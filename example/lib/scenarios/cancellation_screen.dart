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

class CancellationScreen extends StatefulWidget {
  const CancellationScreen({super.key});

  @override
  State<CancellationScreen> createState() => _CancellationScreenState();
}

class _CancellationScreenState extends State<CancellationScreen> {
  late final Dio _dio;
  CancelToken? _activeToken;
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
          maxAttempts: 5,
          backoff: const Backoff.constant(Duration(seconds: 1)),
        )
        .onEvent((e) {
          _log.onEvent(e);
          _stats.onEvent(e);
        })
        .build()
        .attachTo(_dio);
    _dio.httpClientAdapter = FakeHttpClientAdapter(
      (call) async => const FakeResult(503, data: {'error': 'down'}),
      onWireCall: (_) => _stats.recordWireRequest(),
      onCancelled: (_) => _log.line('attempt cancelled mid-flight', level: LogLevel.warn),
    );
    if (kDemoAutoplay) AutoplayHook.action = _runAndAutoCancel;
  }

  @override
  void dispose() {
    if (identical(AutoplayHook.action, _runAndAutoCancel)) AutoplayHook.action = null;
    _log.dispose();
    _stats.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _outcome = null;
    });
    final token = CancelToken();
    _activeToken = token;
    await runScenario(
      stats: _stats,
      log: _log,
      call: () => _dio.get<dynamic>('/cancel-demo', cancelToken: token),
      onOutcome: (o) => setState(() => _outcome = o),
    );
    _activeToken = null;
    if (mounted) setState(() => _busy = false);
  }

  void _cancel() => _activeToken?.cancel('cancelled by the caller');

  Future<void> _runAndAutoCancel() async {
    final run = _run();
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    _cancel();
    await run;
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioScaffold(
      title: 'Cancellation',
      explanation:
          'A caller-cancelled request ends on the spot, even mid-backoff: '
          'the pipeline never sends another attempt, and the caller gets '
          'the cancellation it asked for instead of a resilience exception.',
      controls: const [],
      actions: [
        FilledButton(
          onPressed: _busy ? null : _run,
          child: const Text('Run (retries against a 503)'),
        ),
        OutlinedButton(
          onPressed: _busy ? _cancel : null,
          child: const Text('Cancel now'),
        ),
      ],
      outcome: OutcomeCard(outcome: _outcome),
      log: _log,
      stats: _stats,
    );
  }
}
