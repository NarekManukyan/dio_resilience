import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';
import 'package:flutter/material.dart';

import '../autoplay.dart';
import '../core/demo_stats.dart';
import '../core/event_log.dart';
import '../core/scenario_runner.dart';
import '../fake/fake_adapter.dart';
import '../widgets/outcome_card.dart';
import '../widgets/scenario_scaffold.dart';

class OverridesScreen extends StatefulWidget {
  const OverridesScreen({super.key});

  @override
  State<OverridesScreen> createState() => _OverridesScreenState();
}

class _OverridesScreenState extends State<OverridesScreen> {
  late final Dio _dio;
  ScenarioOutcome? _outcome;
  bool _busy = false;
  final _log = EventLog();
  final _stats = DemoStats();

  @override
  void initState() {
    super.initState();
    _dio = Dio();
    ResiliencePipeline.builder()
        .retry(
          maxAttempts: 3,
          backoff: const Backoff.constant(Duration(milliseconds: 150)),
        )
        .onEvent((e) {
          _log.onEvent(e);
          _stats.onEvent(e);
        })
        .build()
        .attachTo(_dio);
    _dio.httpClientAdapter = FakeHttpClientAdapter((call) async {
      if (call.options.path == '/overrides-slow') {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return const FakeResult(200, data: {'status': 'ok'});
      }
      return const FakeResult(503, data: {'error': 'down'});
    }, onWireCall: (_) => _stats.recordWireRequest());
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

  Future<void> _runDefault() => _run(() => _dio.get<dynamic>('/overrides-flaky'));

  Future<void> _runNoRetry() =>
      _run(() => _dio.get<dynamic>('/overrides-flaky', options: Options().noRetry()));

  Future<void> _runWithTimeout() => _run(
        () => _dio.get<dynamic>(
          '/overrides-slow',
          options: Options().withTimeout(const Duration(milliseconds: 50)),
        ),
      );

  Future<void> _runExtrasMap() => _run(
        () => _dio.get<dynamic>(
          '/overrides-flaky',
          options: Options(extra: ResilienceExtras.noRetry),
        ),
      );

  Future<void> _runAll() async {
    await _runDefault();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _runNoRetry();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _runWithTimeout();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _runExtrasMap();
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioScaffold(
      title: 'Per-request overrides',
      explanation:
          'The pipeline above retries up to 3 times by default. '
          'Options().noRetry() and the const ResilienceExtras.noRetry map '
          'both switch retry off for a single call — the const map is for '
          "call sites that only accept a const map (Retrofit's @Extras). "
          "withTimeout() gives one call its own deadline regardless of the "
          "pipeline's default.",
      controls: const [],
      actions: [
        FilledButton(
          onPressed: _busy ? null : _runDefault,
          child: const Text('Run: default (3 attempts)'),
        ),
        FilledButton(
          onPressed: _busy ? null : _runNoRetry,
          child: const Text('Run: Options().noRetry()'),
        ),
        FilledButton(
          onPressed: _busy ? null : _runWithTimeout,
          child: const Text('Run: .withTimeout(50ms)'),
        ),
        FilledButton(
          onPressed: _busy ? null : _runExtrasMap,
          child: const Text('Run: ResilienceExtras.noRetry'),
        ),
      ],
      outcome: OutcomeCard(outcome: _outcome),
      log: _log,
      stats: _stats,
    );
  }
}
