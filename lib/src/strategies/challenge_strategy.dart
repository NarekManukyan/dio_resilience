import 'dart:async';

import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../options_extension.dart';
import '../overrides.dart';
import '../pipeline_context.dart';
import '../strategy.dart';

/// Discriminated input passed to a [ChallengeMatcher].
///
/// Eliminates the impossible "both response and error non-null" state of a
/// `(Response?, DioException?)` pair. The pipeline always invokes the matcher
/// on exactly one of the two paths.
sealed class ChallengeSignal {
  const ChallengeSignal();

  /// Convenience: the request that produced this signal.
  RequestOptions get request;
}

/// Signal for any response the server sent: a success, or the response of
/// an error status (a `428`, a `403` with a challenge body). The matcher
/// classifies it as a challenge or not.
final class ChallengeOnResponse extends ChallengeSignal {
  final Response<dynamic> response;
  const ChallengeOnResponse(this.response);

  @override
  RequestOptions get request => response.requestOptions;
}

/// Signal for an error that carries no response (a transport failure). An
/// error with a response, such as a `428` or a `403` with a challenge body,
/// reaches the matcher as [ChallengeOnResponse] instead.
final class ChallengeOnError extends ChallengeSignal {
  final DioException error;
  const ChallengeOnError(this.error);

  @override
  RequestOptions get request => error.requestOptions;
}

/// Predicate determining whether a signal represents a server-issued
/// challenge demanding a solved proof token.
///
/// Called once per response and once per error. Keep it a pure check; a
/// matcher that throws counts as "not a challenge".
typedef ChallengeMatcher = bool Function(ChallengeSignal signal);

/// Solver that produces a challenge token from the request and (optionally)
/// the response that triggered the challenge.
typedef ChallengeSolver<T> = Future<T> Function(
  RequestOptions request,
  Response<dynamic>? response,
);

/// Applier that mutates [request] in place to attach the solved token.
///
/// The applier is expected to mutate `request.headers` / `request.extra` in
/// place — matching the existing Dio idiom used elsewhere in this package
/// (see `AuthStrategy._injectAuthHeader`). Do NOT replace the options object.
typedef ChallengeApplier<T> = void Function(
  RequestOptions request,
  T token,
);

/// Configuration for a [ChallengeStrategy] instance.
///
/// Generic over the token type [T] so callers can return whatever shape the
/// downstream applier needs — a `String` (captcha), `Uint8List` (device
/// attestation), or a `Map<String, String>` (multi-field MFA).
final class ChallengeConfig<T> {
  /// Predicate detecting a challenge-shaped signal (response or error).
  final ChallengeMatcher matcher;

  /// Resolves the proof token. Invoked at most [maxAttempts] times per
  /// request and constrained by [solverTimeout].
  final ChallengeSolver<T> solver;

  /// Mutates the request to attach [solver]'s result before replay.
  final ChallengeApplier<T> applier;

  /// Maximum number of solve+replay cycles per request before failing with
  /// [ChallengeFailureReason.maxAttemptsExceeded]. Defaults to 1 because the
  /// most common challenge tokens (captcha, MFA) are single-use and a second
  /// challenge typically indicates a server problem rather than a recoverable
  /// state.
  final int maxAttempts;

  /// Per-solve deadline. If the solver does not complete within this window
  /// the strategy fails with [ChallengeFailureReason.solverTimeout].
  final Duration solverTimeout;

  /// When true, concurrent requests whose [keyOf] resolves to the same key
  /// share a single in-flight solve. Defaults to **false** because most
  /// challenge tokens (captcha, TOTP) are single-use — sharing one solved
  /// token across N requests means N-1 will be rejected and trigger N more
  /// solves. Only enable for tokens with reuse semantics (e.g. device
  /// attestation valid for a window).
  final bool singleFlight;

  /// Single-flight key extractor. When null, requests are keyed by
  /// `request.uri.host` (matching `CircuitBreakerStrategy` convention).
  final String Function(RequestOptions request)? keyOf;

  const ChallengeConfig({
    required this.matcher,
    required this.solver,
    required this.applier,
    this.maxAttempts = 1,
    this.solverTimeout = const Duration(seconds: 30),
    this.singleFlight = false,
    this.keyOf,
  });
}

const String _kChallengeAttemptsKey = '__dio_resilience_challenge_attempts__';

/// Strategy that handles server-issued challenge-response flows (CAPTCHA,
/// MFA step-up, device attestation, etc.).
///
/// On a matched response or error, the strategy:
///   1. Invokes [ChallengeConfig.solver] (subject to [singleFlight] and
///      [solverTimeout]).
///   2. Applies the resulting token to the original [RequestOptions] via
///      [ChallengeConfig.applier].
///   3. Returns [StrategyDecision.replay] so the pipeline re-fires the
///      request with the attached token. That replay doesn't count against
///      the retry budget.
///
/// A response the matcher accepts is a challenge even with a 2xx status: the
/// strategy turns it into an error so the replay path above handles it.
///
/// Pipeline placement: between **hedging** and **retry**, so a challenge-shaped
/// response is intercepted *before* the retry strategy burns its budget on
/// blind replays of a request the server has explicitly told us cannot
/// succeed without a fresh token. The circuit breaker doesn't count
/// challenges as failures.
///
/// When solving fails (the solver throws or times out, or [maxAttempts]
/// solves were already spent) the request fails with a
/// [ChallengeFailedException]; a fallback still gets to handle it.
final class ChallengeStrategy<T> extends ResilienceStrategy {
  final ChallengeConfig<T> config;

