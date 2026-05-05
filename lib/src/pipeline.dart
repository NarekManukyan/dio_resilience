import 'dart:async';

import 'package:dio/dio.dart';

import 'backoff.dart';
import 'conditions.dart';
import 'exceptions.dart';
import 'pipeline_context.dart';
import 'storage/memory_token_storage.dart';
import 'strategy.dart';
import 'overrides.dart';
import 'strategies/auth_strategy.dart';
import 'strategies/circuit_breaker_strategy.dart';
import 'strategies/fallback_strategy.dart';
import 'strategies/hedging_strategy.dart';
import 'strategies/rate_limiter_strategy.dart';
import 'strategies/retry_strategy.dart';
import 'strategies/timeout_strategy.dart';
import 'token.dart';

/// Internal key under which the [PipelineContext] is stashed inside
/// [RequestOptions.extra] (which is typed `Map<String, dynamic>`).
const String _kPipelineContextKey = '__dio_resilience_pipeline_context__';

/// Flag set on requests that are replay attempts fired by [_handleReplay].
/// When present, custom-dispatch errors are rejected without
/// [callFollowingErrorInterceptor] so that the retry chain within
/// [_handleReplay] handles them, rather than triggering a second recursive
/// retry in [onError].
const String _kIsReplayKey = '__dio_resilience_is_replay__';

/// Central orchestrator for all resilience strategies.
///
/// The pipeline coordinates retry, timeout, and auth/token-refresh strategies
/// in a single Dio interceptor. It manages request lifecycle, elapsed time
/// tracking, and replay decisions.
///
/// Usage:
/// ```dart
/// final dio = Dio();
/// dio.interceptors.add(
///   ResiliencePipeline.builder()
///     .retry(maxAttempts: 3)
///     .timeout(total: Duration(seconds: 30))
///     .build()
///     ..attachTo(dio)
/// );
/// ```
final class ResiliencePipeline extends Interceptor {
  final List<ResilienceStrategy> _strategies;
  late Dio _dio;

  /// Create a pipeline builder for fluent configuration.
  static ResiliencePipelineBuilder builder() => ResiliencePipelineBuilder();

  /// Internal constructor. Use [builder()] instead.
  ResiliencePipeline._(this._strategies);

  /// Attach this pipeline to a Dio instance.
  ///
  /// This registers the pipeline as an interceptor and stores the Dio reference
  /// for replaying requests. Also injects the Dio reference into any
  /// [FallbackStrategy] so endpoint handlers can re-fire through the same
  /// interceptor chain.
  ResiliencePipeline attachTo(Dio dio) {
    _dio = dio;
    for (final strategy in _strategies) {
      if (strategy is FallbackStrategy) {
        strategy.injectDio(dio);
      }
    }
    dio.interceptors.add(this);
    return this;
  }

  /// Stream of auth state changes (delegates to AuthStrategy if present).
  Stream<AuthState> get authStateStream {
    final authStrategy = _findStrategy<AuthStrategy>();
    if (authStrategy != null) {
      return authStrategy.authStateStream;
    }
    return const Stream.empty();
  }

  /// Manually sign out the user (delegates to AuthStrategy if present).
  Future<void> signOut({AccountId? accountId}) async {
    final authStrategy = _findStrategy<AuthStrategy>();
    if (authStrategy != null) {
      await authStrategy.logout(accountId: accountId);
    }
  }

  /// Dispose the pipeline, cleaning up any resources (e.g. auth state stream).
  void dispose() {
    for (final strategy in _strategies) {
      if (strategy is AuthStrategy) {
        strategy.dispose();
      }
    }
  }

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Reuse the existing context if this request is a retry replay from
    // _handleReplay (which calls _dio.fetch(ctx.request) on the SAME
    // RequestOptions object). Reusing the context preserves the attempt
    // counter and elapsed timer so retry/timeout strategies see the correct
    // state. For a genuinely fresh request (no prior context), create one.
    final existing = options.extra[_kPipelineContextKey];
    final ctx = existing is PipelineContext && existing.request == options
        ? existing
        : PipelineContext(options);

    // Store context in request.extra for later retrieval
    options.extra[_kPipelineContextKey] = ctx;

