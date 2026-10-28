import 'package:dio/dio.dart';

import '../backoff.dart';
import '../conditions.dart';
import '../exceptions.dart';
import '../options_extension.dart';
import '../overrides.dart';
import '../pipeline_context.dart';
import '../strategy.dart';
import '../http_date.dart';

/// The HTTP methods RFC 9110 defines as idempotent: sending one twice has
/// the same effect as sending it once. The retry strategy's default.
const Set<String> kIdempotentMethods = {
  'GET',
  'HEAD',
  'OPTIONS',
  'TRACE',
  'PUT',
  'DELETE',
};

/// Longest `Retry-After` the retry strategy waits by default.
const Duration kDefaultMaxRetryAfter = Duration(seconds: 30);

/// Retry strategy implementing configurable retry logic with backoff and Retry-After support.
///
/// The strategy manages retry budgets per request and respects per-request
/// overrides. Replays other strategies ask for (an auth refresh, a solved
/// challenge) don't count against its budget.
final class RetryStrategy extends ResilienceStrategy {
  @override
  String get name => 'retry';

  /// Maximum number of attempts (including the initial request).
  final int maxAttempts;

  /// Backoff policy controlling delay between retries.
  final Backoff backoff;

  /// Conditions to retry on by default (if no override is set).
  final List<RetryCondition> defaultRetryOn;

  /// Conditions to skip retry on by default (if no override is set).
  final List<RetryCondition> defaultDoNotRetryOn;

  /// HTTP methods that may be retried, upper case. Null retries any method.
  final Set<String>? methods;

  /// Longest `Retry-After` to wait. A longer one ends the request with the
  /// server's answer. Null waits any.
  final Duration? maxRetryAfter;

  /// Clock for HTTP-date `Retry-After` values. Defaults to [DateTime.now].
  final DateTime Function() now;

  /// Creates a [RetryStrategy].
  ///
  /// - [maxAttempts]: Initial retry budget (default 3, including the original request).
  /// - [backoff]: Delay policy between retries (default: exponential jitter).
  /// - [defaultRetryOn]: Conditions to trigger retry (default: 5xx, 408, 429, network errors, timeouts).
  /// - [defaultDoNotRetryOn]: Additional conditions to block retry (default: empty).
  /// - [methods]: Retryable HTTP methods (default: [kIdempotentMethods]).
  /// - [maxRetryAfter]: Longest `Retry-After` to wait (default: [kDefaultMaxRetryAfter]).
  RetryStrategy({
    this.maxAttempts = 3,
    this.backoff = const Backoff.exponentialJitter(
      initial: Duration(milliseconds: 200),
      multiplier: 2.0,
      maxDelay: Duration(seconds: 10),
    ),
    List<RetryCondition>? defaultRetryOn,
    List<RetryCondition>? defaultDoNotRetryOn,
    this.methods = kIdempotentMethods,
    this.maxRetryAfter = kDefaultMaxRetryAfter,
    DateTime Function()? now,
  })  : defaultRetryOn = defaultRetryOn ??
            const [
              RetryCondition.statusBetween(500, 599),
              RetryCondition.status(408),
              RetryCondition.status(429),
              RetryCondition.networkError(),
              RetryCondition.timeout(),
            ],
        defaultDoNotRetryOn = defaultDoNotRetryOn ?? const [],
        now = now ?? DateTime.now;