  /// Per-key in-flight solve, used when `config.singleFlight` is true.
  final Map<String, Completer<T>> _inFlight = {};

  ChallengeStrategy(this.config);

  @override
  String get name => 'challenge';

  /// Whether this strategy will answer [error] on [request]: it is enabled
  /// for the request and the matcher accepts the error.
  ///
  /// The pipeline asks once per error, before any strategy's `onError`, and
  /// stores the answer in [PipelineContext.isChallengeError], so siblings
  /// (the circuit breaker) can skip challenges in their accounting.
  bool handles(RequestOptions request, DioException error) {
    if (_isDisabledFor(request)) return false;
    if (error.type == DioExceptionType.cancel) return false;
    if (error is DioResilienceException) return false;
    final response = error.response;
    return _matches(
      response != null
          ? ChallengeOnResponse(response)
          : ChallengeOnError(error),
    );
  }

  /// Whether this strategy will answer [response] on [request] as a
  /// challenge. The pipeline asks once per response and stores the answer in
  /// [PipelineContext.isChallengeError].
  bool handlesResponse(RequestOptions request, Response<dynamic> response) =>
      !_isDisabledFor(request) && _matches(ChallengeOnResponse(response));

  @override
  Future<void> onResponse(
    PipelineContext ctx,
    Response<dynamic> response,
  ) async {
    // The pipeline already asked [handlesResponse] for this response.
    if (!ctx.isChallengeError) return;

    // Server returned a successful HTTP response that the matcher classifies
    // as a challenge (e.g. 200 with a challenge body). Convert it into a
    // pipeline error so the standard onError replay path handles it.
    throw DioException(
      requestOptions: ctx.request,
      response: response,
      type: DioExceptionType.badResponse,
      error: const _ChallengeMarker(),
    );
  }

  @override
  Future<StrategyDecision?> onError(
    PipelineContext ctx,
    DioException error,
  ) async {
    // The pipeline already asked [handles] for this error.
    if (!ctx.isChallengeError) return null;

    // Recursion guard: cap solve+replay cycles per request.
    final attempts = (ctx.meta[_kChallengeAttemptsKey] as int?) ?? 0;
    if (attempts >= config.maxAttempts) {
      return StrategyDecision.fail(
        ChallengeFailedException(
          requestOptions: ctx.request,
          reason: ChallengeFailureReason.maxAttemptsExceeded,
          response: error.response,
          stackTrace: StackTrace.current,
        ),
      );
    }
    ctx.meta[_kChallengeAttemptsKey] = attempts + 1;

    final T token;
    try {
      token = await _solve(ctx.request, error.response);
    } on TimeoutException catch (e, st) {
      return StrategyDecision.fail(
        ChallengeFailedException(
          requestOptions: ctx.request,
          reason: ChallengeFailureReason.solverTimeout,
          response: error.response,
          error: e,
          stackTrace: st,
        ),
      );
    } catch (e, st) {
      return StrategyDecision.fail(
        ChallengeFailedException(
          requestOptions: ctx.request,
          reason: ChallengeFailureReason.solverError,
          response: error.response,
          error: e,
          stackTrace: st,
        ),
      );
    }

    try {
      config.applier(ctx.request, token);
    } catch (e, st) {
      return StrategyDecision.fail(
        ChallengeFailedException(
          requestOptions: ctx.request,
          reason: ChallengeFailureReason.solverError,
          response: error.response,
          error: e,
          stackTrace: st,
        ),
      );
    }
    return const StrategyDecision.replay(countsAsAttempt: false);
  }

  bool _matches(ChallengeSignal signal) {
    try {
      return config.matcher(signal);
    } catch (_) {
      return false;
    }
  }

  /// Run the solver under timeout + optional single-flight semantics.
  ///
  /// Single-flight slot is freed (in `finally`) on success, error, AND
  /// timeout — the strategy never leaves a stuck completer in [_inFlight].
  Future<T> _solve(RequestOptions request, Response<dynamic>? response) async {
    if (!config.singleFlight) {
      return _runSolverWithTimeout(request, response);
    }

    final key = config.keyOf?.call(request) ?? request.uri.host;
    final existing = _inFlight[key];
    if (existing != null) return existing.future;

    final completer = Completer<T>();
    _inFlight[key] = completer;
    // Suppress "unhandled" errors when no concurrent waiters attach via
    // .future — the originating caller below throws synchronously. Concurrent
    // waiters install their own listeners by awaiting `existing.future`.
    unawaited(completer.future.then<void>((_) {}, onError: (_) {}));

    try {
      final token = await _runSolverWithTimeout(request, response);
      completer.complete(token);
      return token;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<T> _runSolverWithTimeout(
    RequestOptions request,
    Response<dynamic>? response,
  ) {
    return config.solver(request, response).timeout(config.solverTimeout);
  }

  bool _isDisabledFor(RequestOptions request) =>
      overridesFor(request)?.challenge is ChallengeDisabled;

  /// Test/diagnostic hook: number of in-flight single-flight solves.
  int get inFlightCount => _inFlight.length;
}

/// Internal marker used to wrap a challenge-shaped success response into a
/// [DioException] so that the standard `onError` replay path handles it.
class _ChallengeMarker {
  const _ChallengeMarker();
}
