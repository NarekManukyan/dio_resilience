import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';
import 'package:flutter/foundation.dart';

enum LogLevel { info, warn, error, success }

class LogEntry {
  LogEntry(this.text, {this.level = LogLevel.info}) : time = DateTime.now();

  final DateTime time;
  final String text;
  final LogLevel level;
}

/// Collects the pipeline's [ResilienceEvent]s — plus a few plain lines a
/// scenario adds itself — for the on-screen log panel.
class EventLog extends ChangeNotifier {
  final List<LogEntry> entries = [];

  void clear() {
    entries.clear();
    notifyListeners();
  }

  void line(String text, {LogLevel level = LogLevel.info}) {
    entries.add(LogEntry(text, level: level));
    notifyListeners();
  }

  /// Pass this to `.onEvent(...)` on a pipeline builder.
  void onEvent(ResilienceEvent event) {
    final (text, level) = switch (event) {
      ReplayEvent(:final strategy, :final error, :final attemptNumber, :final delay) => (
          '[$strategy] replay #$attemptNumber after ${_describe(error)} '
              '(wait ${delay.inMilliseconds}ms)',
          LogLevel.warn,
        ),
      RecoveredEvent(:final strategy, :final error) => (
          '[$strategy] recovered after ${_describe(error)}',
          LogLevel.success,
        ),
      GaveUpEvent(:final error) => ('gave up: ${_describe(error)}', LogLevel.error),
      CircuitStateChangedEvent(:final key, :final from, :final to) => (
          'circuit "$key" $from -> $to',
          LogLevel.warn,
        ),
    };
    line(text, level: level);
  }

  String _describe(DioException error) {
    final code = error.response?.statusCode;
    if (code != null) return 'HTTP $code';
    return error.runtimeType == DioException ? error.type.name : '${error.runtimeType}';
  }
}
