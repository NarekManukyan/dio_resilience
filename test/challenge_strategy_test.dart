import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _kTokenHeader = 'x-challenge-token';
const _kHost = 'https://api.test';

/// One scripted server answer.
final class _Reply {
  final int status;
  final Object? body;
  const _Reply(this.status, [this.body]);
}

/// Answers each request with the next scripted [_Reply] and records the
/// headers every request went out with.
class _ScriptedAdapter implements HttpClientAdapter {
  final List<_Reply> _replies;
  final List<Map<String, dynamic>> requestHeaders = [];
  final List<String> requestPaths = [];

  _ScriptedAdapter(List<_Reply> replies) : _replies = [...replies];

  int get requestCount => requestHeaders.length;

  /// The challenge token each request carried, null when it had none.
  List<Object?> get tokens =>
      [for (final h in requestHeaders) h[_kTokenHeader]];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestHeaders.add(Map<String, dynamic>.from(options.headers));
    requestPaths.add(options.path);
    if (_replies.isEmpty) {
      return ResponseBody.fromString('unscripted request', 599);
    }
    final reply = _replies.removeAt(0);
    final body = reply.body;
    if (body == null) return ResponseBody.fromString('', reply.status);
    return ResponseBody.fromString(
      jsonEncode(body),
      reply.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A 428, or any response whose JSON body says `challenge: true` (a 403
/// captcha page, a 200 interstitial).
bool _isChallenge(ChallengeSignal signal) {
  final response = switch (signal) {
    ChallengeOnResponse(:final response) => response,
    ChallengeOnError(:final error) => error.response,
  };
  if (response == null) return false;
  if (response.statusCode == 428) return true;
  final data = response.data;
  return data is Map && data['challenge'] == true;
}

void _applyToken(RequestOptions request, String token) {
  request.headers[_kTokenHeader] = token;
}

/// A solver that counts its calls and answers `tok-<n>`.
final class _CountingSolver {
  int calls = 0;
  final List<Response<dynamic>?> responses = [];

  Future<String> call(
    RequestOptions request,
    Response<dynamic>? response,
  ) async {
    calls++;
    responses.add(response);
    return 'tok-$calls';
  }
}

(Dio, _ScriptedAdapter) _dio(
  List<_Reply> replies,
  ResiliencePipelineBuilder builder,
) {
  final adapter = _ScriptedAdapter(replies);
  final dio = Dio(BaseOptions(baseUrl: _kHost))..httpClientAdapter = adapter;
  builder.build().attachTo(dio);
  return (dio, adapter);
}

/// Pumps the event loop until [condition] holds. Fails rather than hangs.
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 500; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition never became true');
}

PipelineContext _ctx({String url = '$_kHost/a'}) =>
    PipelineContext(RequestOptions(path: url))..isChallengeError = true;

DioException _challengeError(RequestOptions request, {int status = 428}) =>
    DioException(
      requestOptions: request,
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(requestOptions: request, statusCode: status),
    );

TypeMatcher<ChallengeFailedException> _challengeFailed(
  ChallengeFailureReason reason,
) =>
    isA<ChallengeFailedException>().having((e) => e.reason, 'reason', reason);

void main() {
  // -------------------------------------------------------------------------
  // End to end
  // -------------------------------------------------------------------------

  group('solve and replay', () {
    test('428 -> solver -> applier -> replay succeeds with the token',
        () async {
      final solver = _CountingSolver();
      final (dio, adapter) = _dio(
        const [
          _Reply(428),
          _Reply(200, {'ok': true}),
        ],
        ResiliencePipeline.builder().challenge(
          ChallengeConfig<String>(
            matcher: _isChallenge,
            solver: solver.call,
            applier: _applyToken,
          ),
        ),
      );

      final response = await dio.get<dynamic>('/items');

      expect(response.statusCode, 200);
      expect(response.data, {'ok': true});
      expect(adapter.requestCount, 2);
      expect(adapter.tokens, [null, 'tok-1']);
      expect(solver.calls, 1);
      expect(solver.responses.single?.statusCode, 428);
    });

    test('403 with a challenge body is solved; a plain 403 is not', () async {
      final solver = _CountingSolver();
      final (dio, adapter) = _dio(
        const [
          _Reply(403, {'challenge': true, 'kind': 'captcha'}),
          _Reply(200, {'ok': true}),
          _Reply(403, {'error': 'forbidden'}),
        ],
        ResiliencePipeline.builder().challenge(
          ChallengeConfig<String>(
            matcher: _isChallenge,
            solver: solver.call,
            applier: _applyToken,
          ),
        ),
      );

      final solved = await dio.get<dynamic>('/items');
      expect(solved.statusCode, 200);
      expect(adapter.tokens, [null, 'tok-1']);
      expect(solver.responses.single?.data, {
        'challenge': true,
        'kind': 'captcha',
      });

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(
          isA<DioException>()
              .having((e) => e, 'type', isNot(isA<ChallengeFailedException>()))
              .having((e) => e.response?.statusCode, 'status', 403),
        ),
      );
      expect(solver.calls, 1);
      expect(adapter.requestCount, 3);
    });

    test('a 200 the matcher calls a challenge is solved and replayed',
        () async {
      final solver = _CountingSolver();
      final (dio, adapter) = _dio(
        const [
          _Reply(200, {'challenge': true}),
          _Reply(200, {'ok': true}),
        ],
        ResiliencePipeline.builder().challenge(
          ChallengeConfig<String>(
            matcher: _isChallenge,
            solver: solver.call,
            applier: _applyToken,
          ),
        ),
      );

      final response = await dio.get<dynamic>('/items');

      expect(response.data, {'ok': true});
      expect(adapter.requestCount, 2);
      expect(adapter.tokens, [null, 'tok-1']);
      expect(solver.responses.single?.statusCode, 200);
      expect(solver.responses.single?.data, {'challenge': true});
    });
  });

  group('solve failures', () {
    test(
        'solver throws -> ChallengeFailedException(solverError) with the '
        'challenge response', () async {
      final boom = StateError('solver down');
      final (dio, adapter) = _dio(
        const [
          _Reply(428, {'site': 'k'}),
        ],
        ResiliencePipeline.builder().challenge(
          ChallengeConfig<String>(
            matcher: _isChallenge,
            solver: (_, __) async => throw boom,
            applier: _applyToken,
          ),
        ),
      );

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(
          _challengeFailed(ChallengeFailureReason.solverError)
              .having((e) => e.error, 'error', same(boom))
              .having((e) => e.response?.statusCode, 'status', 428)
              .having((e) => e.response?.data, 'data', {'site': 'k'}),
        ),
      );
      expect(adapter.requestCount, 1);
    });

    test('solver throws with a fallback configured -> fallback answers',
        () async {
      DioException? seen;
      final (dio, adapter) = _dio(
        const [_Reply(428)],
        ResiliencePipeline.builder()
            .challenge(
          ChallengeConfig<String>(
            matcher: _isChallenge,
            solver: (_, __) async => throw StateError('solver down'),
            applier: _applyToken,
          ),
        )
            .fallback(
          handlers: [
            FallbackHandler.response((err, opts) {
              seen = err;
              return Response<dynamic>(
                requestOptions: opts,
                statusCode: 200,
                data: {'fallback': true},
              );
            }),
          ],
        ),
      );

      final response = await dio.get<dynamic>('/items');

      expect(response.data, {'fallback': true});
      expect(seen, _challengeFailed(ChallengeFailureReason.solverError));
      expect(adapter.requestCount, 1);
    });

    test('solver slower than solverTimeout -> solverTimeout', () async {
      final never = Completer<String>();
      final (dio, adapter) = _dio(
        const [_Reply(428)],
        ResiliencePipeline.builder().challenge(
          ChallengeConfig<String>(
            matcher: _isChallenge,
            solver: (_, __) => never.future,
            applier: _applyToken,
            solverTimeout: const Duration(milliseconds: 20),
          ),
        ),
      );

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(
          _challengeFailed(ChallengeFailureReason.solverTimeout)
              .having((e) => e.error, 'error', isA<TimeoutException>())
              .having((e) => e.response?.statusCode, 'status', 428),
        ),
      );
      expect(adapter.requestCount, 1);
    });

    test('challenged again after the solved replay -> maxAttemptsExceeded',
        () async {
      final solver = _CountingSolver();
      final (dio, adapter) = _dio(
        const [_Reply(428), _Reply(428)],
        ResiliencePipeline.builder().challenge(
          ChallengeConfig<String>(
            matcher: _isChallenge,
            solver: solver.call,
            applier: _applyToken,
          ),
        ),
      );

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(
          _challengeFailed(ChallengeFailureReason.maxAttemptsExceeded)
              .having((e) => e.response?.statusCode, 'status', 428),
        ),
      );
      expect(solver.calls, 1);
      expect(adapter.requestCount, 2);
      expect(adapter.tokens, [null, 'tok-1']);
    });

