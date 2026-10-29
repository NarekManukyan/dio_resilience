import 'package:dio/dio.dart';

import 'strategies/circuit_breaker_strategy.dart';

/// Something the pipeline did, reported to the `onEvent` callback given to
/// [ResiliencePipelineBuilder.onEvent]. Use it for logs and metrics.
sealed class ResilienceEvent {
  const ResilienceEvent();
}

/// A strategy asked for [request] to be sent again after [error].
final class ReplayEvent extends ResilienceEvent {
  /// The deciding strategy's [ResilienceStrategy.name] (`retry`, `auth`,
  /// `challenge`, …).
  final String strategy;
  final RequestOptions request;
  final DioException error;

  /// [PipelineContext.attemptNumber] of the attempt about to be sent.
  final int attemptNumber;
  final Duration delay;

  const ReplayEvent({
    required this.strategy,
    required this.request,
    required this.error,
    required this.attemptNumber,
    required this.delay,
  });
}

/// A strategy answered [request] with a substitute response after [error]
/// (a fallback).
final class RecoveredEvent extends ResilienceEvent {
  final String strategy;
  final RequestOptions request;
  final DioException error;
  final Response<dynamic> response;

  const RecoveredEvent({
    required this.strategy,
    required this.request,
    required this.error,
    required this.response,
  });
}

/// [request] failed for good with [error], after every strategy had its
/// turn. [error] is what the caller receives.
final class GaveUpEvent extends ResilienceEvent {
  final RequestOptions request;
  final DioException error;

  const GaveUpEvent({required this.request, required this.error});
}

/// The circuit for [key] moved from [from] to [to].
final class CircuitStateChangedEvent extends ResilienceEvent {
  final String key;
  final CircuitPhase from;
  final CircuitPhase to;

  const CircuitStateChangedEvent({
    required this.key,
    required this.from,
    required this.to,
  });
}
