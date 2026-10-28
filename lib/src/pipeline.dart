import 'dart:async';

import 'package:dio/dio.dart';

import 'backoff.dart';
import 'conditions.dart';
import 'events.dart';
import 'exceptions.dart';
import 'overrides.dart';
import 'pipeline_context.dart';
import 'storage/memory_token_storage.dart';
import 'strategies/auth_strategy.dart';
import 'strategies/challenge_strategy.dart';
import 'strategies/circuit_breaker_strategy.dart';
import 'strategies/fallback_strategy.dart';
import 'strategies/hedging_strategy.dart';
import 'strategies/rate_limiter_strategy.dart';
import 'strategies/retry_strategy.dart';
import 'strategies/timeout_strategy.dart';
import 'strategy.dart';
import 'token.dart';

/// Key under which the [PipelineContext] is stashed inside
/// [RequestOptions.extra] (which is typed `Map<String, dynamic>`).
const String _kPipelineContextKey = '__dio_resilience_pipeline_context__';

/// Marks a request a strategy dispatches on behalf of another one (a hedge
/// branch). The pipeline in that request's own chain stays out of it and
/// hands its outcome straight back to the strategy.
const String _kSubDispatchKey = '__dio_resilience_sub_dispatch__';

/// The reason the pipeline cancels an attempt still in flight at the total
/// budget's deadline. Turned into a [PipelineTimeoutException].
final class _DeadlineReached {
  const _DeadlineReached();
}

/// Central orchestrator for all resilience strategies.
///
/// One Dio interceptor that runs every configured strategy for each request
/// and owns the request's whole life: the first attempt, every replay, and
/// the single outcome the caller gets.
///
/// Replays go through `dio.fetch` again, so interceptors registered before
/// the pipeline see every attempt. Interceptors registered after it see each
/// attempt's request and a successful response, but only the final error,
/// once: a retried 503 reaches them as the one error the caller receives.
///
/// Usage:
/// ```dart
/// final dio = Dio();
/// ResiliencePipeline.builder()
///   .retry(maxAttempts: 3)
///   .timeout(total: Duration(seconds: 30))
///   .build()
///   .attachTo(dio);
/// ```
///
/// Register it with [attachTo], not `dio.interceptors.add`: it needs the
/// [Dio] to replay requests through.
final class ResiliencePipeline extends Interceptor {
  final List<ResilienceStrategy> _strategies;
  final ChallengeStrategy<dynamic>? _challenge;
  final void Function(ResilienceEvent event)? _onEvent;
  Dio? _dio;

  /// Create a pipeline builder for fluent configuration.
  static ResiliencePipelineBuilder builder() => ResiliencePipelineBuilder();

  ResiliencePipeline._(this._strategies, this._onEvent)
      : _challenge =
            _strategies.whereType<ChallengeStrategy<dynamic>>().firstOrNull;

  /// Attach this pipeline to a Dio instance.
  ///
  /// Adds the pipeline to `dio.interceptors` (once, even if called again)
  /// and keeps the Dio reference for replaying requests. Also injects the
  /// Dio reference into any [FallbackStrategy] so endpoint handlers can
  /// re-fire through the same interceptor chain.
  ///
  /// Interceptors added before this call run ahead of the pipeline, those
  /// added after it run behind it.
  ResiliencePipeline attachTo(Dio dio) {
    final current = _dio;
    if (current != null && !identical(current, dio)) {
      throw StateError(
        'This ResiliencePipeline is already attached to another Dio. '
        'Build one pipeline per Dio.',
      );
    }
    _dio = dio;
    for (final strategy in _strategies) {
      if (strategy is FallbackStrategy) {
        strategy.injectDio(dio);
      }
    }
    if (!dio.interceptors.contains(this)) {
      dio.interceptors.add(this);
    }
    return this;
  }

  /// Stream of auth state changes (delegates to AuthStrategy if present).
  Stream<AuthState> get authStateStream =>
      _findStrategy<AuthStrategy>()?.authStateStream ?? const Stream.empty();