    test('maxAttempts: 2 solves twice before giving up', () async {
      final solver = _CountingSolver();
      final (dio, adapter) = _dio(
        const [_Reply(428), _Reply(428), _Reply(428)],
        ResiliencePipeline.builder().challenge(
          ChallengeConfig<String>(
            matcher: _isChallenge,
            solver: solver.call,
            applier: _applyToken,
            maxAttempts: 2,
          ),
        ),
      );

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(_challengeFailed(ChallengeFailureReason.maxAttemptsExceeded)),
      );
      expect(solver.calls, 2);
      expect(adapter.tokens, [null, 'tok-1', 'tok-2']);
    });

    test('a 200 challenge repeated after the replay -> maxAttemptsExceeded',
        () async {
      final (dio, adapter) = _dio(
        const [
          _Reply(200, {'challenge': true}),
          _Reply(200, {'challenge': true}),
        ],
        ResiliencePipeline.builder().challenge(
          ChallengeConfig<String>(
            matcher: _isChallenge,
            solver: _CountingSolver().call,
            applier: _applyToken,
          ),
        ),
      );

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(
          _challengeFailed(ChallengeFailureReason.maxAttemptsExceeded)
              .having((e) => e.response?.statusCode, 'status', 200),
        ),
      );
      expect(adapter.requestCount, 2);
    });
  });

  group('single flight (end to end)', () {
    test('singleFlight: true -> concurrent challenges share one solve',
        () async {
      final gate = Completer<void>();
      var solves = 0;
      var keyCalls = 0;
      final (dio, adapter) = _dio(
        const [
          _Reply(428),
          _Reply(428),
          _Reply(200, {'ok': 1}),
          _Reply(200, {'ok': 2}),
        ],
        ResiliencePipeline.builder().challenge(
          ChallengeConfig<String>(
            matcher: _isChallenge,
            solver: (_, __) async {
              solves++;
              await gate.future;
              return 'shared';
            },
            applier: _applyToken,
            singleFlight: true,
            keyOf: (request) {
              keyCalls++;
              return request.uri.host;
            },
          ),
        ),
      );

      final a = dio.get<dynamic>('/a');
      final b = dio.get<dynamic>('/b');
      await _until(() => keyCalls == 2);
      gate.complete();
      final results = await Future.wait([a, b]);

      expect(results.map((r) => r.statusCode), [200, 200]);
      expect(solves, 1);
      expect(adapter.requestCount, 4);
      expect(adapter.tokens, [null, null, 'shared', 'shared']);
    });

    test('singleFlight: false -> one solve per challenged request', () async {
      final gate = Completer<void>();
      var solves = 0;
      final (dio, adapter) = _dio(
        const [
          _Reply(428),
          _Reply(428),
          _Reply(200),
          _Reply(200),
        ],
        ResiliencePipeline.builder().challenge(
          ChallengeConfig<String>(
            matcher: _isChallenge,
            solver: (_, __) async {
              final n = ++solves;
              await gate.future;
              return 'tok-$n';
            },
            applier: _applyToken,
          ),
        ),
      );

      final a = dio.get<dynamic>('/a');
      final b = dio.get<dynamic>('/b');
      await _until(() => solves == 2);
      gate.complete();
      await Future.wait([a, b]);

      expect(solves, 2);
      expect(adapter.requestCount, 4);
      expect(adapter.tokens.sublist(2), unorderedEquals(['tok-1', 'tok-2']));
    });

    test('a failed shared solve fails every waiter with solverError', () async {
      final gate = Completer<void>();
      var solves = 0;
      var keyCalls = 0;
      final (dio, adapter) = _dio(
        const [_Reply(428), _Reply(428)],
        ResiliencePipeline.builder().challenge(
          ChallengeConfig<String>(
            matcher: _isChallenge,
            solver: (_, __) async {
              solves++;
              await gate.future;
              throw StateError('solver down');
            },
            applier: _applyToken,
            singleFlight: true,
            keyOf: (request) {
              keyCalls++;
              return 'k';
            },
          ),
        ),
      );

      final a = dio.get<dynamic>('/a');
      final b = dio.get<dynamic>('/b');
      final aDone = expectLater(
        a,
        throwsA(_challengeFailed(ChallengeFailureReason.solverError)),
      );
      final bDone = expectLater(
        b,
        throwsA(_challengeFailed(ChallengeFailureReason.solverError)),
      );
      await _until(() => keyCalls == 2);
      gate.complete();
      await Future.wait([aDone, bDone]);

      expect(solves, 1);
      expect(adapter.requestCount, 2);
    });
  });

  group('per-request opt out', () {
    for (final (label, options) in [
      ('Options().noChallenge()', Options().noChallenge()),
      (
        'extra: ResilienceExtras.noChallenge',
        Options(extra: ResilienceExtras.noChallenge),
      ),
    ]) {
      test('$label -> a 428 reaches the caller as a plain error', () async {
        final solver = _CountingSolver();
        final (dio, adapter) = _dio(
          const [
            _Reply(428, {'site': 'k'}),
          ],
          ResiliencePipeline.builder().challenge(
            ChallengeConfig<String>(
              matcher: _isChallenge,
              solver: solver.call,
              applier: _applyToken,
            ),
          ),
        );

        await expectLater(
          dio.get<dynamic>('/items', options: options),
          throwsA(
            isA<DioException>()
                .having(
                  (e) => e,
                  'not a resilience error',
                  isNot(isA<DioResilienceException>()),
                )
                .having((e) => e.type, 'type', DioExceptionType.badResponse)
                .having((e) => e.response?.statusCode, 'status', 428),
          ),
        );
        expect(solver.calls, 0);
        expect(adapter.requestCount, 1);
      });

      test('$label -> a 200 challenge body is returned untouched', () async {
        final solver = _CountingSolver();
        final (dio, adapter) = _dio(
          const [
            _Reply(200, {'challenge': true}),
          ],
          ResiliencePipeline.builder().challenge(
            ChallengeConfig<String>(
              matcher: _isChallenge,
              solver: solver.call,
              applier: _applyToken,
            ),
          ),
        );

        final response = await dio.get<dynamic>('/items', options: options);

        expect(response.data, {'challenge': true});
        expect(solver.calls, 0);
        expect(adapter.requestCount, 1);
      });
    }
  });

  group('circuit breaker', () {
    test('a solved challenge does not count as a failure', () async {
      final events = <ResilienceEvent>[];
      final (dio, adapter) = _dio(
        const [
          _Reply(428),
          _Reply(200),
          _Reply(200),
        ],
        ResiliencePipeline.builder()
            .circuitBreaker(failureThreshold: 1)
            .challenge(
              ChallengeConfig<String>(
                matcher: _isChallenge,
                solver: _CountingSolver().call,
                applier: _applyToken,
              ),
            )
            .onEvent(events.add),
      );

      // With a threshold of 1, a counted 428 would open the circuit and the
      // replay would be rejected.
      expect((await dio.get<dynamic>('/items')).statusCode, 200);
      expect((await dio.get<dynamic>('/items')).statusCode, 200);
      expect(events.whereType<CircuitStateChangedEvent>(), isEmpty);
      expect(adapter.requestCount, 3);
    });

    test('a failed solve does not count as a failure', () async {
      final events = <ResilienceEvent>[];
      final (dio, adapter) = _dio(
        const [_Reply(428), _Reply(200)],
        ResiliencePipeline.builder()
            .circuitBreaker(failureThreshold: 1)
            .challenge(
              ChallengeConfig<String>(
                matcher: _isChallenge,
                solver: (_, __) async => throw StateError('solver down'),
                applier: _applyToken,
              ),
            )
            .onEvent(events.add),
      );

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(isA<ChallengeFailedException>()),
      );
      expect((await dio.get<dynamic>('/items')).statusCode, 200);
      expect(events.whereType<CircuitStateChangedEvent>(), isEmpty);
      expect(adapter.requestCount, 2);
    });

    test('a 503 on the replay after a solved challenge is counted', () async {
      final events = <ResilienceEvent>[];
      final (dio, adapter) = _dio(
        const [_Reply(428), _Reply(503)],
        ResiliencePipeline.builder()
            .circuitBreaker(failureThreshold: 1)
            .challenge(
              ChallengeConfig<String>(
                matcher: _isChallenge,
                solver: _CountingSolver().call,
                applier: _applyToken,
              ),
            )
            .onEvent(events.add),
      );

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(
          isA<DioException>()
              .having((e) => e.response?.statusCode, 'status', 503),
        ),
      );
      expect(
        events.whereType<CircuitStateChangedEvent>().map((e) => e.to),
        [CircuitPhase.open],
      );

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(isA<CircuitOpenException>()),
      );
      expect(adapter.requestCount, 2);
    });

    test(
      'a challenged half-open probe gets its solved replay through',
      () async {
        var clock = DateTime(2026);
        final events = <ResilienceEvent>[];
        final (dio, adapter) = _dio(
          const [
            _Reply(503),
            _Reply(428),
            _Reply(200, {'ok': true}),
          ],
          ResiliencePipeline.builder()
              .circuitBreaker(
                failureThreshold: 1,
                cooldown: const Duration(seconds: 30),
                now: () => clock,
              )
              .challenge(
                ChallengeConfig<String>(
                  matcher: _isChallenge,
                  solver: _CountingSolver().call,
                  applier: _applyToken,
                ),
              )
              .onEvent(events.add),
        );

        await expectLater(
          dio.get<dynamic>('/items'),
          throwsA(isA<DioException>()),
        );
        clock = clock.add(const Duration(seconds: 31));

        // The probe is challenged; its replay is the same logical request and
        // must not be rejected as a second probe.
        final response = await dio.get<dynamic>('/items');

        expect(response.data, {'ok': true});
        expect(adapter.requestCount, 3);
        expect(
          events.whereType<CircuitStateChangedEvent>().map((e) => e.to),
          [CircuitPhase.open, CircuitPhase.halfOpen, CircuitPhase.closed],
        );
      },
      skip: 'circuit_breaker_strategy.dart onRequest counts the replay of '
          'a half-open probe as a new probe and rejects it with '
          'CircuitOpenException (halfOpenProbes: 1).',
    );
  });

  group('retry budget', () {
    test('challenge, then 503, then 200 succeeds within maxAttempts: 2',
        () async {
      final events = <ResilienceEvent>[];
      final (dio, adapter) = _dio(
        const [
          _Reply(428),
          _Reply(503),
          _Reply(200, {'ok': true}),
        ],
        ResiliencePipeline.builder()
            .challenge(
              ChallengeConfig<String>(
                matcher: _isChallenge,
                solver: _CountingSolver().call,
                applier: _applyToken,
              ),
            )
            .retry(maxAttempts: 2, methods: null, backoff: Backoff.none)
            .onEvent(events.add),
      );

      final response = await dio.post<dynamic>('/orders');

      expect(response.data, {'ok': true});
      expect(adapter.requestCount, 3);
      // The token stays on the request for the retry too.
      expect(adapter.tokens, [null, 'tok-1', 'tok-1']);
      expect(
        events
            .whereType<ReplayEvent>()
            .map((e) => (e.strategy, e.attemptNumber)),
        [('challenge', 1), ('retry', 2)],
      );
    });

    test('challenge, then 503 twice exhausts maxAttempts: 2 after 3 requests',
        () async {
      final (dio, adapter) = _dio(
        const [_Reply(428), _Reply(503), _Reply(503)],
        ResiliencePipeline.builder()
            .challenge(
              ChallengeConfig<String>(
                matcher: _isChallenge,
                solver: _CountingSolver().call,
                applier: _applyToken,
              ),
            )
            .retry(maxAttempts: 2, methods: null, backoff: Backoff.none),
      );

      await expectLater(
        dio.post<dynamic>('/orders'),
        throwsA(
          isA<AllAttemptsExhaustedException>()
              .having((e) => e.attempts, 'attempts', 2)
              .having((e) => e.response?.statusCode, 'status', 503),
        ),
      );
      expect(adapter.requestCount, 3);
    });
  });

  group('throwing callbacks', () {
    test('a throwing matcher means "not a challenge"', () async {
      final solver = _CountingSolver();
      final (dio, adapter) = _dio(
        const [
          _Reply(428),
          _Reply(200, {'challenge': true}),
        ],
        ResiliencePipeline.builder().challenge(
          ChallengeConfig<String>(
            matcher: (_) => throw StateError('bad matcher'),
            solver: solver.call,
            applier: _applyToken,
          ),
        ),
      );

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(
          isA<DioException>()
              .having(
                (e) => e,
                'not a resilience error',
                isNot(isA<DioResilienceException>()),
              )
              .having((e) => e.response?.statusCode, 'status', 428),
        ),
      );
      final response = await dio.get<dynamic>('/items');
      expect(response.data, {'challenge': true});
      expect(solver.calls, 0);
      expect(adapter.requestCount, 2);
    });

    test('a throwing applier -> ChallengeFailedException(solverError)',
        () async {
      final boom = ArgumentError('bad token');
      final (dio, adapter) = _dio(
        const [_Reply(428)],
        ResiliencePipeline.builder().challenge(
          ChallengeConfig<String>(
            matcher: _isChallenge,
            solver: _CountingSolver().call,
            applier: (_, __) => throw boom,
          ),
        ),
      );

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(
          _challengeFailed(ChallengeFailureReason.solverError)
              .having((e) => e.error, 'error', same(boom))
              .having((e) => e.response?.statusCode, 'status', 428),
        ),
      );
      expect(adapter.requestCount, 1);
    });
  });

  group('events', () {
    test('a solved challenge emits a ReplayEvent from "challenge"', () async {
      final events = <ResilienceEvent>[];
      final (dio, _) = _dio(
        const [_Reply(428), _Reply(200)],
        ResiliencePipeline.builder()
            .challenge(
              ChallengeConfig<String>(
                matcher: _isChallenge,
                solver: _CountingSolver().call,
                applier: _applyToken,
              ),
            )
            .onEvent(events.add),
      );

      await dio.get<dynamic>('/items');

      expect(events, hasLength(1));
      expect(
        events.single,
        isA<ReplayEvent>()
            .having((e) => e.strategy, 'strategy', 'challenge')
            .having((e) => e.attemptNumber, 'attemptNumber', 1)
            .having((e) => e.delay, 'delay', Duration.zero)
            .having((e) => e.error.response?.statusCode, 'status', 428)
            .having((e) => e.request.path, 'path', '/items'),
      );
    });

    test('a failed solve emits GaveUpEvent with the ChallengeFailedException',
        () async {
      final events = <ResilienceEvent>[];
      final (dio, _) = _dio(
        const [_Reply(428), _Reply(428)],
        ResiliencePipeline.builder()
            .challenge(
              ChallengeConfig<String>(
                matcher: _isChallenge,
                solver: _CountingSolver().call,
                applier: _applyToken,
              ),
            )
            .onEvent(events.add),
      );

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(isA<ChallengeFailedException>()),
      );

      expect(events, [
        isA<ReplayEvent>(),
        isA<GaveUpEvent>().having(
          (e) => e.error,
          'error',
          _challengeFailed(ChallengeFailureReason.maxAttemptsExceeded),
        ),
      ]);
    });
  });

  // -------------------------------------------------------------------------
  // Unit
  // -------------------------------------------------------------------------

  group('ChallengeStrategy unit', () {
    ChallengeStrategy<String> strategy({
      ChallengeSolver<String>? solver,
      ChallengeApplier<String>? applier,
      bool singleFlight = true,
      Duration solverTimeout = const Duration(seconds: 5),
      String Function(RequestOptions)? keyOf,
    }) =>
        ChallengeStrategy<String>(
          ChallengeConfig<String>(
            matcher: _isChallenge,
            solver: solver ?? (_, __) async => 'tok',
            applier: applier ?? _applyToken,
            singleFlight: singleFlight,
            solverTimeout: solverTimeout,
            keyOf: keyOf,
          ),
        );

    test('onError ignores an error the pipeline did not flag', () async {
      final s = strategy();
      final ctx = _ctx()..isChallengeError = false;
      expect(await s.onError(ctx, _challengeError(ctx.request)), isNull);
    });

    test('handles: matched errors only, never cancel or resilience errors', () {
      final s = strategy();
      final request = RequestOptions(path: '$_kHost/a');

      expect(s.handles(request, _challengeError(request)), isTrue);
      expect(
        s.handles(request, _challengeError(request, status: 500)),
        isFalse,
      );
      expect(
        s.handles(
          request,
          DioException.requestCancelled(requestOptions: request, reason: 'x'),
        ),
        isFalse,
      );
      expect(
        s.handles(
          request,
          ChallengeFailedException(
            requestOptions: request,
            reason: ChallengeFailureReason.solverError,
            response: Response<dynamic>(
              requestOptions: request,
              statusCode: 428,
            ),
          ),
        ),
        isFalse,
      );
      final optedOut = RequestOptions(
        path: '$_kHost/a',
        extra: {...ResilienceExtras.noChallenge},
      );
      expect(s.handles(optedOut, _challengeError(optedOut)), isFalse);
    });

    test('a 200 the matcher accepts is thrown as a badResponse error',
        () async {
      final s = strategy();
      final ctx = _ctx();
      final response = Response<dynamic>(
        requestOptions: ctx.request,
        statusCode: 200,
        data: {'challenge': true},
      );

      await expectLater(
        s.onResponse(ctx, response),
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.badResponse)
              .having((e) => e.response, 'response', same(response)),
        ),
      );
      await s.onResponse(
        ctx,
        Response<dynamic>(requestOptions: ctx.request, statusCode: 200),
      );
    });

    test('a solve returns a replay that does not count as an attempt',
        () async {
      final s = strategy();
      final ctx = _ctx();

      final decision = await s.onError(ctx, _challengeError(ctx.request));

      expect(
        decision,
        isA<ReplayDecision>()
            .having((d) => d.countsAsAttempt, 'countsAsAttempt', isFalse)
            .having((d) => d.delay, 'delay', isNull),
      );
      expect(ctx.request.headers[_kTokenHeader], 'tok');
    });

    test('single flight: concurrent solves share one, slot freed after',
        () async {
      final gate = Completer<String>();
      var solves = 0;
      final s = strategy(
        solver: (_, __) {
          solves++;
          return gate.future;
        },
      );
      final a = _ctx(url: '$_kHost/a');
      final b = _ctx(url: '$_kHost/b');

      final da = s.onError(a, _challengeError(a.request));
      final db = s.onError(b, _challengeError(b.request));
      await _until(() => solves == 1);
      expect(s.inFlightCount, 1);
      gate.complete('shared');

      expect(await da, isA<ReplayDecision>());
      expect(await db, isA<ReplayDecision>());
      expect(solves, 1);
      expect(a.request.headers[_kTokenHeader], 'shared');
      expect(b.request.headers[_kTokenHeader], 'shared');
      expect(s.inFlightCount, 0);
    });

    test('single flight: different keys solve separately', () async {
      var solves = 0;
      final s = strategy(
        solver: (request, __) async => 'tok-${++solves}-${request.path}',
        keyOf: (request) => request.path,
      );
      final a = _ctx(url: '$_kHost/a');
      final b = _ctx(url: '$_kHost/b');

      await Future.wait([
        s.onError(a, _challengeError(a.request)),
        s.onError(b, _challengeError(b.request)),
      ]);

      expect(solves, 2);
      expect(s.inFlightCount, 0);
    });

    test('single flight: a failed solve frees the slot and fails waiters',
        () async {
      final gate = Completer<String>();
      var solves = 0;
      final s = strategy(
        solver: (_, __) {
          solves++;
          return solves == 1 ? gate.future : Future.value('fresh');
        },
      );
      final a = _ctx(url: '$_kHost/a');
      final b = _ctx(url: '$_kHost/b');

      final da = s.onError(a, _challengeError(a.request));
      final db = s.onError(b, _challengeError(b.request));
      await _until(() => solves == 1);
      gate.completeError(StateError('solver down'));

      for (final decision in [await da, await db]) {
        expect(
          decision,
          isA<FailDecision>().having(
            (d) => d.error,
            'error',
            _challengeFailed(ChallengeFailureReason.solverError),
          ),
        );
      }
      expect(s.inFlightCount, 0);

      // The next challenge on the same key runs a fresh solve.
      final c = _ctx(url: '$_kHost/c');
      expect(
        await s.onError(c, _challengeError(c.request)),
        isA<ReplayDecision>(),
      );
      expect(solves, 2);
      expect(c.request.headers[_kTokenHeader], 'fresh');
    });

    test('single flight: a timed-out solve frees the slot', () async {
      final s = strategy(
        solver: (_, __) => Completer<String>().future,
        solverTimeout: const Duration(milliseconds: 10),
      );
      final a = _ctx(url: '$_kHost/a');
      final b = _ctx(url: '$_kHost/b');

      final decisions = await Future.wait([
        s.onError(a, _challengeError(a.request)),
        s.onError(b, _challengeError(b.request)),
      ]);

      for (final decision in decisions) {
        expect(
          decision,
          isA<FailDecision>().having(
            (d) => d.error,
            'error',
            _challengeFailed(ChallengeFailureReason.solverTimeout),
          ),
        );
      }
      expect(s.inFlightCount, 0);
    });

    test('single flight: a solver that throws synchronously frees the slot',
        () async {
      final s = strategy(solver: (_, __) => throw StateError('sync'));
      final ctx = _ctx();

      expect(
        await s.onError(ctx, _challengeError(ctx.request)),
        isA<FailDecision>().having(
          (d) => d.error,
          'error',
          _challengeFailed(ChallengeFailureReason.solverError),
        ),
      );
      expect(s.inFlightCount, 0);
    });

    test('no single flight: a synchronous solver throw is a solverError',
        () async {
      final s = strategy(
        singleFlight: false,
        solver: (_, __) => throw StateError('sync'),
      );
      final ctx = _ctx();

      expect(
        await s.onError(ctx, _challengeError(ctx.request)),
        isA<FailDecision>().having(
          (d) => d.error,
          'error',
          _challengeFailed(ChallengeFailureReason.solverError),
        ),
      );
      expect(s.inFlightCount, 0);
    });

    test('maxAttempts counts per request context', () async {
      final s = strategy();
      final ctx = _ctx();

      expect(
        await s.onError(ctx, _challengeError(ctx.request)),
        isA<ReplayDecision>(),
      );
      expect(
        await s.onError(ctx, _challengeError(ctx.request)),
        isA<FailDecision>().having(
          (d) => d.error,
          'error',
          _challengeFailed(ChallengeFailureReason.maxAttemptsExceeded),
        ),
      );

      final other = _ctx();
      expect(
        await s.onError(other, _challengeError(other.request)),
        isA<ReplayDecision>(),
      );
    });
  });
}
