import 'package:dio/dio.dart';

import '../options_extension.dart';
import '../overrides.dart';
import '../pipeline_context.dart';
import '../strategy.dart';

/// Strategy that enforces per-attempt and total request timeouts.
///
/// Behavior:
/// - Sets [PipelineContext.totalBudget] from [totalBudget]. The pipeline
///   treats it as a deadline: an attempt still in flight when it passes is
///   cancelled, a retry that wouldn't fit before it isn't sent, and either
///   way the caller gets a [PipelineTimeoutException].
/// - On each attempt, lowers Dio's `connectTimeout` and `receiveTimeout` to
///   [perAttempt] when they are longer or unset. `sendTimeout` is left
///   alone: Dio times the whole request body with it, so a per-attempt value
///   would fail any large upload.
/// - Honors per-request overrides ([TimeoutOverride.disabled],
///   [TimeoutOverride.total], [TimeoutOverride.perAttempt]).
final class TimeoutStrategy extends ResilienceStrategy {
  /// Total time budget across all attempts.
  final Duration? totalBudget;

  /// Per-attempt cap on Dio's connect and receive timeouts.
  final Duration? perAttempt;

  @override
  String get name => 'timeout';

  /// Creates a [TimeoutStrategy].
  ///
  /// - [totalBudget]: Deadline for the whole request, retries included.
  /// - [perAttempt]: Cap on each attempt's connect and receive timeouts.
  const TimeoutStrategy({
    this.totalBudget,
    this.perAttempt,
  });

  @override
  void onStart(PipelineContext ctx) {
    final override = overridesFor(ctx.request)?.timeout;
    ctx.totalBudget = switch (override) {
      null => totalBudget,
      TimeoutDisabled() => null,
      TimeoutTotal(duration: final d) => d,
      // Per-attempt doesn't affect total.
      TimeoutPerAttempt() => totalBudget,
    };
  }

  @override
  Future<void> onRequest(PipelineContext ctx) async {
    final override = overridesFor(ctx.request)?.timeout;
    final effectivePerAttempt = switch (override) {
      null => perAttempt,
      TimeoutDisabled() => null,
      // Total doesn't affect per-attempt.
      TimeoutTotal() => perAttempt,
      TimeoutPerAttempt(duration: final d) => d,
    };
    if (effectivePerAttempt != null) {
      _applyPerAttemptTimeout(ctx.request, effectivePerAttempt);
    }
  }

  /// Apply per-attempt timeout to Dio request, only shortening (not extending).
  void _applyPerAttemptTimeout(RequestOptions request, Duration timeout) {
    final receive = request.receiveTimeout;
    if (receive == null || receive == Duration.zero || timeout < receive) {
      request.receiveTimeout = timeout;
    }

    final connect = request.connectTimeout;
    if (connect == null || connect == Duration.zero || timeout < connect) {
      request.connectTimeout = timeout;
    }
  }
}
