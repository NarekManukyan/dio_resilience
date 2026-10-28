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

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  ScenarioOutcome? _outcome;
  String? _summary;
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

  Future<void> _guard(String label, Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _outcome = null;
      _summary = label;
    });
    try {
      await body();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- Scenario A: concurrent 401s share one refresh ------------------------

  Future<void> _runConcurrentRefresh() => _guard('Concurrent refresh', () async {
        final storage = MemoryTokenStorage();
        await storage.write(const TokenPair(access: 'expired-token'));
        var refreshCount = 0;

        final dio = Dio();
        final pipeline = ResiliencePipeline.builder()
            .auth(
              tokenStorage: storage,
              refreshToken: (current) async {
                refreshCount++;
                _log.line('refreshing (call #$refreshCount)...', level: LogLevel.warn);
                await Future<void>.delayed(const Duration(milliseconds: 400));
                return const TokenPair(access: 'fresh-token');
              },
              onAuthFailure: (r) => _log.line(
                'auth rejected: token=${r.rejectedToken}',
                level: LogLevel.error,
              ),
            )
            .onEvent((e) {
              _log.onEvent(e);
              _stats.onEvent(e);
            })
            .build();
        pipeline.attachTo(dio);
        final authSub =
            pipeline.authStateStream.listen((s) => _log.line('auth state: ${s.name}'));
        dio.httpClientAdapter = FakeHttpClientAdapter(
          (call) async {
            final auth = call.options.headers['Authorization'] as String?;
            if (auth == 'Bearer fresh-token') {
              return const FakeResult(200, data: {'status': 'ok'});
            }
            return const FakeResult(401, data: {'error': 'unauthorized'});
          },
          onWireCall: (_) => _stats.recordWireRequest(),
        );

        final stopwatch = Stopwatch()..start();
        final responses = await Future.wait(
          List.generate(
            5,
            (_) => dio
                .get<dynamic>('/me')
                .then<Response<dynamic>?>((r) => r, onError: (_) => null),
          ),
        );
        stopwatch.stop();
        _stats.recordLogicalCall(stopwatch.elapsed);
        await authSub.cancel();
        final succeeded = responses.whereType<Response<dynamic>>().toList();
        setState(() {
          _summary =
              '${succeeded.length}/5 requests succeeded after $refreshCount '
              'refresh call(s).';
          _outcome = succeeded.isNotEmpty ? ScenarioSuccess(succeeded.first) : null;
        });
      });

  // --- Scenario B: refresh fails terminally ---------------------------------

  Future<void> _runRefreshFailure() => _guard('Refresh failure', () async {
        final storage = MemoryTokenStorage();
        await storage.write(const TokenPair(access: 'expired-token'));

        final dio = Dio();
        ResiliencePipeline.builder()
            .auth(
              tokenStorage: storage,
              refreshToken: (current) async {
                await Future<void>.delayed(const Duration(milliseconds: 200));
                throw Exception('refresh endpoint down');
              },
              onAuthFailure: (r) => _log.line(
                'auth rejected: token=${r.rejectedToken} '
                'refreshAttempted=${r.refreshAttempted}',
                level: LogLevel.error,
              ),
            )
            .onEvent((e) {
              _log.onEvent(e);
              _stats.onEvent(e);
            })
            .build()
            .attachTo(dio);
        dio.httpClientAdapter = FakeHttpClientAdapter(
          (call) async => const FakeResult(401, data: {'error': 'unauthorized'}),
          onWireCall: (_) => _stats.recordWireRequest(),
        );

        await runScenario(
          stats: _stats,
          log: _log,
          call: () => dio.get<dynamic>('/me'),
          onOutcome: (o) => setState(() => _outcome = o),
        );
      });

  // --- Scenario C: no refresh configured -------------------------------------

  Future<void> _runNoRefresh() => _guard('No-refresh mode', () async {
        final dio = Dio();
        ResiliencePipeline.builder()
            .auth(
              onAuthFailure: (r) => _log.line(
                'auth rejected (no refresh configured): token=${r.rejectedToken}',
                level: LogLevel.warn,
              ),
            )
            .onEvent((e) {
              _log.onEvent(e);
              _stats.onEvent(e);
            })
            .build()
            .attachTo(dio);
        // No token stored at all: the strategy injects nothing and the fake
        // server answers 401, which reaches the caller unchanged.
        dio.httpClientAdapter = FakeHttpClientAdapter(
          (call) async => const FakeResult(401, data: {'error': 'unauthorized'}),
          onWireCall: (_) => _stats.recordWireRequest(),
        );

        await runScenario(
          stats: _stats,
          log: _log,
          call: () => dio.get<dynamic>('/me'),
          onOutcome: (o) => setState(() => _outcome = o),
        );
      });

  // --- Scenario D: multi-account -------------------------------------------

  Future<void> _runMultiAccount() => _guard('Multi-account', () async {
        final accountStorage = MemoryAccountTokenStorage();
        const alice = AccountId('alice');
        const bob = AccountId('bob');
        await accountStorage.write(alice, const TokenPair(access: 'alice-expired'));
        await accountStorage.write(bob, const TokenPair(access: 'bob-valid'));

        final dio = Dio();
        ResiliencePipeline.builder()
            .auth(
              accountStorage: accountStorage,
              refreshAccountToken: (account, current) async {
                _log.line('refreshing ${account.value}...');
                await Future<void>.delayed(const Duration(milliseconds: 200));
                return TokenPair(access: '${account.value}-fresh');
              },
              onAuthFailure: (r) => _log.line(
                'auth rejected for ${r.account?.value}: ${r.rejectedToken}',
                level: LogLevel.error,
              ),
            )
            .onEvent((e) {
              _log.onEvent(e);
              _stats.onEvent(e);
            })
            .build()
            .attachTo(dio);
        dio.httpClientAdapter = FakeHttpClientAdapter(
          (call) async {
            final auth = call.options.headers['Authorization'] as String?;
            if (auth == 'Bearer bob-valid') {
              return const FakeResult(200, data: {'user': 'bob'});
            }
            if (auth == 'Bearer alice-fresh') {
              return const FakeResult(200, data: {'user': 'alice'});
            }
            return const FakeResult(401, data: {'error': 'unauthorized'});
          },
          onWireCall: (_) => _stats.recordWireRequest(),
        );

        final stopwatch = Stopwatch()..start();
        final aliceResponse =
            await dio.get<dynamic>('/me', options: Options().withAccount(alice));
        final bobResponse =
            await dio.get<dynamic>('/me', options: Options().withAccount(bob));
        stopwatch.stop();
        _stats.recordLogicalCall(stopwatch.elapsed);
        setState(() {
          _summary = 'alice: ${aliceResponse.data}, bob: ${bobResponse.data}';
          _outcome = ScenarioSuccess(bobResponse);
        });
      });

  Future<void> _runAll() async {
    await _runConcurrentRefresh();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _runRefreshFailure();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _runNoRefresh();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _runMultiAccount();
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioScaffold(
      title: 'Auth & token refresh',
      explanation:
          'auth() injects the stored access token on every request. With a '
          'refreshToken callback, a 401 triggers a single-flight refresh: '
          'several concurrent 401s share one refresh call. Without it, a '
          '401 reaches the caller unchanged. withAccount() plus an '
          'AccountTokenStorage keep several signed-in identities separate.',
      controls: const [],
      actions: [
        FilledButton(
          onPressed: _busy ? null : _runConcurrentRefresh,
          child: const Text('Run: 5 concurrent 401s'),
        ),
        FilledButton(
          onPressed: _busy ? null : _runRefreshFailure,
          child: const Text('Run: refresh fails'),
        ),
        FilledButton(
          onPressed: _busy ? null : _runNoRefresh,
          child: const Text('Run: no-refresh mode'),
        ),
        FilledButton(
          onPressed: _busy ? null : _runMultiAccount,
          child: const Text('Run: multi-account'),
        ),
      ],
      outcome: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_summary != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_summary!, style: Theme.of(context).textTheme.bodyMedium),
            ),
          OutcomeCard(outcome: _outcome),
        ],
      ),
      log: _log,
      stats: _stats,
    );
  }
}
