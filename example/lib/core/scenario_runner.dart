import 'package:dio/dio.dart';

import 'demo_stats.dart';
import 'event_log.dart';

/// The outcome of one logical call, for the on-screen outcome card.
sealed class ScenarioOutcome {
  const ScenarioOutcome();
}

final class ScenarioSuccess extends ScenarioOutcome {
  const ScenarioSuccess(this.response);
  final Response<dynamic> response;
}

final class ScenarioFailure extends ScenarioOutcome {
  const ScenarioFailure(this.error);
  final Object error;
}

/// Runs [call], times it, records it on [stats] and hands the result to
/// [onOutcome]. Shared by every scenario screen's "Run" button.
Future<void> runScenario({
  required DemoStats stats,
  required EventLog log,
  required Future<Response<dynamic>> Function() call,
  required void Function(ScenarioOutcome outcome) onOutcome,
}) async {
  final stopwatch = Stopwatch()..start();
  try {
    final response = await call();
    stopwatch.stop();
    stats.recordLogicalCall(stopwatch.elapsed);
    onOutcome(ScenarioSuccess(response));
  } catch (error) {
    stopwatch.stop();
    stats.recordLogicalCall(stopwatch.elapsed, error: error);
    onOutcome(ScenarioFailure(error));
  }
}
