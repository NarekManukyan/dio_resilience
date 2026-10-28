import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';
import 'package:flutter/material.dart';

import '../autoplay.dart';
import '../core/demo_stats.dart';
import '../core/event_log.dart';
import '../core/scenario_runner.dart';
import '../fake/fake_adapter.dart';
import '../widgets/knob.dart';
import '../widgets/outcome_card.dart';
import '../widgets/scenario_scaffold.dart';

class HedgingScreen extends StatefulWidget {
  const HedgingScreen({super.key});

  @override
  State<HedgingScreen> createState() => _HedgingScreenState();
}

class _HedgingScreenState extends State<HedgingScreen> {
  int _primaryLatencyMs = 1500;
  int _hedgeDelayMs = 150;
  int _maxParallel = 2;

  ScenarioOutcome? _outcome;
  bool _busy = false;
  final _log = EventLog();
  final _stats = DemoStats();

  @override
  void initState() {
    super.initState();
    if (kDemoAutoplay) AutoplayHook.action = _run;
  }

  @override
  void dispose() {
    if (identical(AutoplayHook.action, _run)) AutoplayHook.action = null;
    _log.dispose();
    _stats.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _outcome = null;
    });

    var branch = 0;
    final dio = Dio();
    ResiliencePipeline.builder()
        .hedging(
          maxParallel: _maxParallel,
          delay: Duration(milliseconds: _hedgeDelayMs),
        )
        .onEvent((e) {
          _log.onEvent(e);
          _stats.onEvent(e);
        })
        .build()
        .attachTo(dio);
    dio.httpClientAdapter = FakeHttpClientAdapter(
      (call) async {
        branch++;
        final isPrimary = branch == 1;
        final latency = isPrimary
            ? Duration(milliseconds: _primaryLatencyMs)
            : const Duration(milliseconds: 120);
        _log.line(
          'branch $branch (${isPrimary ? 'primary' : 'hedge'}) fired, '
          '${latency.inMilliseconds}ms latency',
        );
        await Future<void>.delayed(latency);
        return FakeResult(200, data: {'branch': branch, 'primary': isPrimary});
      },
      onWireCall: (_) => _stats.recordWireRequest(),
      onCancelled: (_) => _log.line('a losing branch was cancelled', level: LogLevel.warn),
    );

    final stopwatch = Stopwatch()..start();
    try {
      final response = await dio.get<dynamic>('/hedge-demo');
      stopwatch.stop();
      _stats.recordLogicalCall(stopwatch.elapsed);
      setState(() => _outcome = ScenarioSuccess(response));
    } catch (error) {
      stopwatch.stop();
      _stats.recordLogicalCall(stopwatch.elapsed, error: error);
      setState(() => _outcome = ScenarioFailure(error));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioScaffold(
      title: 'Hedging',
      explanation:
          'hedging() fires a hedge branch after delay if the primary is '
          'still in flight, up to maxParallel total branches. The first '
          'branch to succeed wins; every other in-flight branch is '
          'cancelled. Only GET/HEAD are hedged by default. Here the primary '
          'is deliberately slow so the hedge almost always wins.',
      controls: [
        IntKnob(
          label: 'Primary latency (ms)',
          value: _primaryLatencyMs,
          min: 200,
          max: 3000,
          onChanged: (v) => setState(() => _primaryLatencyMs = v),
        ),
        IntKnob(
          label: 'Hedge delay (ms)',
          value: _hedgeDelayMs,
          min: 50,
          max: 1000,
          onChanged: (v) => setState(() => _hedgeDelayMs = v),
        ),
        IntKnob(
          label: 'Max parallel branches',
          value: _maxParallel,
          min: 2,
          max: 3,
          onChanged: (v) => setState(() => _maxParallel = v),
        ),
      ],
      actions: [
        FilledButton(
          onPressed: _busy ? null : _run,
          child: const Text('Run: race primary vs. hedge'),
        ),
      ],
      outcome: OutcomeCard(outcome: _outcome),
      log: _log,
      stats: _stats,
    );
  }
}