    try {
      // Invoke each strategy's onRequest hook
      for (final strategy in _strategies) {
        await strategy.onRequest(ctx);
      }

      // Give strategies a chance to intercept the dispatch (e.g. hedging).
      // The first strategy that returns a non-null future owns the dispatch.
      Future<Response<dynamic>>? customDispatch;
      for (final strategy in _strategies) {
        customDispatch = strategy.onDispatch(
          ctx,
          ([RequestOptions? overrideOptions]) =>
              _dio.fetch<dynamic>(overrideOptions ?? ctx.request),
        );
        if (customDispatch != null) break;
      }

      if (customDispatch != null) {
        // Strategy took over dispatch — await and resolve/reject manually.
        // On success, resolve immediately. On error, route through the
        // pipeline's own onError strategy chain so retry/fallback/etc. can act
        // on the failure.
        //
        // Two important details:
        //   1. callFollowingErrorInterceptor = true — plain handler.reject(e)
        //      uses InterceptorResultType.reject which causes Dio's
        //      errorInterceptorWrapper to rethrow and skip our own onError
        //      handler. Passing true uses rejectCallFollowing, which triggers
        //      our error interceptor.
        //   2. Re-stamp requestOptions — errors that surface from hedged branch
        //      clones may carry a stale RequestOptions (e.g. from the adapter
        //      test factory) that lacks the pipeline context in its extra map.
        //      We ensure the error carries the original options so that
        //      _retrieveContext can locate the PipelineContext in onError.
        // Whether to route errors through our onError (retry/fallback-aware).
        // Disabled for replay attempts to prevent recursive retry chains.
        final isReplay = options.extra[_kIsReplayKey] == true;

        try {
          final response = await customDispatch;
          return handler.resolve(response);
        } on DioException catch (e) {
          final corrected = e.requestOptions == options
              ? e
              : e.copyWith(requestOptions: options);
          return handler.reject(corrected, isReplay ? false : true);
        } catch (e, st) {
          return handler.reject(
            DioException(
              requestOptions: options,
              error: e,
              stackTrace: st,
              type: DioExceptionType.unknown,
            ),
            isReplay ? false : true,
          );
        }
      }

      // No strategy intercepted; proceed normally.
      return handler.next(options);
    } catch (e, st) {
      // If any strategy throws in onRequest, propagate as error
      handler.reject(
        DioException(
          requestOptions: options,
          error: e,
          stackTrace: st,
          type: DioExceptionType.unknown,
        ),
      );
    }
  }

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final ctx = _retrieveContext(response.requestOptions);
    if (ctx == null) {
      // No context (unexpected), pass through
      return handler.next(response);
    }

    try {
      // Invoke each strategy's onResponse hook
      for (final strategy in _strategies) {
        await strategy.onResponse(ctx, response);
      }

      return handler.next(response);
    } catch (e, st) {
      // If any strategy throws in onResponse, convert to error
      handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          response: response,
          error: e,
          stackTrace: st,
          type: DioExceptionType.unknown,
        ),
      );
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final ctx = _retrieveContext(err.requestOptions);
    if (ctx == null) {
      // No context, pass through
      return handler.next(err);
    }

    try {
      // Check total timeout budget before letting strategies act. If the
      // pipeline's total budget has been exceeded, surface a typed
      // PipelineTimeoutException instead of the underlying transport error
      // — strategies (retry/auth/etc.) are already irrelevant past the
      // deadline.
      if (_isTotalTimeoutExceeded(ctx)) {
        return handler.reject(
          PipelineTimeoutException(
            requestOptions: ctx.request,
            budget: _getTotalBudget(ctx) ?? Duration.zero,
            stackTrace: StackTrace.current,
          ),
        );
      }

      // Invoke each strategy's onError hook in order
      for (final strategy in _strategies) {
        final decision = await strategy.onError(ctx, err);

        if (decision == null) {
          // This strategy doesn't care; continue to next
          continue;
        }

        // Strategy made a decision; execute it
        return _executeDecision(
          decision: decision,
          ctx: ctx,
          originalError: err,
          handler: handler,
        );
      }

      // No strategy decided to replay; propagate original error.
      return handler.next(err);
    } on DioException catch (e) {
      // Strategy threw a typed DioException (e.g. RefreshFailedException) —
      // surface it as-is so callers can pattern-match the concrete type.
      handler.reject(e);
    } catch (e, st) {
      // If strategy logic throws something non-Dio, wrap as generic.
      handler.reject(
        DioException(
          requestOptions: err.requestOptions,
          error: e,
          stackTrace: st,
          type: DioExceptionType.unknown,
        ),
      );
    }
  }

  /// Execute a strategy decision: replay, respond, or fail.
  Future<void> _executeDecision({
    required StrategyDecision decision,
    required PipelineContext ctx,
    required DioException originalError,
    required ErrorInterceptorHandler handler,
  }) async {
    switch (decision) {
      case ReplayDecision(delay: final d):
        return _handleReplay(ctx: ctx, handler: handler, delay: d);
      case RespondDecision(response: final r):
        return handler.resolve(r);
      case FailDecision(error: final e):
        return handler.reject(e);
    }
  }

  /// Handle a replay decision: delay, increment attempt, and re-fire.
  Future<void> _handleReplay({
    required PipelineContext ctx,
    required ErrorInterceptorHandler handler,
    Duration? delay,
  }) async {
    // Wait for backoff delay if specified
    if (delay != null && delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }

    // Increment attempt number
    ctx.attemptNumber++;

    // Check if total budget is exceeded
    if (_isTotalTimeoutExceeded(ctx)) {
      return handler.reject(
        PipelineTimeoutException(
          requestOptions: ctx.request,
          budget: _getTotalBudget(ctx) ?? Duration.zero,
          stackTrace: StackTrace.current,
        ),
      );
    }

    // Mark the request as a replay so that onRequest knows to route
    // custom-dispatch errors directly (without callFollowingErrorInterceptor)
    // and avoid a recursive retry chain inside _handleReplay.
    ctx.request.extra[_kIsReplayKey] = true;
    try {
      // Re-fire the request through Dio
      final response = await _dio.fetch<dynamic>(ctx.request);

      // Success: resolve with the new response
      return handler.resolve(response);
    } on DioException catch (e) {
      // Error on replay: re-stamp requestOptions so _retrieveContext finds the
      // outer context, then feed back to onError for the next strategy.
      final corrected = e.requestOptions == ctx.request
          ? e
          : e.copyWith(requestOptions: ctx.request);
      return handler.next(corrected);
    } catch (e, st) {
      // Unexpected error
      return handler.reject(
        DioException(
          requestOptions: ctx.request,
          error: e,
          stackTrace: st,
          type: DioExceptionType.unknown,
        ),
      );
    } finally {
      ctx.request.extra.remove(_kIsReplayKey);
    }
  }

  /// Check if the total timeout budget has been exceeded.
  bool _isTotalTimeoutExceeded(PipelineContext ctx) {
    final budget = _getTotalBudget(ctx);
    if (budget == null) return false;

    return ctx.elapsed.elapsed > budget;
  }

  /// Get the total budget from context metadata.
  Duration? _getTotalBudget(PipelineContext ctx) {
    final budget = ctx.meta['totalBudget'];
    return budget is Duration ? budget : null;
  }

  /// Retrieve the context from request.extra.
  PipelineContext? _retrieveContext(RequestOptions request) {
    final ctx = request.extra[_kPipelineContextKey];
    return ctx is PipelineContext ? ctx : null;
  }

  /// Find a strategy of a given type.
  T? _findStrategy<T extends ResilienceStrategy>() {
    for (final strategy in _strategies) {
      if (strategy is T) {
        return strategy;
      }
    }
    return null;
  }
}

