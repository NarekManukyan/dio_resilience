import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';
import 'package:test/test.dart';

/// One scripted answer of [_ScriptedAdapter].
final class _Step {
  final int status;
  final Object? body;
  final Map<String, List<String>> headers;
  final Duration delay;
  final DioExceptionType? throwType;
  final Object? throwCause;

  const _Step(
    this.status, {
    this.headers = const {},
    this.delay = Duration.zero,
  })  : body = null,
        throwType = null,
        throwCause = null;

  const _Step.fail(
    DioExceptionType type, {
    Object? cause,
  })  : status = 0,
        delay = Duration.zero,
        body = null,
        headers = const {},
        throwType = type,
        throwCause = cause;
}

/// A fake adapter answering with [steps] in order (the last one repeats)
/// and recording every request it receives.
final class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.steps);

  final List<_Step> steps;
  final List<RequestOptions> requests = [];
  int _next = 0;

  int get calls => requests.length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    // A snapshot: a replay re-sends and mutates the same options object.
    requests.add(options.copyWith(headers: {...options.headers}));
    final step = steps[_next < steps.length ? _next++ : steps.length - 1];
    if (step.delay > Duration.zero) {
      await Future.any<void>([
        Future<void>.delayed(step.delay),
        if (cancelFuture != null) cancelFuture,
      ]);
    }
    final type = step.throwType;
    if (type != null) {
      throw DioException(
        requestOptions: options,
        type: type,
        error: step.throwCause,
      );
    }
    return ResponseBody.fromString(
      step.body == null ? '' : jsonEncode(step.body),
      step.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...step.headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Records what an interceptor registered after the pipeline sees.
final class _Recorder extends Interceptor {
  final List<String> requests = [];
  final List<DioException> errors = [];
  final List<int?> responses = [];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add(options.path);
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler h) {
    responses.add(response.statusCode);
    h.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    errors.add(err);
    handler.next(err);
  }
}

const _noBackoff = Backoff.constant(Duration.zero);