  /// Manually sign out the user (delegates to AuthStrategy if present).
  Future<void> signOut({AccountId? accountId}) async {
    await _findStrategy<AuthStrategy>()?.logout(accountId: accountId);
  }

  /// Dispose the pipeline, cleaning up any resources (e.g. auth state stream).
  void dispose() {
    _findStrategy<AuthStrategy>()?.dispose();
  }

  // ----- Request ------------------------------------------------------------

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra[_kSubDispatchKey] == true) {
      return handler.next(options);
    }
    final dio = _dio;
    if (dio == null) {
      throw StateError(
        'ResiliencePipeline was added to dio.interceptors directly. '
        'Register it with pipeline.attachTo(dio) instead.',
      );
    }

    // A replay re-sends the same RequestOptions, so it finds its context
    // here and keeps the attempt counter and elapsed time. Anything else (a
    // first send, or a finished request's options sent again) starts fresh.
    final existing = options.extra[_kPipelineContextKey];
    final isReplay = existing is PipelineContext &&
        identical(existing.request, options) &&
        !existing.settled;
    final ctx = isReplay ? existing : PipelineContext(options);
    if (!isReplay) {
      options.extra[_kPipelineContextKey] = ctx;
      ctx.callerToken = options.cancelToken;
      for (final strategy in _strategies) {
        strategy.onStart(ctx);
      }
      _armDeadline(ctx);
    }

    try {
      for (final strategy in _strategies) {
        await strategy.onRequest(ctx);
      }
      // A strategy may have waited (rate limit, token refresh) past the end
      // of the budget; don't send an attempt that has no time left.
      if (ctx.isBudgetExhausted) {
        throw PipelineTimeoutException(
          requestOptions: options,
          budget: ctx.totalBudget!,
          stackTrace: StackTrace.current,
        );
      }

      // Started before the dispatch hook so a strategy that dispatches
      // itself (hedging) links its branches to this attempt's token.
      _beginAttempt(ctx);
      Future<Response<dynamic>>? customDispatch;
      for (final strategy in _strategies) {
        customDispatch = strategy.onDispatch(
          ctx,
          ([RequestOptions? branch]) =>
              dio.fetch<dynamic>(_asSubDispatch(branch ?? options)),
        );
        if (customDispatch != null) break;
      }

      if (customDispatch == null) {
        return handler.next(options);
      }

      // A strategy owns this dispatch (hedging). Its branches skipped the
      // strategies in their own chains, so run them on the winner here.
      final Response<dynamic> response;
      try {
        response = await customDispatch;
      } finally {
        _endAttempt(ctx);
      }
      await _runOnResponse(ctx, response);
      if (!ctx.replayInFlight) ctx.settle();
      handler.resolve(response);
    } catch (e, st) {
      _endAttempt(ctx);
      // Into the error chain, where onError decides what happens next.
      handler.reject(_asDioException(e, st, options), true);
    }
  }

  // ----- Response -----------------------------------------------------------

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final options = response.requestOptions;
    if (options.extra[_kSubDispatchKey] == true) {
      return handler.next(response);
    }
    final ctx = _retrieveContext(options);
    if (ctx == null || ctx.settled) {
      return handler.next(response);
    }
    _endAttempt(ctx);

    try {
      await _runOnResponse(ctx, response);
    } catch (e, st) {
      // A strategy turned this response into a failure (a challenge-shaped
      // 200): into the error chain, where onError decides.
      return handler.reject(
        _asDioException(e, st, options, response: response),
        true,
      );
    }
    if (!ctx.replayInFlight) ctx.settle();
    handler.next(response);
  }

  // ----- Error --------------------------------------------------------------

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    if (options.extra[_kSubDispatchKey] == true) {
      // Back to the strategy that dispatched it, unseen by the interceptors
      // behind the pipeline.
      return handler.reject(err);
    }
    final ctx = _retrieveContext(options);
    if (ctx == null || ctx.settled) {
      return handler.next(err);
    }
    _endAttempt(ctx);
    if (ctx.replayInFlight) {
      // A replay's error: hand it back to the loop in [_settle] that
      // dispatched it, unseen by the interceptors behind the pipeline.
      return handler.reject(err);
    }
    await _settle(ctx, err, handler);
  }

  /// Runs every strategy's `onResponse`, after asking the challenge strategy
  /// once whether [response] is a challenge.
  Future<void> _runOnResponse(
    PipelineContext ctx,
    Response<dynamic> response,
  ) async {
    ctx.isChallengeError =
        _challenge?.handlesResponse(ctx.request, response) ?? false;
    for (final strategy in _strategies) {
      await strategy.onResponse(ctx, response);
    }
  }

  /// Runs the strategies on [error] and replays until the request has an
  /// outcome, then hands that outcome on, once.
  Future<void> _settle(
    PipelineContext ctx,
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    var err = error;
    while (true) {
      final outcome = await _decide(ctx, err);
      switch (outcome) {
        case _Respond(:final response, :final strategy, :final error):
          _emit(
            RecoveredEvent(
              strategy: strategy,
              request: ctx.request,
              error: error,
              response: response,
            ),
          );
          ctx.settle();
          return handler.resolve(response);

        case _GiveUp(:final error):
          ctx.settle();
          if (error.type != DioExceptionType.cancel) {
            _emit(GaveUpEvent(request: ctx.request, error: error));
          }
          return handler.next(error);

        case _Replay(:final decision, :final strategy, :final error):
          final delay = decision.delay ?? Duration.zero;
          if (decision.countsAsAttempt) ctx.attemptNumber++;
          ctx.replayCount++;
          _emit(
            ReplayEvent(
              strategy: strategy,
              request: ctx.request,
              error: error,
              attemptNumber: ctx.attemptNumber,
              delay: delay,
            ),
          );
          if (delay > Duration.zero) {
            final cancelled = await _wait(ctx, delay);
            if (cancelled != null) {
              ctx.settle();
              return handler.next(cancelled);
            }
          }

          ctx.replayInFlight = true;
          try {
            final response = await _dio!.fetch<dynamic>(ctx.request);
            ctx.settle();
            return handler.resolve(response);
          } catch (e, st) {
            err = _asDioException(e, st, ctx.request);
          } finally {
            ctx.replayInFlight = false;
          }
      }
    }
  }

  /// Asks the strategies, in order, what to do about [error].
  Future<_Outcome> _decide(PipelineContext ctx, DioException error) async {
    var err = error;
    if (err.type == DioExceptionType.cancel) {
      if (err.error is! _DeadlineReached) return _GiveUp(err);
      err = PipelineTimeoutException(
        requestOptions: ctx.request,
        budget: ctx.totalBudget ?? Duration.zero,
        stackTrace: err.stackTrace,
      );
    }
    ctx.isChallengeError = _challenge?.handles(ctx.request, err) ?? false;

    for (final strategy in _strategies) {
      StrategyDecision? decision;
      try {
        decision = await strategy.onError(ctx, err);
      } on DioException catch (e) {
        decision = StrategyDecision.fail(e);
      } catch (e, st) {
        decision = StrategyDecision.fail(_asDioException(e, st, ctx.request));
      }

      switch (decision) {
        case null:
          continue;
        case RespondDecision(:final response):
          return _Respond(response, strategy.name, err);
        case FailDecision(error: final failure):
          // The strategies after this one (fallback) handle the new error.
          err = failure;
          ctx.isChallengeError = false;
          continue;
        case ReplayDecision(:final delay):
          final remaining = ctx.remainingBudget;
          if (remaining != null &&
              (remaining <= Duration.zero ||
                  (delay ?? Duration.zero) >= remaining)) {
            // No time for another attempt: give up on the budget instead,
            // and let the strategies after this one handle that.
            err = PipelineTimeoutException(
              requestOptions: ctx.request,
              budget: ctx.totalBudget!,
              lastError: err,
              stackTrace: StackTrace.current,
            );
            ctx.isChallengeError = false;
            continue;
          }
          return _Replay(decision, strategy.name, err);
      }
    }
    return _GiveUp(err);
  }

  // ----- Helpers ------------------------------------------------------------

  /// Cancels an attempt still in flight when the total budget runs out, so
  /// `total` is a deadline, not just a check between attempts.
  void _armDeadline(PipelineContext ctx) {
    final budget = ctx.totalBudget;
    if (budget == null) return;
    ctx.deadlineTimer = Timer(budget, () {
      ctx.deadlineReached = true;
      // Only an attempt on the wire is cut short. Between attempts the
      // budget check before each replay ends the request.
      final token = ctx.attemptToken;
      if (ctx.attemptInFlight && token != null && !token.isCancelled) {
        token.cancel(const _DeadlineReached());
      }
    });
  }

  /// Marks an attempt as on the wire. Under a total budget the attempt gets
  /// its own [CancelToken], which the deadline cancels and the caller's
  /// token still cancels too.
  ///
  /// A token per attempt, not one per request: Dio races each interceptor
  /// call against the request's token, and the pipeline's own error handling
  /// for an earlier attempt must not be cut short by a later attempt's
  /// deadline.
  void _beginAttempt(PipelineContext ctx) {
    ctx.attemptInFlight = true;
    if (ctx.totalBudget == null) return;
    // Dio builds the cancellation error from the token's requestOptions; it
    // must point at this request so the pipeline finds its context.
    final token = CancelToken()..requestOptions = ctx.request;
    final caller = ctx.callerToken;
    if (caller != null) {
      unawaited(
        caller.whenCancel.then((e) {
          if (!token.isCancelled) token.cancel(e.error);
        }),
      );
    }
    ctx.attemptToken = token;
    ctx.request.cancelToken = token;
  }

  /// Marks the attempt as over and gives the request back the caller's
  /// token.
  void _endAttempt(PipelineContext ctx) {
    ctx.attemptInFlight = false;
    if (ctx.attemptToken == null) return;
    ctx.attemptToken = null;
    ctx.request.cancelToken = ctx.callerToken;
  }

  /// Waits [delay] before a replay. Returns the cancellation when the
  /// request is cancelled first.
  Future<DioException?> _wait(PipelineContext ctx, Duration delay) async {
    final token = ctx.request.cancelToken;
    if (token == null) {
      await Future<void>.delayed(delay);
      return null;
    }
    final cancelError = token.cancelError;
    if (cancelError != null) return cancelError;
    final done = Completer<DioException?>();
    final timer = Timer(delay, () {
      if (!done.isCompleted) done.complete(null);
    });
    unawaited(
      token.whenCancel.then((e) {
        if (!done.isCompleted) done.complete(e);
      }),
    );
    final result = await done.future;
    timer.cancel();
    return result;
  }

  /// A copy of [options] marked as a sub-dispatch, so flagging it never
  /// touches the parent's `extra` map.
  RequestOptions _asSubDispatch(RequestOptions options) => options.copyWith(
        extra: {...options.extra, _kSubDispatchKey: true},
      );

  /// [error] as a [DioException] about [options]. A plain [DioException]
  /// about another [RequestOptions] (a hedge branch's copy) is re-stamped
  /// with [options]; a typed resilience exception keeps its type.
  DioException _asDioException(
    Object error,
    StackTrace stackTrace,
    RequestOptions options, {
    Response<dynamic>? response,
  }) {
    if (error is DioException) {
      if (identical(error.requestOptions, options) ||
          error is DioResilienceException) {
        return error;
      }
      return error.copyWith(requestOptions: options);
    }
    return DioException(
      requestOptions: options,
      response: response,
      error: error,
      stackTrace: stackTrace,
      type: DioExceptionType.unknown,
    );
  }

  void _emit(ResilienceEvent event) => _onEvent?.call(event);

  PipelineContext? _retrieveContext(RequestOptions request) {
    final ctx = request.extra[_kPipelineContextKey];
    return ctx is PipelineContext ? ctx : null;
  }

  T? _findStrategy<T extends ResilienceStrategy>() =>
      _strategies.whereType<T>().firstOrNull;
}

