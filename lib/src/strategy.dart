import 'package:dio/dio.dart';

import 'pipeline_context.dart';

/// Outcome an error hook can request from the pipeline.
///
/// Sub-types ([ReplayDecision], [RespondDecision], [FailDecision]) are public
/// so the pipeline can pattern-match on them across files.
sealed class StrategyDecision {
  const StrategyDecision();

  /// Re-run the request. The pipeline waits [delay], then dispatches the same
  /// [RequestOptions] through Dio again. When [countsAsAttempt] is true (a
  /// retry) it increments [PipelineContext.attemptNumber]; a replay that
  /// only fixes the request (a refreshed token, a solved challenge) passes
  /// false so it doesn't use up the retry budget.
  const factory StrategyDecision.replay({
    Duration? delay,
    bool countsAsAttempt,
  }) = ReplayDecision;

  /// Substitute a successful response (used by fallback).
  const factory StrategyDecision.respond(Response<dynamic> response) =
      RespondDecision;

  /// Give up with a custom exception. Strategies after the one that decided
  /// (fallback) still get to handle [error]; if none does, the caller gets
  /// it.
  const factory StrategyDecision.fail(DioException error) = FailDecision;
}

/// "Replay this request" — see [StrategyDecision.replay].
final class ReplayDecision extends StrategyDecision {
  final Duration? delay;
  final bool countsAsAttempt;
  const ReplayDecision({this.delay, this.countsAsAttempt = true});
}

/// "Use this response instead" — see [StrategyDecision.respond].
final class RespondDecision extends StrategyDecision {
  final Response<dynamic> response;
  const RespondDecision(this.response);
}

/// "Fail with this exception" — see [StrategyDecision.fail].
final class FailDecision extends StrategyDecision {
  final DioException error;
  const FailDecision(this.error);
}

/// A resilience strategy. Strategies are composed by the pipeline in a fixed
/// order and coordinate via [PipelineContext].
///
/// Strategies should `extends ResilienceStrategy` so they inherit empty
/// default implementations of any hooks they don't need.
abstract class ResilienceStrategy {
  const ResilienceStrategy();

  /// Stable name used in logs and as the metrics key.
  String get name;

  /// Called once per logical request, before any strategy's [onRequest].
  /// Resolve per-request settings other strategies read from the context
  /// here (the timeout strategy sets [PipelineContext.totalBudget]).
  void onStart(PipelineContext ctx) {}

  /// Called before each request attempt is dispatched.
  Future<void> onRequest(PipelineContext ctx) async {}

  /// Called when the request has finished, however it ended (a response, a
  /// failure, a cancellation). Give back here anything [onRequest] took that
  /// no outcome released, such as a circuit breaker's half-open probe slot.
  /// May be called more than once for a request; make it idempotent.
  void onEnd(PipelineContext ctx) {}

  /// Called after a response is received successfully.
  Future<void> onResponse(
    PipelineContext ctx,
    Response<dynamic> response,
  ) async {}

  /// Called when a request errors. Return `null` to defer to the next
  /// strategy, or return a [StrategyDecision] to direct the pipeline.
  ///
  /// Not called for a cancelled request. After a [FailDecision], only the
  /// strategies after the deciding one are called, with the new error.
  Future<StrategyDecision?> onError(
    PipelineContext ctx,
    DioException error,
  ) async =>
      null;

  /// Called by the pipeline instead of the standard `handler.next(options)`
  /// dispatch when any strategy returns a non-null future here.
  ///
  /// Override this to intercept the actual HTTP dispatch — for example, hedging
  /// fires multiple parallel requests and races them. Return `null` (the
  /// default) to let the pipeline proceed with its standard single dispatch.
  ///
  /// Only the first strategy in the list that returns non-null takes effect.
  ///
  /// The [doRequest] closure accepts an optional [RequestOptions] override.
  /// When non-null, the provided options are used for that fetch instead of
  /// [PipelineContext.request]. Strategies that fire multiple branches (e.g.
  /// hedging) should pass a per-branch clone so that Dio's internal reference
  /// to the options object is isolated from concurrent mutations.
  Future<Response<dynamic>>? onDispatch(
    PipelineContext ctx,
    Future<Response<dynamic>> Function([RequestOptions? options]) doRequest,
  ) =>
      null;
}