  @override
  Future<StrategyDecision?> onError(
    PipelineContext ctx,
    DioException error,
  ) async {
    // Never retry cancellations.
    if (error.type == DioExceptionType.cancel) {
      return null;
    }

    // Never retry on resilience-internal failures (circuit open, rate limit,
    // refresh failed, pipeline timeout). These are terminal decisions made by
    // sibling strategies — replaying them would either short-circuit again or
    // defeat the strategy's intent.
    if (error is DioResilienceException ||
        error.error is DioResilienceException) {
      return null;
    }

    // Read per-request overrides.
    final override = overridesFor(ctx.request)?.retry;

    // If retry is disabled, don't retry.
    if (override is RetryDisabled) {
      return null;
    }

    if (!_methodAllowed(ctx.request.method, override)) {
      return null;
    }

    final effectiveMaxAttempts =
        _getEffectiveMaxAttempts(override, maxAttempts);
    if (!_shouldRetry(ctx, error, override)) {
      return null;
    }

    // If we've exhausted attempts, fail.
    if (ctx.attemptNumber >= effectiveMaxAttempts) {
      return StrategyDecision.fail(
        AllAttemptsExhaustedException(
          requestOptions: ctx.request,
          attempts: effectiveMaxAttempts,
          lastError: error,
          stackTrace: error.stackTrace,
        ),
      );
    }

    var delay = _getEffectiveBackoff(override).delayFor(ctx.attemptNumber);

    // Honour Retry-After when it asks for longer than the backoff, unless
    // it asks for longer than we're willing to wait.
    final retryAfter = _parseRetryAfter(error);
    if (retryAfter != null) {
      final cap = maxRetryAfter;
      if (cap != null && retryAfter > cap) {
        return null;
      }
      if (retryAfter > delay) {
        delay = retryAfter;
      }
    }

    return StrategyDecision.replay(delay: delay);
  }

  bool _methodAllowed(String method, RetryOverride? override) {
    final allowed = switch (override) {
      RetryPolicy(methods: final m?) => m,
      _ => methods,
    };
    if (allowed == null) return true;
    final upper = method.toUpperCase();
    return allowed.any((m) => m.toUpperCase() == upper);
  }

  /// Determines the effective max attempts based on the override.
  int _getEffectiveMaxAttempts(RetryOverride? override, int defaultMax) {
    return switch (override) {
      null ||
      RetryDisabled() ||
      RetryExceptWhen() ||
      RetryOnlyWhen() =>
        defaultMax,
      RetryAttempts(attempts: final n) => n,
      RetryPolicy(maxAttempts: final n) => n ?? defaultMax,
    };
  }

  /// Determines the effective backoff based on the override.
  Backoff _getEffectiveBackoff(RetryOverride? override) {
    return switch (override) {
      RetryPolicy(backoff: final b?) => b,
      _ => backoff,
    };
  }

  /// Whether [error] matches the effective retry conditions.
  bool _shouldRetry(
    PipelineContext ctx,
    DioException error,
    RetryOverride? override,
  ) {
    final evaluation = RetryEvaluation(
      error: error,
      attemptNumber: ctx.attemptNumber,
      elapsed: ctx.elapsed.elapsed,
    );

    final (retryOn, doNotRetryOn) =
        _getEffectiveConditions(override, defaultRetryOn, defaultDoNotRetryOn);

    for (final cond in doNotRetryOn) {
      if (cond.matches(evaluation)) return false;
    }
    for (final cond in retryOn) {
      if (cond.matches(evaluation)) return true;
    }
    return false;
  }

  /// Determines effective retry and "do not retry" conditions based on the override.
  (List<RetryCondition>, List<RetryCondition>) _getEffectiveConditions(
    RetryOverride? override,
    List<RetryCondition> defaultRetryOn,
    List<RetryCondition> defaultDoNotRetryOn,
  ) {
    return switch (override) {
      null || RetryDisabled() || RetryAttempts() => (
          defaultRetryOn,
          defaultDoNotRetryOn,
        ),
      RetryExceptWhen(conditions: final conds) => (
          defaultRetryOn,
          [...defaultDoNotRetryOn, ...conds],
        ),
      RetryOnlyWhen(conditions: final conds) => (conds, defaultDoNotRetryOn),
      RetryPolicy(
        retryOn: final customRetry,
        doNotRetryOn: final customDoNotRetry,
      ) =>
        (
          customRetry ?? defaultRetryOn,
          customDoNotRetry ?? defaultDoNotRetryOn,
        ),
    };
  }

  /// Parses the Retry-After header: delay-seconds or an HTTP-date. Null when
  /// absent or unreadable. A date in the past reads as zero.
  Duration? _parseRetryAfter(DioException error) {
    final value = error.response?.headers['retry-after']?.firstOrNull?.trim();
    if (value == null || value.isEmpty) return null;

    final seconds = int.tryParse(value);
    if (seconds != null) {
      return seconds < 0 ? null : Duration(seconds: seconds);
    }

    final date = parseHttpDate(value);
    if (date == null) return null;
    final wait = date.difference(now().toUtc());
    return wait.isNegative ? Duration.zero : wait;
  }
}
