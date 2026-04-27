import 'dart:async';

import 'package:dio/dio.dart';

import 'backoff.dart';
import 'conditions.dart';
import 'exceptions.dart';
import 'pipeline_context.dart';
import 'storage/memory_token_storage.dart';
import 'strategy.dart';
import 'strategies/auth_strategy.dart';
import 'strategies/retry_strategy.dart';
import 'strategies/timeout_strategy.dart';
import 'token.dart';

/// Internal key under which the [PipelineContext] is stashed inside
/// [RequestOptions.extra] (which is typed `Map<String, dynamic>`).
const String _kPipelineContextKey = '__dio_resilience_pipeline_context__';

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
  /// for replaying requests.
  ResiliencePipeline attachTo(Dio dio) {
    _dio = dio;
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
    // Create a fresh context for this request
    final ctx = PipelineContext(options);

    // Store context in request.extra for later retrieval
    options.extra[_kPipelineContextKey] = ctx;

    try {
      // Invoke each strategy's onRequest hook
      for (final strategy in _strategies) {
        await strategy.onRequest(ctx);
      }

      // Proceed to the next interceptor/request
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
      // Check total timeout budget before replaying
      if (!_isTotalTimeoutExceeded(ctx)) {
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
      }

      // No strategy decided to replay, and total timeout not exceeded
      // Propagate original error
      return handler.next(err);
    } catch (e, st) {
      // If strategy logic throws, propagate as new error
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

    try {
      // Re-fire the request through Dio
      final response = await _dio.fetch<dynamic>(ctx.request);

      // Success: resolve with the new response
      return handler.resolve(response);
    } on DioException catch (e) {
      // Error on replay: send back to onError for next strategy
      return handler.next(e);
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
  RetryStrategy? _retryStrategy;
  TimeoutStrategy? _timeoutStrategy;

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

  /// Build the pipeline.
  ResiliencePipeline build() {
    final strategies = <ResilienceStrategy>[
      if (_authStrategy != null) _authStrategy!,
      if (_retryStrategy != null) _retryStrategy!,
      if (_timeoutStrategy != null) _timeoutStrategy!,
    ];

    return ResiliencePipeline._(strategies);
  }
}
