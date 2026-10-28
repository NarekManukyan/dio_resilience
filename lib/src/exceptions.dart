import 'package:dio/dio.dart';

/// Base class for all dio_resilience-thrown exceptions.
///
/// Inherits from [DioException] so that existing app-level error handling
/// (`try/catch DioException`) continues to work without modification.
sealed class DioResilienceException extends DioException {
  DioResilienceException({
    required super.requestOptions,
    super.response,
    super.message,
    super.error,
    super.stackTrace,
  }) : super(type: DioExceptionType.unknown);
}

/// Thrown when the auth strategy's refresh flow fails terminally.
///
/// All in-flight requests waiting on the same refresh receive this exception.
/// The token storage has been cleared at this point and `onRefreshFailed`
/// has fired.
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

/// Thrown when the local rate limiter rejects a call (or its queue wait
/// budget elapses).
final class RateLimitException extends DioResilienceException {
  RateLimitException({
    required super.requestOptions,
    super.stackTrace,
  }) : super(message: 'Local rate limit exceeded.');
}

/// Thrown by [RateLimiterStrategy] when a token cannot be acquired.
///
/// In [RateLimitMode.fail] mode this is thrown immediately when no token is
/// available. In [RateLimitMode.wait] mode it is thrown when the pipeline's
/// total elapsed budget would be exceeded before a token becomes available.
final class RateLimitExceededException extends DioResilienceException {
  /// The rate-limit key that triggered this exception (e.g. the host name).
  final String key;

  RateLimitExceededException({
    required super.requestOptions,
    required this.key,
    super.stackTrace,
  }) : super(message: 'Rate limit exceeded for key "$key".');
}

/// Thrown when the pipeline's total time budget is exhausted across attempts.
final class PipelineTimeoutException extends DioResilienceException {
  final Duration budget;

  PipelineTimeoutException({
    required super.requestOptions,
    required this.budget,
    super.stackTrace,
  }) : super(message: 'Pipeline timeout after ${budget.inMilliseconds}ms.');
}

/// Thrown when a [ChallengeStrategy] solver fails, times out, or the
/// per-request challenge budget is exhausted.
///
/// Carries a [ChallengeFailureReason] discriminator so callers can
/// distinguish solver throws from timeouts from budget exhaustion without
/// inspecting the underlying [error] / [stackTrace].
final class ChallengeFailedException extends DioResilienceException {
  final ChallengeFailureReason reason;

  ChallengeFailedException({
    required super.requestOptions,
    required this.reason,
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

/// Thrown when retries have been exhausted and no fallback produced a value.
final class AllAttemptsExhaustedException extends DioResilienceException {
  final int attempts;

  AllAttemptsExhaustedException({
    required super.requestOptions,
    required this.attempts,
    super.response,
    super.error,
    super.stackTrace,
  }) : super(message: 'All $attempts retry attempts exhausted.');
}