/// Builder for fluent pipeline configuration.
class ResiliencePipelineBuilder {
  AuthStrategy? _authStrategy;
  RateLimiterStrategy? _rateLimiterStrategy;
  CircuitBreakerStrategy? _circuitBreakerStrategy;
  HedgingStrategy? _hedgingStrategy;
  RetryStrategy? _retryStrategy;
  TimeoutStrategy? _timeoutStrategy;
  FallbackStrategy? _fallbackStrategy;

  /// Configure auth/token-refresh strategy.
  ///
  /// The [refreshToken] callback receives the current [TokenPair] (may be
  /// null if storage has been cleared) and must return the new pair, or null
  /// to signal terminal refresh failure (which clears storage and fires
  /// [onRefreshFailed]).
  ///
  /// Inside [refreshToken] you should use a SEPARATE [Dio] instance, not the
  /// one this pipeline is attached to — otherwise the refresh request itself
  /// will recurse through the auth strategy.
  ResiliencePipelineBuilder auth({
    required Future<TokenPair?> Function(TokenPair? current) refreshToken,
    TokenStorage? tokenStorage,
    void Function()? onRefreshFailed,
    Duration preemptiveRefreshWindow = const Duration(minutes: 1),
    String scheme = 'Bearer',
    bool Function(DioException)? shouldRefresh,
    bool Function(RequestOptions)? isRefreshRequest,
  }) {
    _authStrategy = AuthStrategy(
      storage: tokenStorage ?? MemoryTokenStorage(),
      refreshToken: refreshToken,
      scheme: scheme,
      preemptiveRefreshWindow: preemptiveRefreshWindow,
      isRefreshRequest: isRefreshRequest,
      shouldRefresh: shouldRefresh,
      onRefreshFailed: onRefreshFailed,
    );
    return this;
  }

  /// Configure rate-limit strategy.
  ///
  /// Requests are bucketed by host by default. Pass [keyExtractor] to use a
  /// custom dimension. [algorithm] selects token-bucket or sliding-window
  /// semantics. [mode] controls whether excess requests block ([RateLimitMode.wait])
  /// or fail immediately ([RateLimitMode.fail]).
  ResiliencePipelineBuilder rateLimit({
    required RateLimitAlgorithm algorithm,
    RateLimitMode mode = RateLimitMode.wait,
    String Function(RequestOptions)? keyExtractor,
    DateTime Function()? now,
  }) {
    _rateLimiterStrategy = RateLimiterStrategy(
      algorithm: algorithm,
      mode: mode,
      keyExtractor: keyExtractor,
      now: now,
    );
    return this;
  }

