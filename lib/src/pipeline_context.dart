import 'dart:async';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

/// Mutable context shared across all strategies for a single logical
/// request. Strategies read from and write to this so they can coordinate
/// without knowing about each other.
class PipelineContext {
  /// The request options being sent. Strategies may mutate the headers map
  /// on this (e.g. to inject `Authorization`). Every replay re-sends this
  /// object; if an interceptor ahead of the pipeline hands a replay on as a
  /// copy, this becomes that copy.
  RequestOptions get request => _request;
  RequestOptions _request;

  /// Stopwatch tracking elapsed time across all attempts. Used by the
  /// timeout strategy to enforce a total budget.
  final Stopwatch elapsed = Stopwatch()..start();

  /// 1-indexed attempt counter used by the retry budget, starting at 1 for
  /// the original call. Replays that don't count as an attempt (an auth
  /// refresh, a solved challenge) leave it alone; see [replayCount].
  int attemptNumber = 1;

  /// Every replay of this request, whichever strategy asked for it.
  int replayCount = 0;

  /// Total time budget across all attempts, or null for none. Resolved by
  /// the timeout strategy before any strategy's `onRequest` runs.
  Duration? totalBudget;

  /// True while the pipeline handles a response or error that a challenge
  /// strategy will answer. Set for every response and error before any
  /// strategy sees it. Lets other strategies (the circuit breaker) skip
  /// server-issued challenges in their accounting.
  bool isChallengeError = false;

  /// Optional metadata attached by strategies for logging / metrics.
  final Map<String, Object?> meta = {};

  PipelineContext(RequestOptions request) : _request = request;

  /// Time left of [totalBudget], or null without a budget. Never negative.
  Duration? get remainingBudget {
    final budget = totalBudget;
    if (budget == null) return null;
    final left = budget - elapsed.elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// True once [totalBudget] has run out.
  bool get isBudgetExhausted {
    final budget = totalBudget;
    return budget != null && elapsed.elapsed >= budget;
  }

  // ----- Pipeline bookkeeping (not for strategies) -------------------------

  /// True while the pipeline waits on a replay it dispatched; the nested
  /// dispatch hands its outcome back instead of deciding on it.
  @internal
  bool replayInFlight = false;

  /// True once the request has finished; a later `fetch` of the same
  /// options starts a fresh context.
  @internal
  bool settled = false;

  /// True while an attempt is on the wire, the only time the deadline may
  /// cancel it.
  @internal
  bool attemptInFlight = false;

  /// Set when the deadline passed.
  @internal
  bool deadlineReached = false;

  /// The caller's own cancel token, restored on the request between
  /// attempts.
  @internal
  CancelToken? callerToken;

  /// The token of the attempt on the wire, which the deadline cancels.
  @internal
  CancelToken? attemptToken;

  @internal
  Timer? deadlineTimer;

  /// Points the context at [options], the copy of [request] an interceptor
  /// ahead of the pipeline handed a replay on as.
  @internal
  void rebind(RequestOptions options) => _request = options;

  /// Stops the deadline timer. Called once the request has finished.
  @internal
  void settle() {
    settled = true;
    deadlineTimer?.cancel();
    deadlineTimer = null;
  }
}
