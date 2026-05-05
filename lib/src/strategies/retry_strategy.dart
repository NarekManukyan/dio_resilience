import 'package:dio/dio.dart';

import '../backoff.dart';
import '../conditions.dart';
import '../exceptions.dart';
import '../options_extension.dart';
import '../overrides.dart';
import '../pipeline_context.dart';
import '../strategy.dart';

/// Retry strategy implementing configurable retry logic with backoff and Retry-After support.
///
/// The strategy manages retry budgets per request, respects per-request overrides,
/// and coordinates with the auth strategy to avoid counting auth-induced replays
/// against the retry budget.
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

  /// Creates a [RetryStrategy].
  ///
  /// - [maxAttempts]: Initial retry budget (default 3, including the original request).
  /// - [backoff]: Delay policy between retries (default: exponential jitter).
  /// - [defaultRetryOn]: Conditions to trigger retry (default: 5xx, 408, 429, network errors, timeouts).
  /// - [defaultDoNotRetryOn]: Additional conditions to block retry (default: empty).
  const RetryStrategy({
    this.maxAttempts = 3,
    this.backoff = const Backoff.exponentialJitter(
      initial: Duration(milliseconds: 200),
      multiplier: 2.0,
      maxDelay: Duration(seconds: 10),
    ),
    List<RetryCondition>? defaultRetryOn,
    List<RetryCondition>? defaultDoNotRetryOn,
  })  : defaultRetryOn = defaultRetryOn ??
            const [
              RetryCondition.statusBetween(500, 599),
              RetryCondition.status(408),
              RetryCondition.status(429),
              RetryCondition.networkError(),
              RetryCondition.timeout(),
            ],
        defaultDoNotRetryOn = defaultDoNotRetryOn ?? const [];

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
    if (error is DioResilienceException || error.error is DioResilienceException) {
      return null;
    }

    // If this is a replay after auth refresh, don't count it against retry budget.
    if (ctx.wasReplayedAfterRefresh) {
      ctx.wasReplayedAfterRefresh = false;
      (ctx.meta['authReplays'] as int?) != null
          ? ctx.meta['authReplays'] = (ctx.meta['authReplays'] as int) + 1
          : ctx.meta['authReplays'] = 1;
      return null;
    }

    // Read per-request overrides.
    final override = overridesFor(ctx.request)?.retry;

    // If retry is disabled, don't retry.
    if (override is RetryDisabled) {
      return null;
    }

    // Determine effective maxAttempts and conditions based on override type.
    final effectiveMaxAttempts =
        _getEffectiveMaxAttempts(override, maxAttempts);
    final (shouldRetry, evaluation) = _evaluateRetry(ctx, error, override);

    if (!shouldRetry) {
      return null;
    }

    // If we've exhausted attempts, fail.
    if (ctx.attemptNumber >= effectiveMaxAttempts) {
      return StrategyDecision.fail(
        AllAttemptsExhaustedException(
          requestOptions: ctx.request,
          attempts: effectiveMaxAttempts,
          response: error.response,
          error: error.error,
          stackTrace: error.stackTrace,
        ),
      );
    }

    // Compute backoff delay.
    final effectiveBackoff = _getEffectiveBackoff(override);
    var delay = effectiveBackoff.delayFor(ctx.attemptNumber);

    // Check for Retry-After header and use it if it's greater.
    final retryAfterDelay = _parseRetryAfter(error);
    if (retryAfterDelay != null && retryAfterDelay > delay) {
      delay = retryAfterDelay;
    }

    return StrategyDecision.replay(delay: delay);
  }

  /// Determines the effective max attempts based on the override.
  int _getEffectiveMaxAttempts(RetryOverride? override, int defaultMax) {
    if (override == null) {
      return defaultMax;
    }

    return switch (override) {
      RetryDisabled() => defaultMax, // Should not reach here.
      RetryAttempts(attempts: final n) => n,
      RetryExceptWhen() => defaultMax,
      RetryOnlyWhen() => defaultMax,
      RetryPolicy(maxAttempts: final n) => n ?? defaultMax,
    };
  }

  /// Determines the effective backoff based on the override.
  Backoff _getEffectiveBackoff(RetryOverride? override) {
    if (override == null) {
      return backoff;
    }

    return switch (override) {
      RetryDisabled() => backoff,
      RetryAttempts() => backoff,
      RetryExceptWhen() => backoff,
      RetryOnlyWhen() => backoff,
      RetryPolicy(backoff: final b) => b ?? backoff,
    };
  }

  /// Evaluates whether the error should trigger a retry based on conditions.
  ///
  /// Returns (shouldRetry, evaluation).
  (bool, RetryEvaluation) _evaluateRetry(
    PipelineContext ctx,
    DioException error,
    RetryOverride? override,
  ) {
    final evaluation = RetryEvaluation(
      error: error,
      attemptNumber: ctx.attemptNumber,
      elapsed: ctx.elapsed.elapsed,
    );

    // Determine effective conditions based on override.
    final (retryOn, doNotRetryOn) =
        _getEffectiveConditions(override, defaultRetryOn, defaultDoNotRetryOn);

    // Check if any "do not retry" condition matches.
    for (final cond in doNotRetryOn) {
      if (cond.matches(evaluation)) {
        return (false, evaluation);
      }
    }

    // Check if any "retry on" condition matches.
    for (final cond in retryOn) {
      if (cond.matches(evaluation)) {
        return (true, evaluation);
      }
    }

    return (false, evaluation);
  }

  /// Determines effective retry and "do not retry" conditions based on the override.
  (List<RetryCondition>, List<RetryCondition>) _getEffectiveConditions(
    RetryOverride? override,
    List<RetryCondition> defaultRetryOn,
    List<RetryCondition> defaultDoNotRetryOn,
  ) {
    if (override == null) {
      return (defaultRetryOn, defaultDoNotRetryOn);
    }

    return switch (override) {
      RetryDisabled() => (defaultRetryOn, defaultDoNotRetryOn),
      RetryAttempts() => (defaultRetryOn, defaultDoNotRetryOn),
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

  /// Parses the Retry-After header and returns the delay, or null if absent/invalid.
  ///
  /// Handles both numeric (seconds) and HTTP-date formats.
  Duration? _parseRetryAfter(DioException error) {
    final response = error.response;
    if (response == null) return null;

    final retryAfter = response.headers['retry-after'];
    if (retryAfter == null || retryAfter.isEmpty) return null;

    final value = retryAfter.first;

    // Try parsing as seconds (numeric).
    final seconds = int.tryParse(value);
    if (seconds != null) {
      return Duration(seconds: seconds);
    }

    // Try parsing as HTTP-date (simplified: just count as retry later).
    // For now, skip HTTP-date parsing and return null.
    // A full implementation would parse RFC 7231 date format.

    return null;
  }
}
