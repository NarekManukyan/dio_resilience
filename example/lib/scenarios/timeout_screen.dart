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

class TimeoutScreen extends StatefulWidget {
  const TimeoutScreen({super.key});

  @override
  State<TimeoutScreen> createState() => _TimeoutScreenState();
}

class _TimeoutScreenState extends State<TimeoutScreen> {
  int _totalBudgetMs = 1200;
  int _perAttemptMs = 500;

  ScenarioOutcome? _outcome;
  bool _busy = false;
  final _log = EventLog();
  final _stats = DemoStats();

  @override
  void initState() {
    super.initState();
    if (kDemoAutoplay) AutoplayHook.action = _runAll;
  }

  @override
  void dispose() {
    if (identical(AutoplayHook.action, _runAll)) AutoplayHook.action = null;
    _log.dispose();
    _stats.dispose();
    super.dispose();
  }

  Future<void> _run(Future<Response<dynamic>> Function() call) async {
    setState(() {
      _busy = true;
      _outcome = null;
    });
    await runScenario(
      stats: _stats,
      log: _log,
      call: call,
      onOutcome: (o) => setState(() => _outcome = o),
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _runTotalBudget() {
    final dio = Dio();
    ResiliencePipeline.builder()
        .timeout(total: Duration(milliseconds: _totalBudgetMs))
        .onEvent((e) {
          _log.onEvent(e);
          _stats.onEvent(e);
        })
        .build()
        .attachTo(dio);
    dio.httpClientAdapter = FakeHttpClientAdapter((call) async {
      await Future<void>.delayed(Duration(milliseconds: _totalBudgetMs * 3));
      return const FakeResult(200, data: {'status': 'ok'});
    }, onWireCall: (_) => _stats.recordWireRequest());
    return _run(() => dio.get<dynamic>('/timeout-total'));
  }

  Future<void> _runPerAttempt() {
    var attempts = 0;
    final dio = Dio();
    ResiliencePipeline.builder()
        .retry(
          maxAttempts: 3,
          backoff: const Backoff.constant(Duration(milliseconds: 150)),
        )
        .timeout(perAttempt: Duration(milliseconds: _perAttemptMs))
        .onEvent((e) {
          _log.onEvent(e);
          _stats.onEvent(e);
        })
        .build()
        .attachTo(dio);
    dio.httpClientAdapter = FakeHttpClientAdapter((call) async {
      attempts++;
      final latency = attempts == 1
          ? Duration(milliseconds: (_perAttemptMs * 2.5).round())
          : Duration(milliseconds: (_perAttemptMs * 0.3).round());
      await Future<void>.delayed(latency);
      return FakeResult(200, data: {'status': 'ok', 'attempt': attempts});
    }, onWireCall: (_) => _stats.recordWireRequest());
    return _run(() => dio.get<dynamic>('/timeout-per-attempt'));
  }

  Future<void> _runAll() async {
    await _runTotalBudget();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _runPerAttempt();
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioScaffold(
      title: 'Timeout',
      explanation:
          'timeout(total:) is a deadline for the whole request: an attempt '
          'still in flight when it passes is cancelled and the caller gets '
          'a PipelineTimeoutException. timeout(perAttempt:) caps each '
          "individual attempt's connect/receive timeout, so a slow attempt "
          'times out and retry gets to try again on a fresh one.',
      controls: [
        IntKnob(
          label: 'Total budget (ms)',
          value: _totalBudgetMs,
          min: 300,
          max: 4000,
          onChanged: (v) => setState(() => _totalBudgetMs = v),
        ),
        IntKnob(
          label: 'Per-attempt cap (ms)',
          value: _perAttemptMs,
          min: 100,
          max: 2000,
          onChanged: (v) => setState(() => _perAttemptMs = v),
        ),
      ],
      actions: [
        FilledButton(
          onPressed: _busy ? null : _runTotalBudget,
          child: const Text('Run: total budget cuts it off'),
        ),
        FilledButton(
          onPressed: _busy ? null : _runPerAttempt,
          child: const Text('Run: per-attempt timeout then retry'),
        ),
      ],
      outcome: OutcomeCard(outcome: _outcome),
      log: _log,
      stats: _stats,
    );
  }
}
