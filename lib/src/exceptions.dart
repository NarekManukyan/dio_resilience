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

/// Thrown when the pipeline's total time budget is exhausted across attempts.
final class PipelineTimeoutException extends DioResilienceException {
  final Duration budget;

  PipelineTimeoutException({
    required super.requestOptions,
    required this.budget,
    super.stackTrace,
  }) : super(message: 'Pipeline timeout after ${budget.inMilliseconds}ms.');
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
