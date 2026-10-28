import 'dart:async';

import 'package:dio/dio.dart';

import '../options_extension.dart';
import '../overrides.dart';
import '../pipeline_context.dart';
import '../strategy.dart';

/// Strategy that fires multiple parallel ("hedged") requests and races them,
/// returning the first successful response and cancelling all losers.
///
/// Design: pre-dispatch hedging (option a).
///
/// Hedging is wired in as an `onDispatch` override. When the pipeline reaches
/// the point of dispatching the HTTP call (`handler.next`), any strategy that
/// returns non-null from `onDispatch` takes ownership of the actual fetch.
/// `HedgingStrategy` uses this hook to:
///   1. Fire the primary request immediately.
///   2. After [delay], if the primary hasn't completed, fire hedge #2.
///   3. After another [delay], if still outstanding, fire hedge #3
///      (up to [maxParallel] total branches).
///   4. Return the first successful response; cancel the rest.
///
/// Why option (a) over (b):
///   - Hedging is not an error-recovery mechanism — it fires *during* a slow
///     but still in-flight request. Implementing it on the error path (b)
///     requires artificial timeouts and can't cancel the slow primary.
///   - Intercepting at dispatch time gives us full control over `CancelToken`
///     for every branch, including the primary, so losers are always cleaned up.
///   - The implementation is simpler and semantically clean: the caller sees a
///     single response as if only one request was made.
///
/// Hedging counts as ONE attempt for retry-strategy bookkeeping: all branches
/// share the same `ctx.attemptNumber`. If retry is also enabled, hedging runs
/// within each retry attempt independently.
///
/// Default [shouldHedge] predicate: only GET and HEAD requests (idempotent;
/// safe to fire multiple times with no side-effects).
final class HedgingStrategy extends ResilienceStrategy {
  @override
  String get name => 'hedging';

  /// Maximum total parallel branches, including the initial request.
  ///
  /// Must be >= 1. A value of 1 means no hedging (only the primary fires).
  final int maxParallel;

  /// Time to wait after the previous branch is fired before launching the next.
  ///
  /// E.g. with delay = 100ms and maxParallel = 3:
  ///   t=0ms   → primary fires
  ///   t=100ms → hedge #2 fires (if primary not done)
  ///   t=200ms → hedge #3 fires (if neither done)
  final Duration delay;

  /// Predicate deciding whether this request should be hedged at all.
  ///
  /// Defaults to `_defaultShouldHedge` (GET and HEAD only).
  final bool Function(RequestOptions) shouldHedge;

  HedgingStrategy({
    this.maxParallel = 2,
    this.delay = const Duration(milliseconds: 100),
    bool Function(RequestOptions)? shouldHedge,
  })  : assert(maxParallel >= 1, 'maxParallel must be >= 1'),
        shouldHedge = shouldHedge ?? _defaultShouldHedge;

  /// Default predicate: only GET and HEAD are idempotent enough to hedge.
  static bool _defaultShouldHedge(RequestOptions options) {
    final method = options.method.toUpperCase();
    return method == 'GET' || method == 'HEAD';
  }

  @override
  Future<Response<dynamic>>? onDispatch(
    PipelineContext ctx,
    Future<Response<dynamic>> Function([RequestOptions? options]) doRequest,
  ) {
    // Check per-request override first.
    final override = overridesFor(ctx.request)?.hedging;
    if (override is HedgingDisabled) {
      return null; // Opt out: let pipeline do standard dispatch.
    }

    // Determine effective config from override.
    final effectiveMax = _effectiveMaxParallel(override);
    final effectiveDelay = _effectiveDelay(override);

    // If the request is not eligible for hedging, skip.
    if (!shouldHedge(ctx.request)) {
      return null;
    }

    // maxParallel == 1 means "no hedging", fall through to normal dispatch.
    if (effectiveMax <= 1) {
      return null;
    }

    return _runHedged(ctx, doRequest, effectiveMax, effectiveDelay);
  }