  /// Configure circuit breaker strategy.
  ///
  /// The circuit is keyed per-host by default. Pass [keyExtractor] to use a
  /// custom dimension (e.g. per-endpoint). The [now] parameter is injectable
  /// for deterministic testing without sleeping.
  ///
  /// Strategy order: auth → rateLimit → **circuit** → retry → timeout.
  ResiliencePipelineBuilder circuitBreaker({
    int failureThreshold = 5,
    Duration windowDuration = const Duration(seconds: 60),
    Duration cooldown = const Duration(seconds: 30),
    int halfOpenProbes = 1,
    String Function(RequestOptions)? keyExtractor,
    DateTime Function()? now,
  }) {
    _circuitBreakerStrategy = CircuitBreakerStrategy(
      failureThreshold: failureThreshold,
      windowDuration: windowDuration,
      cooldown: cooldown,
      halfOpenProbes: halfOpenProbes,
      keyExtractor: keyExtractor,
      now: now,
    );
    return this;
  }

  /// Configure hedging strategy.
  ///
  /// Hedging fires up to [maxParallel] parallel requests for the same logical
  /// call, separated by [delay]. The first successful response wins and all
  /// losing in-flight branches are cancelled via [CancelToken].
  ///
  /// Only requests that match [shouldHedge] are hedged. The default predicate
  /// allows only GET and HEAD (idempotent) methods.
  ///
  /// Strategy execution order: auth → rateLimit → circuit → **hedging** → retry → timeout.
  ResiliencePipelineBuilder hedging({
    int maxParallel = 2,
    Duration delay = const Duration(milliseconds: 100),
    bool Function(RequestOptions)? shouldHedge,
  }) {
    _hedgingStrategy = HedgingStrategy(
      maxParallel: maxParallel,
      delay: delay,
      shouldHedge: shouldHedge,
    );
    return this;
  }

  /// Configure retry strategy.
  ResiliencePipelineBuilder retry({
    int maxAttempts = 3,
    Backoff backoff = const Backoff.exponentialJitter(
      initial: Duration(milliseconds: 200),
      multiplier: 2.0,
      maxDelay: Duration(seconds: 10),
    ),
    List<RetryCondition>? retryOn,
    List<RetryCondition>? doNotRetryOn,
  }) {
    _retryStrategy = RetryStrategy(
      maxAttempts: maxAttempts,
      backoff: backoff,
      defaultRetryOn: retryOn,
      defaultDoNotRetryOn: doNotRetryOn,
    );
    return this;
  }

  /// Configure timeout strategy.
  ResiliencePipelineBuilder timeout({
    Duration? total,
    Duration? perAttempt,
  }) {
    _timeoutStrategy = TimeoutStrategy(
      totalBudget: total,
      perAttempt: perAttempt,
    );
    return this;
  }

  /// Configure fallback strategy.
  ///
  /// Positioned LAST in the pipeline — only activates when every other
  /// strategy (auth, rate-limit, circuit, hedging, retry, timeout) has
  /// declined to handle the error.
  ///
  /// [handlers] — ordered list of [FallbackHandler]s tried on error. The first
  /// matching handler's result is returned as [StrategyDecision.respond].
  ///
  /// Example:
  /// ```dart
  /// .fallback(handlers: [
  ///   FallbackHandler.endpoint('https://mirror.example.com/api'),
  ///   FallbackHandler.response((err, opts) => Response(
  ///     requestOptions: opts,
  ///     statusCode: 200,
  ///     data: {'offline': true},
  ///   )),
  /// ])
  /// ```
  ResiliencePipelineBuilder fallback({
    required List<FallbackHandler> handlers,
  }) {
    _fallbackStrategy = FallbackStrategy(handlers: handlers);
    return this;
  }

  /// Build the pipeline.
  ///
  /// Strategy execution order:
  /// auth → rateLimit → circuit → hedging → retry → timeout → **fallback**.
  ResiliencePipeline build() {
    final strategies = <ResilienceStrategy>[
      if (_authStrategy != null) _authStrategy!,
      if (_rateLimiterStrategy != null) _rateLimiterStrategy!,
      if (_circuitBreakerStrategy != null) _circuitBreakerStrategy!,
      if (_hedgingStrategy != null) _hedgingStrategy!,
      if (_retryStrategy != null) _retryStrategy!,
      if (_timeoutStrategy != null) _timeoutStrategy!,
      // Fallback is always last — it only fires when no other strategy decided.
      if (_fallbackStrategy != null) _fallbackStrategy!,
    ];

    return ResiliencePipeline._(strategies);
  }
}
