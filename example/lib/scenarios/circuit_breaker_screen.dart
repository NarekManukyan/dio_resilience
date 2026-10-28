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

class CircuitBreakerScreen extends StatefulWidget {
  const CircuitBreakerScreen({super.key});

  @override
  State<CircuitBreakerScreen> createState() => _CircuitBreakerScreenState();
}

class _CircuitBreakerScreenState extends State<CircuitBreakerScreen> {
  int _failureThreshold = 3;
  int _cooldownMs = 2000;
  int _halfOpenProbes = 1;

  late Dio _dio;
  bool _forceFailure = false;
  ScenarioOutcome? _outcome;
  bool _busy = false;
  CircuitPhase _phase = CircuitPhase.closed;
  final _log = EventLog();
  final _stats = DemoStats();

  @override
  void initState() {
    super.initState();
    _rebuild();
    if (kDemoAutoplay) AutoplayHook.action = _runAll;
  }

  @override
  void dispose() {
    if (identical(AutoplayHook.action, _runAll)) AutoplayHook.action = null;
    _log.dispose();
    _stats.dispose();
    super.dispose();
  }

  void _rebuild() {
    _dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
    ResiliencePipeline.builder()
        .circuitBreaker(
          failureThreshold: _failureThreshold,
          cooldown: Duration(milliseconds: _cooldownMs),
          halfOpenProbes: _halfOpenProbes,
          windowDuration: const Duration(seconds: 60),
        )
        .onEvent((e) {
          _log.onEvent(e);
          _stats.onEvent(e);
          if (e is CircuitStateChangedEvent && mounted) {
            setState(() => _phase = e.to);
          }
        })
        .build()
        .attachTo(_dio);
    _dio.httpClientAdapter = FakeHttpClientAdapter(
      (call) async {
        if (_forceFailure) return const FakeResult(500, data: {'error': 'down'});
        return const FakeResult(200, data: {'status': 'ok'});
      },
      onWireCall: (_) => _stats.recordWireRequest(),
    );
    setState(() => _phase = CircuitPhase.closed);
  }

  Future<void> _send({required bool fail}) async {
    setState(() {
      _busy = true;
      _outcome = null;
    });
    _forceFailure = fail;
    await runScenario(
      stats: _stats,
      log: _log,
      call: () => _dio.get<dynamic>('/circuit-demo'),
      onOutcome: (o) => setState(() => _outcome = o),
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _waitCooldownThenProbe() async {
    _log.line('waiting ${_cooldownMs}ms for the cooldown to elapse...');
    await Future<void>.delayed(Duration(milliseconds: _cooldownMs + 150));
    await _send(fail: false);
  }

  Future<void> _runAll() async {
    for (var i = 0; i < _failureThreshold; i++) {
      await _send(fail: true);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await _send(fail: true); // circuit is open now: fail-fast.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _waitCooldownThenProbe();
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioScaffold(
      title: 'Circuit breaker',
      explanation:
          'circuitBreaker() trips to open after failureThreshold failures '
          'in windowDuration, fails fast with CircuitOpenException while '
          'open, allows halfOpenProbes probes after cooldown, and closes '
          'again once they all succeed.',
      controls: [
        IntKnob(
          label: 'Failure threshold',
          value: _failureThreshold,
          min: 1,
          max: 8,
          onChanged: (v) => setState(() => _failureThreshold = v),
        ),
        IntKnob(
          label: 'Cooldown (ms)',
          value: _cooldownMs,
          min: 500,
          max: 5000,
          onChanged: (v) => setState(() => _cooldownMs = v),
        ),
        IntKnob(
          label: 'Half-open probes',
          value: _halfOpenProbes,
          min: 1,
          max: 3,
          onChanged: (v) => setState(() => _halfOpenProbes = v),
        ),
        FilledButton.tonal(
          onPressed: _rebuild,
          child: const Text('Apply & reset circuit'),
        ),
      ],
      actions: [
        FilledButton(
          onPressed: _busy ? null : () => _send(fail: true),
          child: const Text('Send failing request'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _send(fail: false),
          child: const Text('Send succeeding request'),
        ),
        FilledButton(
          onPressed: _busy ? null : _waitCooldownThenProbe,
          child: const Text('Wait cooldown & probe'),
        ),
      ],
      outcome: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PhaseIndicator(phase: _phase),
          const SizedBox(height: 8),
          OutcomeCard(outcome: _outcome),
        ],
      ),
      log: _log,
      stats: _stats,
    );
  }
}

class _PhaseIndicator extends StatelessWidget {
  const _PhaseIndicator({required this.phase});

  final CircuitPhase phase;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (phase) {
      CircuitPhase.closed => (Colors.green, 'CLOSED — requests flow normally'),
      CircuitPhase.open => (Colors.red, 'OPEN — failing fast'),
      CircuitPhase.halfOpen => (Colors.orange, 'HALF-OPEN — probing'),
    };
    return Card(
      color: color.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.circle, color: color, size: 14),
            const SizedBox(width: 8),
            Text(label, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
      ),
    );
  }
}
