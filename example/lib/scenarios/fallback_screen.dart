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

class FallbackScreen extends StatefulWidget {
  const FallbackScreen({super.key});

  @override
  State<FallbackScreen> createState() => _FallbackScreenState();
}

class _FallbackScreenState extends State<FallbackScreen> {
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

  Future<void> _runAfterRetriesExhausted() {
    final dio = Dio();
    ResiliencePipeline.builder()
        .retry(
          maxAttempts: 2,
          backoff: const Backoff.constant(Duration(milliseconds: 100)),
        )
        .fallback(
          handlers: [
            FallbackHandler.response(
              (err, opts) => Response<dynamic>(
                requestOptions: opts,
                statusCode: 200,
                data: {'fallback': true, 'reason': err.runtimeType.toString()},
              ),
            ),
          ],
        )
        .onEvent((e) {
          _log.onEvent(e);
          _stats.onEvent(e);
        })
        .build()
        .attachTo(dio);
    dio.httpClientAdapter = FakeHttpClientAdapter(
      (call) async => const FakeResult(503, data: {'error': 'down'}),
      onWireCall: (_) => _stats.recordWireRequest(),
    );
    return _run(() => dio.get<dynamic>('/fallback-retry'));
  }

  Future<void> _runAfterCircuitOpen() {
    final dio = Dio();
    ResiliencePipeline.builder()
        .circuitBreaker(failureThreshold: 1, cooldown: const Duration(seconds: 30))
        .fallback(
          handlers: [
            FallbackHandler.response(
              (err, opts) => Response<dynamic>(
                requestOptions: opts,
                statusCode: 200,
                data: {'fallback': true, 'reason': err.runtimeType.toString()},
              ),
            ),
          ],
        )
        .onEvent((e) {
          _log.onEvent(e);
          _stats.onEvent(e);
        })
        .build()
        .attachTo(dio);
    dio.httpClientAdapter = FakeHttpClientAdapter(
      (call) async => const FakeResult(500, data: {'error': 'down'}),
      onWireCall: (_) => _stats.recordWireRequest(),
    );
    // The first call trips the circuit; the second is fail-fast and falls
    // back.
    return _run(() async {
      try {
        await dio.get<dynamic>('/fallback-circuit');
      } catch (_) {
        // Expected: this is the call that trips the circuit.
      }
      return dio.get<dynamic>('/fallback-circuit');
    });
  }

  Future<void> _runEndpointFallback() {
    final dio = Dio();
    ResiliencePipeline.builder()
        .retry(maxAttempts: 1)
        .fallback(handlers: [const FallbackHandler.endpoint('https://mirror.example/api')])
        .onEvent((e) {
          _log.onEvent(e);
          _stats.onEvent(e);
        })
        .build()
        .attachTo(dio);
    dio.httpClientAdapter = FakeHttpClientAdapter((call) async {
      if (call.options.uri.host == 'mirror.example') {
        return const FakeResult(200, data: {'status': 'ok', 'via': 'mirror'});
      }
      return const FakeResult(500, data: {'error': 'primary_down'});
    }, onWireCall: (_) => _stats.recordWireRequest());
    return _run(() => dio.get<dynamic>('https://primary.example/api'));
  }

  Future<void> _runAll() async {
    await _runAfterRetriesExhausted();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _runAfterCircuitOpen();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _runEndpointFallback();
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioScaffold(
      title: 'Fallback',
      explanation:
          'fallback() is the last resort: it only runs once every other '
          'strategy has declined. A handler can return a canned response, '
          're-fire to an alternate endpoint (through the same pipeline), or '
          'wrap another handler behind a predicate.',
      controls: const [],
      actions: [
        FilledButton(
          onPressed: _busy ? null : _runAfterRetriesExhausted,
          child: const Text('Run: after retries exhausted'),
        ),
        FilledButton(
          onPressed: _busy ? null : _runAfterCircuitOpen,
          child: const Text('Run: after circuit opens'),
        ),
        FilledButton(
          onPressed: _busy ? null : _runEndpointFallback,
          child: const Text('Run: alternate endpoint'),
        ),
      ],
      outcome: OutcomeCard(outcome: _outcome),
      log: _log,
      stats: _stats,
    );
  }
}
