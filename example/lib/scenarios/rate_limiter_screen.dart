import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';
import 'package:flutter/material.dart';

import '../autoplay.dart';
import '../core/demo_stats.dart';
import '../core/event_log.dart';
import '../fake/fake_adapter.dart';
import '../widgets/knob.dart';
import '../widgets/scenario_scaffold.dart';

enum _Algo { tokenBucket, slidingWindow }

class _TimelineEntry {
  _TimelineEntry(this.index);
  final int index;
  int? finishedAtMs;
  bool? ok;
  Object? error;
}

class RateLimiterScreen extends StatefulWidget {
  const RateLimiterScreen({super.key});

  @override
  State<RateLimiterScreen> createState() => _RateLimiterScreenState();
}

class _RateLimiterScreenState extends State<RateLimiterScreen> {
  _Algo _algo = _Algo.tokenBucket;
  int _ratePerSecond = 2;
  int _burst = 2;
  int _windowRequests = 3;
  int _windowMs = 2000;
  RateLimitMode _mode = RateLimitMode.wait;
  int _fireCount = 6;

  late Dio _dio;
  bool _busy = false;
  List<_TimelineEntry> _timeline = [];
  final _log = EventLog();
  final _stats = DemoStats();

  @override
  void initState() {
    super.initState();
    _rebuild();
    if (kDemoAutoplay) AutoplayHook.action = _fire;
  }

  @override
  void dispose() {
    if (identical(AutoplayHook.action, _fire)) AutoplayHook.action = null;
    _log.dispose();
    _stats.dispose();
    super.dispose();
  }

  void _rebuild() {
    _dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
    final algorithm = _algo == _Algo.tokenBucket
        ? RateLimitAlgorithm.tokenBucket(
            ratePerSecond: _ratePerSecond.toDouble(),
            burst: _burst,
          )
        : RateLimitAlgorithm.slidingWindow(
            requests: _windowRequests,
            window: Duration(milliseconds: _windowMs),
          );
    ResiliencePipeline.builder()
        .rateLimit(algorithm: algorithm, mode: _mode)
        .timeout(total: const Duration(seconds: 20))
        .onEvent((e) {
          _log.onEvent(e);
          _stats.onEvent(e);
        })
        .build()
        .attachTo(_dio);
    _dio.httpClientAdapter = FakeHttpClientAdapter(
      (call) async => const FakeResult(200, data: {'status': 'ok'}),
      onWireCall: (_) => _stats.recordWireRequest(),
    );
  }

  Future<void> _fire() async {
    setState(() {
      _timeline = [for (var i = 0; i < _fireCount; i++) _TimelineEntry(i + 1)];
      _busy = true;
    });
    final stopwatch = Stopwatch()..start();
    await Future.wait(
      List.generate(_fireCount, (i) {
        final entry = _timeline[i];
        return _dio.get<dynamic>('/rate-demo').then((response) {
          entry.finishedAtMs = stopwatch.elapsedMilliseconds;
          entry.ok = true;
          _stats.recordLogicalCall(stopwatch.elapsed);
          if (mounted) setState(() {});
        }).catchError((Object e) {
          entry.finishedAtMs = stopwatch.elapsedMilliseconds;
          entry.ok = false;
          entry.error = e;
          _stats.recordLogicalCall(stopwatch.elapsed, error: e);
          if (mounted) setState(() {});
        });
      }),
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioScaffold(
      title: 'Rate limiter',
      explanation:
          'rateLimit() throttles outgoing requests per key (host by '
          'default). Token bucket allows a burst then refills continuously; '
          'sliding window allows a strict N requests per rolling duration. '
          'RateLimitMode.wait blocks for a token (bounded by the total '
          'budget); RateLimitMode.fail throws RateLimitExceededException '
          'immediately. Fire several requests at once and watch when each '
          'one actually gets through.',
      controls: [
        ChoiceKnob<_Algo>(
          label: 'Algorithm',
          value: _algo,
          options: _Algo.values,
          labelOf: (a) => a == _Algo.tokenBucket ? 'Token bucket' : 'Sliding window',
          onChanged: (v) => setState(() => _algo = v),
        ),
        if (_algo == _Algo.tokenBucket) ...[
          IntKnob(
            label: 'Rate (tokens/sec)',
            value: _ratePerSecond,
            min: 1,
            max: 10,
            onChanged: (v) => setState(() => _ratePerSecond = v),
          ),
          IntKnob(
            label: 'Burst',
            value: _burst,
            min: 1,
            max: 10,
            onChanged: (v) => setState(() => _burst = v),
          ),
        ] else ...[
          IntKnob(
            label: 'Requests per window',
            value: _windowRequests,
            min: 1,
            max: 10,
            onChanged: (v) => setState(() => _windowRequests = v),
          ),
          IntKnob(
            label: 'Window (ms)',
            value: _windowMs,
            min: 500,
            max: 5000,
            onChanged: (v) => setState(() => _windowMs = v),
          ),
        ],
        ChoiceKnob<RateLimitMode>(
          label: 'Mode',
          value: _mode,
          options: RateLimitMode.values,
          labelOf: (m) => m.name,
          onChanged: (v) => setState(() => _mode = v),
        ),
        IntKnob(
          label: 'Requests to fire',
          value: _fireCount,
          min: 1,
          max: 15,
          onChanged: (v) => setState(() => _fireCount = v),
        ),
        FilledButton.tonal(onPressed: _rebuild, child: const Text('Apply')),
      ],
      actions: [
        FilledButton(
          onPressed: _busy ? null : _fire,
          child: Text('Fire $_fireCount requests at once'),
        ),
      ],
      outcome: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: _timeline.isEmpty
              ? const Text('Press "Fire" to see when each request gets through.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in _timeline)
                      Text(
                        '#${entry.index}: ${_describe(entry)}',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      ),
                  ],
                ),
        ),
      ),
      log: _log,
      stats: _stats,
    );
  }

  String _describe(_TimelineEntry entry) {
    if (entry.ok == null) return 'pending...';
    if (entry.ok!) return 'through @ ${entry.finishedAtMs}ms';
    return 'rejected @ ${entry.finishedAtMs}ms (${entry.error.runtimeType})';
  }
}
