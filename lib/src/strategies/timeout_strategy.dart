import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../options_extension.dart';
import '../overrides.dart';
import '../pipeline_context.dart';
import '../strategy.dart';

/// Strategy that enforces per-attempt and total request timeouts.
///
/// Behavior:
/// - On each request, applies [perAttempt] timeout to Dio's internal timeout fields
///   (sendTimeout, receiveTimeout, connectTimeout) if shorter than any existing values.
/// - Stores [totalBudget] in context metadata; the pipeline checks elapsed time
///   before each replay and throws [PipelineTimeoutException] if exceeded.
/// - Honors per-request overrides ([TimeoutOverride.disabled], [TimeoutOverride.total],
///   [TimeoutOverride.perAttempt]).
final class TimeoutStrategy extends ResilienceStrategy {
  /// Total time budget across all attempts.
  final Duration? totalBudget;

  /// Per-attempt timeout applied to Dio's send/receive/connect timeouts.
  final Duration? perAttempt;

  @override
  String get name => 'timeout';

  /// Creates a [TimeoutStrategy].
  ///
  /// - [totalBudget]: Maximum total elapsed time across all attempts.
  /// - [perAttempt]: Timeout applied to each individual request's Dio timeouts.
  const TimeoutStrategy({
    this.totalBudget,
    this.perAttempt,
  });

  @override
  Future<void> onRequest(PipelineContext ctx) async {
    final overrides = overridesFor(ctx.request);
    final timeoutOverride = overrides?.timeout;

    // Honor TimeoutOverride.disabled
    if (timeoutOverride is TimeoutDisabled) {
      return;
    }

    // Resolve effective timeouts from override or defaults
    final effectivePerAttempt = _getEffectivePerAttempt(timeoutOverride);
    final effectiveTotalBudget = _getEffectiveTotalBudget(timeoutOverride);

    // Store total budget in context metadata for pipeline enforcement
    if (effectiveTotalBudget != null) {
      ctx.meta['totalBudget'] = effectiveTotalBudget;
    }

    // Apply per-attempt timeout to Dio's request options
    if (effectivePerAttempt != null) {
      _applyPerAttemptTimeout(ctx.request, effectivePerAttempt);
    }
  }

  @override
  Future<void> onResponse(
    PipelineContext ctx,
    Response<dynamic> response,
  ) async {
    // No-op: successful response, timeout already enforced by request.
  }

  /// Resolve the effective per-attempt timeout from override or default.
  Duration? _getEffectivePerAttempt(TimeoutOverride? override) {
    if (override == null) {
      return perAttempt;
    }

    return switch (override) {
      TimeoutDisabled() => null,
      TimeoutTotal() => null, // Total doesn't affect per-attempt
      TimeoutPerAttempt(duration: final d) => d,
    };
  }

  /// Resolve the effective total budget from override or default.
  Duration? _getEffectiveTotalBudget(TimeoutOverride? override) {
    if (override == null) {
      return totalBudget;
    }

    return switch (override) {
      TimeoutDisabled() => null,
      TimeoutTotal(duration: final d) => d,
      TimeoutPerAttempt() => null, // Per-attempt doesn't affect total
    };
  }

  /// Apply per-attempt timeout to Dio request, only shortening (not extending).
  void _applyPerAttemptTimeout(RequestOptions request, Duration timeout) {
    // Only apply if the timeout is shorter than what's already set.
    // This respects any pre-configured Dio defaults.

    if (request.sendTimeout == null || timeout.inMilliseconds < request.sendTimeout!.inMilliseconds) {
      request.sendTimeout = timeout;
    }

    if (request.receiveTimeout == null || timeout.inMilliseconds < request.receiveTimeout!.inMilliseconds) {
      request.receiveTimeout = timeout;
    }

    if (request.connectTimeout == null || timeout.inMilliseconds < request.connectTimeout!.inMilliseconds) {
      request.connectTimeout = timeout;
    }
  }
}
