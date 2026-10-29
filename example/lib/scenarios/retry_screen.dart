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

class RetryScreen extends StatefulWidget {
  const RetryScreen({super.key});

  @override
  State<RetryScreen> createState() => _RetryScreenState();
}

class _RetryScreenState extends State<RetryScreen> {
  int _maxAttempts = 3;
  int _failureCount = 2;
  int _retryAfterSeconds = 5;
  bool _capRetryAfter = true;

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

  Dio _newDio(FakeHandler handler) {
    final dio = Dio();
    ResiliencePipeline.builder()
        .retry(
          maxAttempts: _maxAttempts,
          maxRetryAfter: _capRetryAfter ? const Duration(seconds: 10) : null,
          backoff: const Backoff.exponentialJitter(
            initial: Duration(milliseconds: 150),
            maxDelay: Duration(seconds: 2),
          ),
        )
        .onEvent((e) {
          _log.onEvent(e);
          _stats.onEvent(e);
        })
        .build()
        .attachTo(dio);
    dio.httpClientAdapter = FakeHttpClientAdapter(
      handler,
      onWireCall: (_) => _stats.recordWireRequest(),
    );
    return dio;
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

  Future<void> _runBackoff() {
    var attempts = 0;
    final dio = _newDio((call) async {
      attempts++;
      if (attempts <= _failureCount) {
        return const FakeResult(503, data: {'error': 'service_unavailable'});
      }
      return FakeResult(200, data: {'status': 'ok', 'attempts': attempts});
    });
    return _run(() => dio.get<dynamic>('/retry-backoff'));
  }

  Future<void> _runPost() {
    final dio = _newDio(
      (call) async =>
          const FakeResult(503, data: {'error': 'service_unavailable'}),
    );
    return _run(() => dio.post<dynamic>('/retry-post'));
  }

  Future<void> _runRetryAfter() {
    var attempts = 0;
    final dio = _newDio((call) async {
      attempts++;
      if (attempts == 1) {
        return FakeResult(
          429,
          data: {'error': 'rate_limited'},
          headers: {
            'retry-after': ['$_retryAfterSeconds'],
          },
        );
      }
      return const FakeResult(200, data: {'status': 'ok'});
    });
    return _run(() => dio.get<dynamic>('/retry-after'));
  }

  Future<void> _runExhausted() {
    final dio = _newDio(
      (call) async => const FakeResult(503, data: {'error': 'always_down'}),
    );
    return _run(() => dio.get<dynamic>('/retry-exhausted'));
  }

  Future<void> _runAll() async {
    await _runBackoff();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _runPost();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _runRetryAfter();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _runExhausted();
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioScaffold(
      title: 'Retry & backoff',
      explanation:
          'retry() replays a failed attempt with backoff. Only the '
          'idempotent methods (GET, HEAD, OPTIONS, TRACE, PUT, DELETE) are '
          'retried by default, so a POST whose response got lost is never '
          'sent twice. A server Retry-After longer than maxRetryAfter ends '
          'the request instead of waiting. Once maxAttempts is spent, the '
          'caller sees an AllAttemptsExhaustedException that still reads '
          "like the last failure (status, type).",
      controls: [
        IntKnob(
          label: 'Max attempts',
          value: _maxAttempts,
          min: 1,
          max: 6,
          onChanged: (v) => setState(() => _maxAttempts = v),
        ),
        IntKnob(
          label: 'Failures before success',
          value: _failureCount,
          min: 0,
          max: 5,
          onChanged: (v) => setState(() => _failureCount = v),
        ),
        IntKnob(
          label: 'Retry-After (seconds)',
          value: _retryAfterSeconds,
          min: 1,
          max: 40,
          onChanged: (v) => setState(() => _retryAfterSeconds = v),
        ),
        BoolKnob(
          label: 'Cap Retry-After at 10s (maxRetryAfter)',
          value: _capRetryAfter,
          onChanged: (v) => setState(() => _capRetryAfter = v),
        ),
      ],
      actions: [
        FilledButton(
          onPressed: _busy ? null : _runBackoff,
          child: const Text('Run: 503 ×N then 200'),
        ),
        FilledButton(
          onPressed: _busy ? null : _runPost,
          child: const Text('Run: POST (not retried)'),
        ),
        FilledButton(
          onPressed: _busy ? null : _runRetryAfter,
          child: const Text('Run: Retry-After'),
        ),
        FilledButton(
          onPressed: _busy ? null : _runExhausted,
          child: const Text('Run: exhausted'),
        ),
      ],
      outcome: OutcomeCard(outcome: _outcome),
      log: _log,
      stats: _stats,
    );
  }
}
