import 'package:dio/dio.dart';

import 'pipeline_context.dart';

/// Outcome an error hook can request from the pipeline.
///
/// Sub-types ([ReplayDecision], [RespondDecision], [FailDecision]) are public
/// so the pipeline can pattern-match on them across files.
sealed class StrategyDecision {
  const StrategyDecision();

  /// Re-run the request. The pipeline increments
  /// [PipelineContext.attemptNumber] and dispatches through Dio again. The
  /// optional [delay] is honored before the replay fires.
  const factory StrategyDecision.replay({Duration? delay}) = ReplayDecision;

  /// Substitute a successful response (used by fallback).
  const factory StrategyDecision.respond(Response<dynamic> response) =
      RespondDecision;

  /// Give up with a custom exception. The pipeline propagates this to the
  /// caller.
  const factory StrategyDecision.fail(DioException error) = FailDecision;
}

/// "Replay this request" — see [StrategyDecision.replay].
final class ReplayDecision extends StrategyDecision {
  final Duration? delay;
  const ReplayDecision({this.delay});
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

  /// Called before each request attempt is dispatched.
  Future<void> onRequest(PipelineContext ctx) async {}

  /// Called after a response is received successfully.
  Future<void> onResponse(
    PipelineContext ctx,
    Response<dynamic> response,
  ) async {}

  /// Called when a request errors. Return `null` to defer to the next
  /// strategy, or return a [StrategyDecision] to direct the pipeline.
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