  /// Core hedging logic: fire branches with inter-hedge [delay], race for the
  /// first success, cancel losers.
  Future<Response<dynamic>> _runHedged(
    PipelineContext ctx,
    Future<Response<dynamic>> Function([RequestOptions? options]) doRequest,
    int effectiveMax,
    Duration effectiveDelay,
  ) async {
    // Completer that resolves with the winning response (or the last error).
    final winner = Completer<Response<dynamic>>();

    // Track all in-flight cancel tokens so we can abort losers.
    final cancelTokens = <CancelToken>[];

    // The caller's cancellation (or the pipeline's deadline) ends the whole
    // round: cancel every branch and fail with that cancellation.
    final parentToken = ctx.request.cancelToken;
    if (parentToken != null) {
      unawaited(
        parentToken.whenCancel.then((cancel) {
          if (winner.isCompleted) return;
          winner.completeError(cancel.copyWith(requestOptions: ctx.request));
          for (final token in cancelTokens) {
            if (!token.isCancelled) token.cancel(cancel.error);
          }
        }),
      );
    }

    // Number of branches that have settled (either succeeded or errored).
    var settled = 0;

    // Last error — used if every branch fails.
    DioException? lastError;

    void onBranchSuccess(Response<dynamic> response) {
      if (winner.isCompleted) return;
      winner.complete(response);
      // Cancel all other in-flight branches.
      for (final token in cancelTokens) {
        if (!token.isCancelled) {
          token.cancel('hedging winner resolved');
        }
      }
    }

    // Number of branches that have been *launched* so far (primary + any
    // hedges that fired). Distinct from `cancelTokens.length` because a
    // launched branch only adds its token after entering `launchBranch`.
    var launched = 0;
    var allBranchesScheduled = false;

    void onBranchError(Object error, StackTrace st) {
      settled++;
      if (error is DioException) {
        // Swallow cancellation errors from our own cancel-token cleanup.
        if (error.type == DioExceptionType.cancel) {
          settled--; // Cancellation doesn't count as a real failure.
          return;
        }
        lastError = error;
      }

      if (!winner.isCompleted && allBranchesScheduled && settled >= launched) {
        // Every branch that will ever be launched has now settled and none
        // succeeded — propagate the last error.
        winner.completeError(lastError ?? error, st);
      }
    }

    Future<void> launchBranch() async {
      if (winner.isCompleted) return;
      if (parentToken != null && parentToken.isCancelled) return;

      launched++;
      final token = CancelToken();
      cancelTokens.add(token);

      // Clone the shared RequestOptions for this branch so each branch
      // carries its own CancelToken: losers can be cancelled independently
      // without touching the shared ctx.request. The pipeline sends the
      // branch past its strategies, so it is never hedged or retried itself.
      final branchOptions = ctx.request.copyWith(cancelToken: token);

      try {
        final response = await doRequest(branchOptions);
        onBranchSuccess(response);
      } on DioException catch (e, st) {
        onBranchError(e, st);
      } catch (e, st) {
        onBranchError(e, st);
      }
    }

    // Launch primary immediately (branch index 0).
    unawaited(launchBranch());

    // Schedule additional hedge branches with increasing delays. Track how
    // many have either fired or were skipped (because the winner already
    // resolved successfully) so that we know when "all branches that will
    // ever launch" have settled.
    final hedgeCount = effectiveMax - 1;
    if (hedgeCount == 0) {
      allBranchesScheduled = true;
    } else {
      var hedgesProcessed = 0;
      void markHedgeProcessed() {
        hedgesProcessed++;
        if (hedgesProcessed >= hedgeCount) {
          allBranchesScheduled = true;
          // Re-evaluate the all-failed condition in case the last branch
          // already errored before we flipped the flag.
          if (!winner.isCompleted && settled >= launched && lastError != null) {
            winner.completeError(lastError!);
          }
        }
      }

      for (var i = 1; i < effectiveMax; i++) {
        final hedgeIndex = i;
        unawaited(
          Future<void>.delayed(effectiveDelay * hedgeIndex).then((_) async {
            if (winner.isCompleted) {
              // A branch already won (success). Skip launching this hedge.
              markHedgeProcessed();
              return;
            }
            // Launch this hedge branch and mark scheduling-done after it
            // settles, so onBranchError can decide whether to fail the
            // whole hedging round.
            await launchBranch();
            markHedgeProcessed();
          }),
        );
      }
    }

    return winner.future;
  }

  int _effectiveMaxParallel(HedgingOverride? override) {
    return switch (override) {
      null => maxParallel,
      HedgingDisabled() => 1, // Should not reach here — handled above.
      HedgingMaxParallel(n: final n) => n,
      HedgingDelay() => maxParallel,
    };
  }

  Duration _effectiveDelay(HedgingOverride? override) {
    return switch (override) {
      null => delay,
      HedgingDisabled() => delay,
      HedgingMaxParallel() => delay,
      HedgingDelay(d: final d) => d,
    };
  }
}
