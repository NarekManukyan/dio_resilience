import 'package:dio/dio.dart';

/// Phase of the auth strategy for the lifetime of a single request.
enum AuthPhase { idle, refreshing, refreshFailed, succeeded }

/// Mutable context shared across all strategies for a single logical
/// request. Strategies read from and write to this so they can coordinate
/// without knowing about each other.
class PipelineContext {
  /// The original request options. Strategies may mutate the headers map
  /// on this (e.g. to inject `Authorization`).
  final RequestOptions request;

  /// Stopwatch tracking elapsed time across all attempts. Used by the
  /// timeout strategy to enforce a total budget.
  final Stopwatch elapsed = Stopwatch()..start();

  /// 1-indexed retry attempt counter, starting at 1 for the original call.
  int attemptNumber = 1;

  /// Auth phase for this request.
  AuthPhase authPhase = AuthPhase.idle;

  /// Set true by the auth strategy when this attempt is being replayed
  /// after a successful token refresh. The retry strategy uses this signal
  /// to *not* count the auth-induced replay against the retry budget.
  bool wasReplayedAfterRefresh = false;

  /// Optional metadata attached by strategies for logging / metrics.
  final Map<String, Object?> meta = {};

  PipelineContext(this.request);
}
