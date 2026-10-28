import 'dart:math';

import 'package:dio_resilience/dio_resilience.dart';
import 'package:flutter/foundation.dart';

/// Tracks the numbers a README "statistics" screenshot wants to show:
/// requests actually sent on the wire vs. logical calls the app made,
/// retries, refreshes, fallbacks, failures by type, and latency percentiles.
class DemoStats extends ChangeNotifier {
  int logicalCalls = 0;
  int wireRequests = 0;
  int retries = 0;
  int refreshes = 0;
  int fallbacksUsed = 0;
  final Map<String, int> failuresByType = {};
  final List<Duration> _latencies = [];

  void reset() {
    logicalCalls = 0;
    wireRequests = 0;
    retries = 0;
    refreshes = 0;
    fallbacksUsed = 0;
    failuresByType.clear();
    _latencies.clear();
    notifyListeners();
  }

  void recordWireRequest() {
    wireRequests++;
    notifyListeners();
  }

  /// Call once per logical (caller-level) request, success or failure.
  void recordLogicalCall(Duration latency, {Object? error}) {
    logicalCalls++;
    _latencies.add(latency);
    if (error != null) {
      final key = error.runtimeType.toString();
      failuresByType[key] = (failuresByType[key] ?? 0) + 1;
    }
    notifyListeners();
  }

  /// Pass this to `.onEvent(...)` on a pipeline builder.
  void onEvent(ResilienceEvent event) {
    switch (event) {
      case ReplayEvent(:final strategy):
        if (strategy == 'retry') retries++;
        if (strategy == 'auth') refreshes++;
        notifyListeners();
      case RecoveredEvent(:final strategy):
        if (strategy == 'fallback') fallbacksUsed++;
        notifyListeners();
      case GaveUpEvent():
      case CircuitStateChangedEvent():
        break;
    }
  }

  Duration? get p50 => _percentile(0.5);
  Duration? get p95 => _percentile(0.95);

  Duration? _percentile(double p) {
    if (_latencies.isEmpty) return null;
    final sorted = [..._latencies]..sort();
    final index = min(sorted.length - 1, (sorted.length * p).floor());
    return sorted[index];
  }
}
