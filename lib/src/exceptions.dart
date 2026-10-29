import 'package:dio/dio.dart';

/// Base class for all dio_resilience-thrown exceptions.
///
/// Inherits from [DioException] so that existing app-level error handling
/// (`try/catch DioException`) continues to work without modification.
///
/// Subclasses that wrap a failed attempt keep that attempt's
/// [DioException.response] and [DioException.error], and
/// [AllAttemptsExhaustedException] also keeps its [DioException.type], so
/// code that classifies errors (timeout, connection error, bad response)
/// still works on the wrapper.
sealed class DioResilienceException extends DioException {
  DioResilienceException({
    required super.requestOptions,
    super.response,
    super.message,
    super.error,
    super.stackTrace,
    super.type = DioExceptionType.unknown,
  });
}

/// Thrown when the auth strategy's refresh flow fails terminally.
///
/// Every request waiting on the same refresh receives its own instance,
/// carrying its own [requestOptions]. [error] is the cause the refresh
/// failed with.
final class RefreshFailedException extends DioResilienceException {
  RefreshFailedException({
    required super.requestOptions,
    super.response,
    super.error,
    super.stackTrace,
  }) : super(message: 'Token refresh failed; user must re-authenticate.');
}

/// Thrown when the circuit breaker is open and a call is fail-fast rejected.
final class CircuitOpenException extends DioResilienceException {
  final String circuitName;

  CircuitOpenException({
    required super.requestOptions,
    required this.circuitName,
    super.stackTrace,
  }) : super(message: 'Circuit "$circuitName" is open; call rejected.');
}

/// Thrown by [RateLimiterStrategy] when a token cannot be acquired.
///
/// In [RateLimitMode.fail] mode this is thrown immediately when no token is
/// available. In [RateLimitMode.wait] mode it is thrown when the pipeline's
/// total budget would run out before a token becomes available.
final class RateLimitExceededException extends DioResilienceException {
  /// The rate-limit key that triggered this exception (e.g. the host name).
  final String key;

  RateLimitExceededException({
    required super.requestOptions,
    required this.key,
    super.stackTrace,
  }) : super(message: 'Rate limit exceeded for key "$key".');
}

/// Thrown when the pipeline's total time budget runs out: an attempt was
/// still in flight at the deadline, or the next retry would not fit in what
/// is left of it.
final class PipelineTimeoutException extends DioResilienceException {
  final Duration budget;

  /// The failed attempt that would have been retried, or null when the
  /// deadline cut an attempt short.
  final DioException? lastError;

  /// True when the deadline cancelled an attempt that was on the wire: the
  /// backend didn't answer in time.
  final bool cutAttempt;

  PipelineTimeoutException({
    required super.requestOptions,
    required this.budget,
    this.lastError,
    this.cutAttempt = false,
    super.stackTrace,
  }) : super(
          message: 'Pipeline timeout after ${budget.inMilliseconds}ms.',
          response: lastError?.response,
          error: lastError?.error,
        );
}

/// Thrown when a [ChallengeStrategy] solver fails, times out, or the
/// per-request challenge budget is exhausted.
///
/// Carries a [ChallengeFailureReason] discriminator so callers can
/// distinguish solver throws from timeouts from budget exhaustion without
/// inspecting the underlying [error] / [stackTrace]. [response] is the
/// challenge response, when there was one.
final class ChallengeFailedException extends DioResilienceException {
  final ChallengeFailureReason reason;

  ChallengeFailedException({
    required super.requestOptions,
    required this.reason,
    super.response,
    super.error,
    super.stackTrace,
  }) : super(message: 'Challenge failed: ${reason.name}.');
}

/// Discriminator for [ChallengeFailedException].
enum ChallengeFailureReason {
  /// The solver callback threw (or completed with an error).
  solverError,

  /// The solver did not complete before [ChallengeConfig.solverTimeout].
  solverTimeout,

  /// `maxAttempts` re-challenges already fired for this request.
  maxAttemptsExceeded,
}

/// Thrown when retries have been exhausted. Fallback handlers still see it.
///
/// Keeps the last attempt's [type], [response] and [error], so an exhausted
/// run of timeouts still reads as a timeout. [lastError] is that attempt.
final class AllAttemptsExhaustedException extends DioResilienceException {
  final int attempts;

  /// The last failed attempt.
  final DioException lastError;

  AllAttemptsExhaustedException({
    required super.requestOptions,
    required this.attempts,
    required this.lastError,
    super.stackTrace,
  }) : super(
          message: 'All $attempts retry attempts exhausted.',
          type: lastError.type,
          response: lastError.response,
          error: lastError.error,
        );
}
