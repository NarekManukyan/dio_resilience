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

class ChallengeScreen extends StatefulWidget {
  const ChallengeScreen({super.key});

  @override
  State<ChallengeScreen> createState() => _ChallengeScreenState();
}

class _ChallengeScreenState extends State<ChallengeScreen> {
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

  // The pipeline only builds a ChallengeOnError when the failure has NO
  // response at all (a transport-level failure); any failure that does
  // carry a Response — including a plain 4xx — arrives as a
  // ChallengeOnResponse instead, matching [ChallengeStrategy.handles] rather
  // than that class's doc comment, which claims a 4xx body is still seen as
  // ChallengeOnError. See lib/src/strategies/challenge_strategy.dart:33-36
  // vs. :159-171 in the package — reported upstream.
  bool _matcher(ChallengeSignal signal) => switch (signal) {
        ChallengeOnResponse(:final response) =>
          response.statusCode == 428 ||
              (response.data is Map && (response.data as Map)['challenge'] == true),
        ChallengeOnError() => false,
      };

  Future<String> _dialogSolver(
    RequestOptions request,
    Response<dynamic>? response,
  ) async {
    _log.line('showing the CAPTCHA...', level: LogLevel.warn);
    final token = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CaptchaDialog(),
    );
    if (token == null) throw StateError('solver produced no token');
    _log.line('CAPTCHA solved: $token', level: LogLevel.success);
    return token;
  }

  Future<String> _failingSolver(
    RequestOptions request,
    Response<dynamic>? response,
  ) async {
    _log.line('solver throwing on purpose...', level: LogLevel.error);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    throw Exception('captcha service unavailable');
  }

  void _applier(RequestOptions request, String token) {
    request.headers['X-Captcha-Token'] = token;
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

  Future<void> _runSuccessResponseChallenge() {
    final dio = Dio();
    ResiliencePipeline.builder()
        .challenge(ChallengeConfig<String>(
          matcher: _matcher,
          solver: _dialogSolver,
          applier: _applier,
        ))
        .onEvent((e) {
          _log.onEvent(e);
          _stats.onEvent(e);
        })
        .build()
        .attachTo(dio);
    dio.httpClientAdapter = FakeHttpClientAdapter((call) async {
      final solved = call.options.headers['X-Captcha-Token'] != null;
      if (!solved) {
        return const FakeResult(200, data: {'challenge': true, 'siteKey': 'demo'});
      }
      return const FakeResult(200, data: {'status': 'ok'});
    }, onWireCall: (_) => _stats.recordWireRequest());
    return _run(() => dio.get<dynamic>('/challenge-200'));
  }

  Future<void> _runErrorChallenge() {
    final dio = Dio();
    ResiliencePipeline.builder()
        .challenge(ChallengeConfig<String>(
          matcher: _matcher,
          solver: _dialogSolver,
          applier: _applier,
        ))
        .onEvent((e) {
          _log.onEvent(e);
          _stats.onEvent(e);
        })
        .build()
        .attachTo(dio);
    dio.httpClientAdapter = FakeHttpClientAdapter((call) async {
      final solved = call.options.headers['X-Captcha-Token'] != null;
      if (!solved) {
        return const FakeResult(428, data: {'error': 'captcha_required'});
      }
      return const FakeResult(200, data: {'status': 'ok'});
    }, onWireCall: (_) => _stats.recordWireRequest());
    return _run(() => dio.get<dynamic>('/challenge-428'));
  }

  Future<void> _runSolverFailure() {
    final dio = Dio();
    ResiliencePipeline.builder()
        .challenge(ChallengeConfig<String>(
          matcher: _matcher,
          solver: _failingSolver,
          applier: _applier,
        ))
        .onEvent((e) {
          _log.onEvent(e);
          _stats.onEvent(e);
        })
        .build()
        .attachTo(dio);
    dio.httpClientAdapter = FakeHttpClientAdapter(
      (call) async => const FakeResult(428, data: {'error': 'captcha_required'}),
      onWireCall: (_) => _stats.recordWireRequest(),
    );
    return _run(() => dio.get<dynamic>('/challenge-fail'));
  }

  Future<void> _runAll() async {
    await _runSuccessResponseChallenge();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _runErrorChallenge();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _runSolverFailure();
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioScaffold(
      title: 'Challenge',
      explanation:
          'challenge() intercepts a server-issued proof challenge — even a '
          '200 whose body asks for one — solves it (here, a mock CAPTCHA '
          'dialog) and replays with the token attached, without touching '
          'the retry budget. A solver that throws ends the request with a '
          'typed ChallengeFailedException.',
      controls: const [],
      actions: [
        FilledButton(
          onPressed: _busy ? null : _runSuccessResponseChallenge,
          child: const Text('Run: 200 with challenge body'),
        ),
        FilledButton(
          onPressed: _busy ? null : _runErrorChallenge,
          child: const Text('Run: 428 challenge'),
        ),
        FilledButton(
          onPressed: _busy ? null : _runSolverFailure,
          child: const Text('Run: solver fails'),
        ),
      ],
      outcome: OutcomeCard(outcome: _outcome),
      log: _log,
      stats: _stats,
    );
  }
}

class _CaptchaDialog extends StatefulWidget {
  const _CaptchaDialog();

  @override
  State<_CaptchaDialog> createState() => _CaptchaDialogState();
}

class _CaptchaDialogState extends State<_CaptchaDialog> {
  @override
  void initState() {
    super.initState();
    if (kDemoAutoplay) {
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (mounted) Navigator.of(context).pop('solved-token');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Prove you are human'),
      content: const Text('(Mock CAPTCHA standing in for the real thing.)'),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop('solved-token'),
          child: const Text("I'm human"),
        ),
      ],
    );
  }
}