Dio _dio(_ScriptedAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.example.com'))
      ..httpClientAdapter = adapter;

void main() {
  group('replay loop', () {
    test('an interceptor behind the pipeline sees the final error once',
        () async {
      final adapter = _ScriptedAdapter(const [_Step(503)]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .retry(maxAttempts: 3, backoff: _noBackoff)
          .build()
          .attachTo(dio);
      final recorder = _Recorder();
      dio.interceptors.add(recorder);

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(isA<AllAttemptsExhaustedException>()),
      );
      expect(adapter.calls, 3);
      expect(recorder.requests, hasLength(3));
      expect(recorder.errors, hasLength(1));
      expect(recorder.errors.single, isA<AllAttemptsExhaustedException>());
    });

    test('a retried success reaches the interceptor behind once, no error',
        () async {
      final adapter =
          _ScriptedAdapter(const [_Step(503), _Step(503), _Step(200)]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .retry(maxAttempts: 3, backoff: _noBackoff)
          .build()
          .attachTo(dio);
      final recorder = _Recorder();
      dio.interceptors.add(recorder);

      final response = await dio.get<dynamic>('/items');
      expect(response.statusCode, 200);
      expect(recorder.errors, isEmpty);
      expect(recorder.responses, [200]);
    });

    test('an exhausted retry keeps the last attempt type and error', () async {
      final adapter = _ScriptedAdapter(
        const [_Step.fail(DioExceptionType.connectionTimeout)],
      );
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .retry(maxAttempts: 2, backoff: _noBackoff)
          .build()
          .attachTo(dio);

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(
          isA<AllAttemptsExhaustedException>()
              .having((e) => e.type, 'type', DioExceptionType.connectionTimeout)
              .having(
                (e) => e.lastError.type,
                'lastError.type',
                DioExceptionType.connectionTimeout,
              )
              .having((e) => e.attempts, 'attempts', 2),
        ),
      );
    });

    test('a POST is not retried by default', () async {
      final adapter = _ScriptedAdapter(const [_Step(503)]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .retry(maxAttempts: 3, backoff: _noBackoff)
          .build()
          .attachTo(dio);

      await expectLater(
        dio.post<dynamic>('/charge'),
        throwsA(
          isA<DioException>()
              .having((e) => e.response?.statusCode, 'status', 503),
        ),
      );
      expect(adapter.calls, 1);
    });

    test('ResilienceExtras.noRetry turns retry off for the request', () async {
      final adapter = _ScriptedAdapter(const [_Step(503)]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .retry(maxAttempts: 3, backoff: _noBackoff)
          .build()
          .attachTo(dio);

      await expectLater(
        dio.get<dynamic>(
          '/items',
          options: Options(extra: {...ResilienceExtras.noRetry}),
        ),
        throwsA(isA<DioException>()),
      );
      expect(adapter.calls, 1);
    });

    test('a Retry-After past maxRetryAfter ends the request with the 503',
        () async {
      final adapter = _ScriptedAdapter(const [
        _Step(
          503,
          headers: {
            'retry-after': ['600'],
          },
        ),
      ]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .retry(maxAttempts: 3, backoff: _noBackoff)
          .build()
          .attachTo(dio);

      final watch = Stopwatch()..start();
      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(
          isA<DioException>()
              .having((e) => e.response?.statusCode, 'status', 503),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(adapter.calls, 1);
    });

    test('the same RequestOptions fetched again starts a fresh context',
        () async {
      final adapter = _ScriptedAdapter(
        const [_Step(503), _Step(200), _Step(503), _Step(200)],
      );
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .retry(maxAttempts: 2, backoff: _noBackoff)
          .build()
          .attachTo(dio);

      final first = await dio.get<dynamic>('/items');
      final second = await dio.fetch<dynamic>(first.requestOptions);
      expect(second.statusCode, 200);
      expect(adapter.calls, 4);
    });

    test('caller cancellation during backoff ends the request', () async {
      final adapter = _ScriptedAdapter(const [_Step(503), _Step(200)]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .retry(
            maxAttempts: 3,
            backoff: const Backoff.constant(Duration(seconds: 5)),
          )
          .build()
          .attachTo(dio);

      final token = CancelToken();
      final call = dio.get<dynamic>('/items', cancelToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      token.cancel('user left');

      await expectLater(
        call,
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.cancel),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(adapter.calls, 1);
    });
  });

  group('attachTo', () {
    test('attaching twice registers the pipeline once', () {
      final dio = _dio(_ScriptedAdapter(const [_Step(200)]));
      final pipeline = ResiliencePipeline.builder().build();
      pipeline
        ..attachTo(dio)
        ..attachTo(dio);
      expect(dio.interceptors.whereType<ResiliencePipeline>(), hasLength(1));
    });

    test('adding the pipeline without attachTo fails clearly', () async {
      final dio = _dio(_ScriptedAdapter(const [_Step(200)]));
      dio.interceptors.add(ResiliencePipeline.builder().build());

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(
          isA<DioException>().having((e) => e.error, 'error', isStateError),
        ),
      );
    });

    test('attaching to a second Dio throws', () {
      final pipeline = ResiliencePipeline.builder().build()
        ..attachTo(_dio(_ScriptedAdapter(const [_Step(200)])));
      expect(
        () => pipeline.attachTo(_dio(_ScriptedAdapter(const [_Step(200)]))),
        throwsStateError,
      );
    });
  });

  group('fallback', () {
    Response<dynamic> canned(DioException err, RequestOptions opts) =>
        Response<dynamic>(
          requestOptions: opts,
          statusCode: 200,
          data: {'cached': true},
        );

    test('answers after retries are exhausted', () async {
      final adapter = _ScriptedAdapter(const [_Step(503)]);
      final dio = _dio(adapter);
      final events = <ResilienceEvent>[];
      ResiliencePipeline.builder()
          .retry(maxAttempts: 2, backoff: _noBackoff)
          .fallback(handlers: [FallbackHandler.response(canned)])
          .onEvent(events.add)
          .build()
          .attachTo(dio);

      final response = await dio.get<dynamic>('/items');
      expect(response.data, {'cached': true});
      expect(adapter.calls, 2);
      expect(
        events.whereType<RecoveredEvent>().single.error,
        isA<AllAttemptsExhaustedException>(),
      );
    });

    test('answers an open circuit', () async {
      final adapter = _ScriptedAdapter(const [_Step(503)]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .circuitBreaker(failureThreshold: 1)
          .fallback(handlers: [FallbackHandler.response(canned)])
          .build()
          .attachTo(dio);

      // Trips the circuit; fallback answers the 503 too.
      await dio.get<dynamic>('/items');
      final response = await dio.get<dynamic>('/items');
      expect(response.data, {'cached': true});
      expect(adapter.calls, 1);
    });

    test('answers when the next retry would not fit the budget', () async {
      final adapter = _ScriptedAdapter(const [_Step(503)]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .retry(
            maxAttempts: 3,
            backoff: const Backoff.constant(Duration(seconds: 10)),
          )
          .timeout(total: const Duration(seconds: 1))
          .fallback(handlers: [FallbackHandler.response(canned)])
          .build()
          .attachTo(dio);

      final response = await dio.get<dynamic>('/items');
      expect(response.data, {'cached': true});
      expect(adapter.calls, 1);
    });

    test('an endpoint fallback that fails does not fall back again', () async {
      final adapter = _ScriptedAdapter(const [_Step(503)]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .fallback(
            handlers: [
              const FallbackHandler.endpoint('https://mirror.example.com/x'),
            ],
          )
          .build()
          .attachTo(dio);

      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(isA<DioException>()),
      );
      expect(adapter.calls, 2);
    });

    test('does not answer a cancellation', () async {
      final adapter = _ScriptedAdapter(
        const [_Step(200, delay: Duration(seconds: 1))],
      );
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .fallback(handlers: [FallbackHandler.response(canned)])
          .build()
          .attachTo(dio);

      final token = CancelToken();
      final call = dio.get<dynamic>('/items', cancelToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel();
      await expectLater(
        call,
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.cancel),
        ),
      );
    });
  });

  group('total budget', () {
    test('cuts an attempt still in flight at the deadline', () async {
      final adapter = _ScriptedAdapter(
        const [_Step(200, delay: Duration(seconds: 5))],
      );
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .timeout(total: const Duration(milliseconds: 100))
          .build()
          .attachTo(dio);

      final watch = Stopwatch()..start();
      await expectLater(
        dio.get<dynamic>('/slow'),
        throwsA(isA<PipelineTimeoutException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('cuts a replayed attempt at the deadline', () async {
      final adapter = _ScriptedAdapter(const [
        _Step(503),
        _Step(200, delay: Duration(seconds: 5)),
      ]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .retry(maxAttempts: 3, backoff: _noBackoff)
          .timeout(total: const Duration(milliseconds: 150))
          .build()
          .attachTo(dio);

      await expectLater(
        dio.get<dynamic>('/slow'),
        throwsA(isA<PipelineTimeoutException>()),
      );
      expect(adapter.calls, 2);
    });

    test('a retry wait longer than the budget left fails at once', () async {
      final adapter = _ScriptedAdapter(const [_Step(503)]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .retry(
            maxAttempts: 3,
            backoff: const Backoff.constant(Duration(seconds: 10)),
          )
          .timeout(total: const Duration(seconds: 2))
          .build()
          .attachTo(dio);

      final watch = Stopwatch()..start();
      await expectLater(
        dio.get<dynamic>('/items'),
        throwsA(
          isA<PipelineTimeoutException>().having(
            (e) => e.lastError?.response?.statusCode,
            'lastError status',
            503,
          ),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test("the caller's cancel token still cancels under a budget", () async {
      final adapter = _ScriptedAdapter(
        const [_Step(200, delay: Duration(seconds: 5))],
      );
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .timeout(total: const Duration(seconds: 30))
          .build()
          .attachTo(dio);

      final token = CancelToken();
      final call = dio.get<dynamic>('/slow', cancelToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel('bye');
      await expectLater(
        call,
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.cancel)
              .having((e) => e.error, 'reason', 'bye'),
        ),
      );
    });

    test('perAttempt leaves sendTimeout alone', () async {
      final adapter = _ScriptedAdapter(const [_Step(200)]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .timeout(perAttempt: const Duration(seconds: 3))
          .build()
          .attachTo(dio);

      await dio.post<dynamic>('/upload', data: {'a': 1});
      final sent = adapter.requests.single;
      expect(sent.sendTimeout, isNull);
      expect(sent.receiveTimeout, const Duration(seconds: 3));
      expect(sent.connectTimeout, const Duration(seconds: 3));
    });

    test('the rate limiter sees the budget on the first request', () async {
      final adapter = _ScriptedAdapter(const [_Step(200)]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .rateLimit(
            algorithm: const RateLimitAlgorithm.tokenBucket(
              ratePerSecond: 0.1,
              burst: 1,
            ),
          )
          .timeout(total: const Duration(seconds: 1))
          .build()
          .attachTo(dio);

      await dio.get<dynamic>('/a');
      await expectLater(
        dio.get<dynamic>('/b'),
        throwsA(isA<RateLimitExceededException>()),
      );
    });
  });

  group('auth', () {
    test('a refresh replay does not use a retry attempt', () async {
      final adapter =
          _ScriptedAdapter(const [_Step(401), _Step(503), _Step(200)]);
      final dio = _dio(adapter);
      final storage = MemoryTokenStorage();
      await storage.write(const TokenPair(access: 'old'));
      ResiliencePipeline.builder()
          .auth(
            tokenStorage: storage,
            refreshToken: (_) async => const TokenPair(access: 'new'),
          )
          .retry(maxAttempts: 2, backoff: _noBackoff)
          .build()
          .attachTo(dio);

      final response = await dio.get<dynamic>('/me');
      expect(response.statusCode, 200);
      expect(adapter.calls, 3);
      expect(adapter.requests.last.headers['Authorization'], 'Bearer new');
    });

    test('a 401 for the refreshed token ends the request, no loop', () async {
      final adapter = _ScriptedAdapter(const [_Step(401)]);
      final dio = _dio(adapter);
      final storage = MemoryTokenStorage();
      await storage.write(const TokenPair(access: 'old'));
      var refreshes = 0;
      ResiliencePipeline.builder()
          .auth(
            tokenStorage: storage,
            refreshToken: (_) async {
              refreshes++;
              return TokenPair(access: 'new$refreshes');
            },
          )
          .build()
          .attachTo(dio);

      await expectLater(
        dio.get<dynamic>('/me'),
        throwsA(
          isA<RefreshFailedException>()
              .having((e) => e.response?.statusCode, 'status', 401),
        ),
      );
      expect(refreshes, 1);
      expect(adapter.calls, 2);
    });

    test('concurrent 401s share one refresh', () async {
      final adapter = _ScriptedAdapter(const [
        _Step(401, delay: Duration(milliseconds: 10)),
        _Step(401, delay: Duration(milliseconds: 10)),
        _Step(401, delay: Duration(milliseconds: 10)),
        _Step(200),
      ]);
      final dio = _dio(adapter);
      final storage = MemoryTokenStorage();
      await storage.write(const TokenPair(access: 'old'));
      var refreshes = 0;
      ResiliencePipeline.builder()
          .auth(
            tokenStorage: storage,
            refreshToken: (_) async {
              refreshes++;
              await Future<void>.delayed(const Duration(milliseconds: 30));
              return const TokenPair(access: 'new');
            },
          )
          .build()
          .attachTo(dio);

      final responses = await Future.wait([
        dio.get<dynamic>('/a'),
        dio.get<dynamic>('/b'),
        dio.get<dynamic>('/c'),
      ]);
      expect(responses.map((r) => r.statusCode), everyElement(200));
      expect(refreshes, 1);
    });

    test('a 401 for a token already replaced replays without refreshing',
        () async {
      final storage = MemoryTokenStorage();
      await storage.write(const TokenPair(access: 'old'));
      var refreshes = 0;
      // In order of arrival: /a's 401 comes back at once; /b, sent with the
      // same old token, answers 401 only after /a's refresh is done.
      final adapter = _ScriptedAdapter(const [
        _Step(401),
        _Step(401, delay: Duration(milliseconds: 120)),
        _Step(200),
        _Step(200),
      ]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .auth(
            tokenStorage: storage,
            refreshToken: (_) async {
              refreshes++;
              await Future<void>.delayed(const Duration(milliseconds: 20));
              return const TokenPair(access: 'new');
            },
          )
          .build()
          .attachTo(dio);

      final responses = await Future.wait([
        dio.get<dynamic>('/a'),
        dio.get<dynamic>('/b'),
      ]);
      expect(responses.map((r) => r.statusCode), [200, 200]);
      expect(refreshes, 1);
      expect(
        adapter.requests.map((r) => r.headers['Authorization']),
        ['Bearer old', 'Bearer old', 'Bearer new', 'Bearer new'],
      );
    });

    test('waiters on a failed refresh get errors about their own requests',
        () async {
      final adapter = _ScriptedAdapter(
        const [_Step(401, delay: Duration(milliseconds: 10))],
      );
      final dio = _dio(adapter);
      final storage = MemoryTokenStorage();
      await storage.write(const TokenPair(access: 'old'));
      ResiliencePipeline.builder()
          .auth(
            tokenStorage: storage,
            refreshToken: (_) async {
              await Future<void>.delayed(const Duration(milliseconds: 30));
              throw Exception('refresh endpoint down');
            },
          )
          .build()
          .attachTo(dio);

      Future<String?> pathOfFailure(String path) => dio
          .get<dynamic>(path)
          .then<String?>((_) => null)
          .catchError((Object e) => (e as DioException).requestOptions.path);

      final paths = await Future.wait([
        pathOfFailure('/a'),
        pathOfFailure('/b'),
      ]);
      expect(paths, ['/a', '/b']);
    });

    test('without refreshToken a 401 reaches the caller and is reported',
        () async {
      final adapter = _ScriptedAdapter(const [_Step(401)]);
      final dio = _dio(adapter);
      final storage = MemoryTokenStorage();
      await storage.write(const TokenPair(access: 'tok'));
      final rejections = <AuthRejection>[];
      ResiliencePipeline.builder()
          .auth(tokenStorage: storage, onAuthFailure: rejections.add)
          .build()
          .attachTo(dio);

      await expectLater(
        dio.get<dynamic>('/me'),
        throwsA(
          isA<DioException>()
              .having((e) => e.response?.statusCode, 'status', 401),
        ),
      );
      expect(rejections.single.rejectedToken, 'tok');
      expect(rejections.single.refreshAttempted, isFalse);
      expect(await storage.read(), isNotNull);
    });

    test('a failed refresh reports the rejected token', () async {
      final adapter = _ScriptedAdapter(const [_Step(401)]);
      final dio = _dio(adapter);
      final storage = MemoryTokenStorage();
      await storage.write(const TokenPair(access: 'tok'));
      final rejections = <AuthRejection>[];
      ResiliencePipeline.builder()
          .auth(
            tokenStorage: storage,
            refreshToken: (_) async => null,
            onAuthFailure: rejections.add,
            clearTokensOnRefreshFailure: false,
          )
          .build()
          .attachTo(dio);

      await expectLater(
        dio.get<dynamic>('/me'),
        throwsA(isA<RefreshFailedException>()),
      );
      expect(rejections.single.rejectedToken, 'tok');
      expect(rejections.single.refreshAttempted, isTrue);
      expect(await storage.read(), isNotNull);
    });

    test('an expired token is refreshed before the request is sent', () async {
      final adapter = _ScriptedAdapter(const [_Step(200)]);
      final dio = _dio(adapter);
      final storage = MemoryTokenStorage();
      await storage.write(
        TokenPair(
          access: 'expired',
          accessExpiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        ),
      );
      ResiliencePipeline.builder()
          .auth(
            tokenStorage: storage,
            refreshToken: (_) async => const TokenPair(access: 'fresh'),
          )
          .build()
          .attachTo(dio);

      await dio.get<dynamic>('/me');
      expect(adapter.requests.single.headers['Authorization'], 'Bearer fresh');
    });

    test('a failed preemptive refresh surfaces as RefreshFailedException',
        () async {
      final adapter = _ScriptedAdapter(const [_Step(200)]);
      final dio = _dio(adapter);
      final storage = MemoryTokenStorage();
      await storage.write(
        TokenPair(
          access: 'expired',
          accessExpiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        ),
      );
      ResiliencePipeline.builder()
          .auth(
            tokenStorage: storage,
            refreshToken: (_) async => throw Exception('down'),
          )
          .build()
          .attachTo(dio);

      await expectLater(
        dio.get<dynamic>('/me'),
        throwsA(isA<RefreshFailedException>()),
      );
      expect(adapter.calls, 0);
    });

    test('withAccount uses that account token and refreshes it alone',
        () async {
      final adapter = _ScriptedAdapter(const [_Step(401), _Step(200)]);
      final dio = _dio(adapter);
      final accounts = MemoryAccountTokenStorage();
      await accounts.write(
        const AccountId('bob'),
        const TokenPair(access: 'bob-old'),
      );
      final refreshed = <AccountId>[];
      ResiliencePipeline.builder()
          .auth(
            tokenStorage: MemoryTokenStorage(),
            accountStorage: accounts,
            refreshAccountToken: (account, _) async {
              refreshed.add(account);
              return const TokenPair(access: 'bob-new');
            },
          )
          .build()
          .attachTo(dio);

      await dio.get<dynamic>(
        '/me',
        options: Options().withAccount(const AccountId('bob')),
      );
      expect(adapter.requests.first.headers['Authorization'], 'Bearer bob-old');
      expect(adapter.requests.last.headers['Authorization'], 'Bearer bob-new');
      expect(refreshed, [const AccountId('bob')]);
      expect(
        (await accounts.read(const AccountId('bob')))?.access,
        'bob-new',
      );
    });

    test('ResilienceExtras.noAuth skips injection', () async {
      final adapter = _ScriptedAdapter(const [_Step(200)]);
      final dio = _dio(adapter);
      final storage = MemoryTokenStorage();
      await storage.write(const TokenPair(access: 'tok'));
      ResiliencePipeline.builder()
          .auth(tokenStorage: storage)
          .build()
          .attachTo(dio);

      await dio.get<dynamic>(
        '/otp',
        options: Options(extra: {...ResilienceExtras.noAuth}),
      );
      expect(adapter.requests.single.headers['Authorization'], isNull);
    });

    test('the auth state stream emits only changes', () async {
      final adapter = _ScriptedAdapter(const [_Step(200)]);
      final dio = _dio(adapter);
      final storage = MemoryTokenStorage();
      await storage.write(const TokenPair(access: 'tok'));
      final pipeline = ResiliencePipeline.builder()
          .auth(tokenStorage: storage)
          .build()
        ..attachTo(dio);
      final states = <AuthState>[];
      final sub = pipeline.authStateStream.listen(states.add);

      await dio.get<dynamic>('/a');
      await dio.get<dynamic>('/b');
      await Future<void>.delayed(Duration.zero);
      expect(states, [AuthState.authenticated]);
      await sub.cancel();
      pipeline.dispose();
    });
  });

  group('hedging', () {
    test('a failed hedging round is retried as one attempt', () async {
      final adapter = _ScriptedAdapter(const [
        _Step(503, delay: Duration(milliseconds: 30)),
        _Step(503, delay: Duration(milliseconds: 30)),
        _Step(200),
      ]);
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .hedging(maxParallel: 2, delay: const Duration(milliseconds: 5))
          .retry(maxAttempts: 2, backoff: _noBackoff)
          .build()
          .attachTo(dio);

      final response = await dio.get<dynamic>('/items');
      expect(response.statusCode, 200);
      // Round 1: two branches. Round 2 (the retry): the primary wins.
      expect(adapter.calls, inInclusiveRange(3, 4));
    });

    test("the caller's cancel ends a hedging round", () async {
      final adapter = _ScriptedAdapter(
        const [_Step(200, delay: Duration(seconds: 5))],
      );
      final dio = _dio(adapter);
      ResiliencePipeline.builder()
          .hedging(maxParallel: 2, delay: const Duration(milliseconds: 5))
          .build()
          .attachTo(dio);

      final token = CancelToken();
      final call = dio.get<dynamic>('/items', cancelToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      token.cancel();
      await expectLater(
        call,
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.cancel),
        ),
      );
    });
  });

  group('circuit breaker', () {
    test('reports state changes as events', () async {
      final adapter = _ScriptedAdapter(const [_Step(503)]);
      final dio = _dio(adapter);
      final events = <ResilienceEvent>[];
      ResiliencePipeline.builder()
          .circuitBreaker(failureThreshold: 2)
          .onEvent(events.add)
          .build()
          .attachTo(dio);

      for (var i = 0; i < 3; i++) {
        await dio.get<dynamic>('/items').catchError(
              (Object _) => Response<dynamic>(requestOptions: RequestOptions()),
            );
      }
      final changes = events.whereType<CircuitStateChangedEvent>().toList();
      expect(changes, hasLength(1));
      expect(changes.single.to, CircuitPhase.open);
      expect(adapter.calls, 2);
    });

    test('does not count a cancelled request', () async {
      final adapter = _ScriptedAdapter(
        const [_Step(200, delay: Duration(seconds: 1))],
      );
      final dio = _dio(adapter);
      final circuit = CircuitBreakerStrategy(failureThreshold: 1);
      final ctx = PipelineContext(RequestOptions(path: 'https://h/x'));
      final cancel = DioException.requestCancelled(
        requestOptions: ctx.request,
        reason: 'x',
      );
      await circuit.onError(ctx, cancel);
      expect(circuit.phaseFor('h'), CircuitPhase.closed);
      dio.close();
    });
  });

  group('events', () {
    test('retries and the final failure are reported', () async {
      final adapter = _ScriptedAdapter(const [_Step(503)]);
      final dio = _dio(adapter);
      final events = <ResilienceEvent>[];
      ResiliencePipeline.builder()
          .retry(maxAttempts: 3, backoff: _noBackoff)
          .onEvent(events.add)
          .build()
          .attachTo(dio);

      await dio.get<dynamic>('/items').catchError(
            (Object _) => Response<dynamic>(requestOptions: RequestOptions()),
          );
      final replays = events.whereType<ReplayEvent>().toList();
      expect(replays.map((e) => e.strategy), ['retry', 'retry']);
      expect(replays.map((e) => e.attemptNumber), [2, 3]);
      expect(
        events.whereType<GaveUpEvent>().single.error,
        isA<AllAttemptsExhaustedException>(),
      );
    });
  });

  group('parseHttpDate', () {
    test('reads the three HTTP-date forms', () {
      final expected = DateTime.utc(1994, 11, 6, 8, 49, 37);
      expect(parseHttpDate('Sun, 06 Nov 1994 08:49:37 GMT'), expected);
      expect(parseHttpDate('Sunday, 06-Nov-94 08:49:37 GMT'), expected);
      expect(parseHttpDate('Sun Nov  6 08:49:37 1994'), expected);
      expect(parseHttpDate('soon'), isNull);
    });
  });
}