/// What [ResiliencePipeline._decide] concluded.
sealed class _Outcome {
  const _Outcome();
}

final class _Respond extends _Outcome {
  final Response<dynamic> response;
  final String strategy;
  final DioException error;
  const _Respond(this.response, this.strategy, this.error);
}

final class _Replay extends _Outcome {
  final ReplayDecision decision;
  final String strategy;
  final DioException error;
  const _Replay(this.decision, this.strategy, this.error);
}

final class _GiveUp extends _Outcome {
  final DioException error;
  const _GiveUp(this.error);
}

/// Builder for fluent pipeline configuration.
class ResiliencePipelineBuilder {
  AuthStrategy? _authStrategy;
  RateLimiterStrategy? _rateLimiterStrategy;
  CircuitBreakerStrategy? _circuitBreakerStrategy;
  HedgingStrategy? _hedgingStrategy;
  ChallengeStrategy<dynamic>? _challengeStrategy;
  RetryStrategy? _retryStrategy;
  TimeoutStrategy? _timeoutStrategy;
  FallbackStrategy? _fallbackStrategy;
  void Function(ResilienceEvent event)? _onEvent;

  /// Configure the auth strategy: token injection, and with [refreshToken]
  /// single-flight token refresh.
  ///
  /// Without [refreshToken] the strategy only injects the token: a `401`
  /// reaches the caller as the `401` it is, after [onAuthFailure] reports
  /// it with the token that was sent.
  ///
  /// The [refreshToken] callback receives the current [TokenPair] (may be
  /// null if storage has been cleared) and must return the new pair, or null
  /// to signal terminal refresh failure (which clears storage when
  /// [clearTokensOnRefreshFailure] is true, and fires [onAuthFailure]).
  ///
  /// [accountStorage] and [refreshAccountToken] serve requests sent with
  /// `Options().withAccount(id)`; see [AccountTokenStorage].
  ///
  /// Inside [refreshToken] you should use a SEPARATE [Dio] instance, not the
  /// one this pipeline is attached to — otherwise the refresh request itself
  /// will recurse through the auth strategy.
  ResiliencePipelineBuilder auth({
    RefreshToken? refreshToken,
    TokenStorage? tokenStorage,
    AccountTokenStorage? accountStorage,
    RefreshAccountToken? refreshAccountToken,
    void Function(AuthRejection rejection)? onAuthFailure,
    @Deprecated('Use onAuthFailure, which says which request and token failed')
    void Function()? onRefreshFailed,
    bool clearTokensOnRefreshFailure = true,
    Duration preemptiveRefreshWindow = const Duration(minutes: 1),
    String scheme = 'Bearer',
    bool Function(DioException)? shouldRefresh,
    bool Function(RequestOptions)? isRefreshRequest,
  }) {
    _authStrategy = AuthStrategy(
      storage: tokenStorage ?? MemoryTokenStorage(),
      refreshToken: refreshToken,
      accountStorage: accountStorage,
      refreshAccountToken: refreshAccountToken,
      scheme: scheme,
      preemptiveRefreshWindow: preemptiveRefreshWindow,
      isRefreshRequest: isRefreshRequest,
      shouldRefresh: shouldRefresh,
      onAuthFailure: onAuthFailure,
      // ignore: deprecated_member_use_from_same_package
      onRefreshFailed: onRefreshFailed,
      clearTokensOnRefreshFailure: clearTokensOnRefreshFailure,
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
  /// for deterministic testing without sleeping. State changes are reported
  /// to [onEvent] as [CircuitStateChangedEvent]s.
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
      onStateChange: (key, from, to) => _onEvent?.call(
        CircuitStateChangedEvent(key: key, from: from, to: to),
      ),
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

  /// Configure challenge-response strategy.
  ///
  /// Handles server-issued challenges (CAPTCHA, MFA step-up, device
  /// attestation) where the server returns a challenge-shaped response or
  /// error and expects a solved proof token attached to a replay of the
  /// original request.
  ///
  /// The [config] supplies the matcher (when to fire), solver (how to
  /// produce a token), and applier (how to attach it). Generic over the
  /// token type so callers can return whatever shape the applier needs.
  ///
  /// The replay after a solve does not count against the retry budget.
  ResiliencePipelineBuilder challenge<T>(ChallengeConfig<T> config) {
    _challengeStrategy = ChallengeStrategy<T>(config);
    return this;
  }

  /// Configure retry strategy.
  ///
  /// Only [methods] are retried; the default is the idempotent methods
  /// ([kIdempotentMethods]), so a POST whose response got lost is never sent
  /// twice. Pass null to retry any method.
  ///
  /// A `Retry-After` longer than [maxRetryAfter] ends the request instead of
  /// waiting; the caller gets the server's answer, header included. Null
  /// waits any `Retry-After` (within the total budget).
  ResiliencePipelineBuilder retry({
    int maxAttempts = 3,
    Backoff backoff = const Backoff.exponentialJitter(
      initial: Duration(milliseconds: 200),
      multiplier: 2.0,
      maxDelay: Duration(seconds: 10),
    ),
    List<RetryCondition>? retryOn,
    List<RetryCondition>? doNotRetryOn,
    Set<String>? methods = kIdempotentMethods,
    Duration? maxRetryAfter = kDefaultMaxRetryAfter,
    DateTime Function()? now,
  }) {
    _retryStrategy = RetryStrategy(
      maxAttempts: maxAttempts,
      backoff: backoff,
      defaultRetryOn: retryOn,
      defaultDoNotRetryOn: doNotRetryOn,
      methods: methods,
      maxRetryAfter: maxRetryAfter,
      now: now,
    );
    return this;
  }

  /// Configure timeout strategy.
  ///
  /// [total] is a deadline for the whole request, retries and waits
  /// included: an attempt still in flight when it passes is cancelled and
  /// the caller gets a [PipelineTimeoutException]. [perAttempt] caps each
  /// attempt's connect and receive timeouts.
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
  /// Positioned LAST in the pipeline: it handles whatever failure the other
  /// strategies end with, including an [AllAttemptsExhaustedException], a
  /// [PipelineTimeoutException] or a [CircuitOpenException].
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

  /// Report retries, fallbacks, final failures and circuit state changes to
  /// [onEvent], for logs and metrics.
  ResiliencePipelineBuilder onEvent(
    void Function(ResilienceEvent event) onEvent,
  ) {
    _onEvent = onEvent;
    return this;
  }

  /// Build the pipeline.
  ///
  /// Strategy execution order:
  /// auth → rateLimit → circuit → hedging → challenge → retry → timeout →
  /// fallback.
  ///
  /// Challenge runs *before* retry so a challenge-shaped response (e.g.
  /// 428 CAPTCHA) is intercepted and solved without consuming the retry
  /// budget. After replay, if the request still fails for transient reasons,
  /// retry kicks in normally on the replayed attempt.
  ResiliencePipeline build() {
    final strategies = <ResilienceStrategy>[
      if (_authStrategy != null) _authStrategy!,
      if (_rateLimiterStrategy != null) _rateLimiterStrategy!,
      if (_circuitBreakerStrategy != null) _circuitBreakerStrategy!,
      if (_hedgingStrategy != null) _hedgingStrategy!,
      if (_challengeStrategy != null) _challengeStrategy!,
      if (_retryStrategy != null) _retryStrategy!,
      if (_timeoutStrategy != null) _timeoutStrategy!,
      // Fallback is always last — it handles whatever the others end with.
      if (_fallbackStrategy != null) _fallbackStrategy!,
    ];

    return ResiliencePipeline._(strategies, _onEvent);
  }
}
