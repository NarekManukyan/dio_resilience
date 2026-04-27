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
}
