import 'dart:async';
import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';
import 'package:test/test.dart';
import 'support/fn_adapter.dart';

class HeaderCopyInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions o, RequestInterceptorHandler h) =>
      h.next(o.copyWith(headers: {...o.headers, 'x-trace': 'y'}));
}

class SlowReadStorage implements TokenStorage {
  SlowReadStorage(this._pair);
  TokenPair? _pair;
  @override
  Future<TokenPair?> read() async {
    final snap = _pair; // served before any write that lands meanwhile
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return snap;
  }

  @override
  Future<void> write(TokenPair p) async => _pair = p;
  @override
  Future<void> clear() async => _pair = null;
}

class CopyingInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions o, RequestInterceptorHandler h) =>
      h.next(o.copyWith());
}

class Behind extends Interceptor {
  int errors = 0;
  @override
  void onError(DioException e, ErrorInterceptorHandler h) {
    errors++;
    h.next(e);
  }
}

/// Regression tests for bugs a review of 0.3.0 found and reproduced.
void main() {
  test('T1 caller-cancelled half-open probe gives its slot back', () async {
    var mode = 'fail';
    final adapter = FnAdapter((o, c) async {
      if (mode == 'fail') return body(503);
      if (mode == 'hang') return hang(c);
      return body(200, {'ok': true});
    });
    final dio = mkDio(adapter);
    ResiliencePipeline.builder()
        .circuitBreaker(
          failureThreshold: 1,
          cooldown: Duration.zero,
          halfOpenProbes: 1,
        )
        .build()
        .attachTo(dio);
    await expectLater(dio.get<dynamic>('/x'), throwsA(isA<DioException>()));
    mode = 'hang';
    final token = CancelToken();
    final probe = dio.get<dynamic>('/x', cancelToken: token);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel('user left');
    await expectLater(
      probe,
      throwsA(
        isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel),
      ),
    );
    mode = 'ok';
    final r = await dio
        .get<dynamic>('/x')
        .then<Object>((r) => r.statusCode!, onError: (Object e) => e);
    expect(r, 200, reason: 'got $r');
  });

  test('T2 half-open probe answered by a failed challenge gives its slot back',
      () async {
    var mode = 'fail';
    final adapter = FnAdapter((o, c) async {
      if (mode == 'fail') return body(503);
      if (mode == 'challenge') return body(428);
      return body(200);
    });
    final dio = mkDio(adapter);
    ResiliencePipeline.builder()
        .circuitBreaker(failureThreshold: 1, cooldown: Duration.zero)
        .challenge<String>(
          ChallengeConfig<String>(
            matcher: (s) =>
                s is ChallengeOnResponse && s.response.statusCode == 428,
            solver: (_, __) async => throw StateError('user dismissed captcha'),
            applier: (r, t) => r.headers['x-captcha'] = t,
          ),
        )
        .build()
        .attachTo(dio);
    await expectLater(dio.get<dynamic>('/x'), throwsA(isA<DioException>()));
    mode = 'challenge';
    await expectLater(
      dio.get<dynamic>('/x'),
      throwsA(isA<ChallengeFailedException>()),
    );
    mode = 'ok';
    final r = await dio
        .get<dynamic>('/x')
        .then<Object>((r) => r.statusCode!, onError: (Object e) => e);
    expect(r, 200, reason: 'got $r');
  });

  test('T3 a replay handed on as a copy keeps its retry budget', () async {
    final adapter = FnAdapter((o, c) async => body(503));
    var n = 0;
    final capped = FnAdapter((o, c) async => ++n > 20 ? body(200) : body(503));
    final dio = mkDio(capped);
    dio.interceptors.add(HeaderCopyInterceptor());
    ResiliencePipeline.builder()
        .retry(maxAttempts: 3, backoff: const Backoff.constant(Duration.zero))
        .build()
        .attachTo(dio);
    final r = await dio.get<dynamic>('/x').then<Object>(
          (r) => 'status ${r.statusCode}',
          onError: (Object e) => e.runtimeType,
        );
    expect(capped.calls, 3, reason: 'calls=${capped.calls} result=$r');
    adapter.close();
  });

  test('T4 a stale storage read reuses the finished refresh', () async {
    final storage =
        SlowReadStorage(const TokenPair(access: 't1', refresh: 'r1'));
    var refreshes = 0;
    var latestRefresh = 'r1';
    final adapter = FnAdapter((o, c) async {
      final auth = o.headers['Authorization'];
      if (auth == 'Bearer t1') {
        if (o.path.endsWith('/b')) {
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
        return body(401);
      }
      return body(200);
    });
    final dio = mkDio(adapter);
    final failures = <AuthRejection>[];
    ResiliencePipeline.builder()
        .auth(
          tokenStorage: storage,
          onAuthFailure: failures.add,
          refreshToken: (cur) async {
            refreshes++;
            await Future<void>.delayed(const Duration(milliseconds: 50));
            if (cur?.refresh != latestRefresh) {
              throw StateError('refresh token reused (rotated)');
            }
            final n = refreshes + 1;
            latestRefresh = 'r$n';
            return TokenPair(access: 't$n', refresh: 'r$n');
          },
        )
        .build()
        .attachTo(dio);
    final a = dio.get<dynamic>('/a').then<Object>(
          (r) => r.statusCode!,
          onError: (Object e) => e.runtimeType,
        );
    final b = dio.get<dynamic>('/b').then<Object>(
          (r) => r.statusCode!,
          onError: (Object e) => e.runtimeType,
        );
    final res = await Future.wait([a, b]);
    final stored = await storage.read();
    expect(
      refreshes,
      1,
      reason:
          'results=$res refreshes=$refreshes stored=$stored failures=${failures.length}',
    );
    expect(res, [200, 200]);
  });

  test(
      'T5 cancel during preemptive refresh: abandoned onRequest takes the half-open probe',
      () async {
    var mode = 'fail';
    final adapter =
        FnAdapter((o, c) async => mode == 'fail' ? body(503) : body(200));
    final dio = mkDio(adapter);
    final storage = MemoryTokenStorage();
    await storage.write(
      TokenPair(
        access: 'old',
        refresh: 'r',
        accessExpiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      ),
    );
    ResiliencePipeline.builder()
        .auth(
          tokenStorage: storage,
          refreshToken: (cur) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return TokenPair(
              access: 'new',
              refresh: 'r2',
              accessExpiresAt: DateTime.now().add(const Duration(hours: 1)),
            );
          },
        )
        .circuitBreaker(failureThreshold: 1, cooldown: Duration.zero)
        .build()
        .attachTo(dio);
    await expectLater(
      dio.get<dynamic>('/x', options: Options().noAuth()),
      throwsA(isA<DioException>()),
    );
    mode = 'ok';
    final token = CancelToken();
    final f = dio.get<dynamic>('/x', cancelToken: token);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    token.cancel();
    await expectLater(f, throwsA(isA<DioException>()));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final r = await dio
        .get<dynamic>('/x', options: Options().noAuth())
        .then<Object>((r) => r.statusCode!, onError: (Object e) => e);
    expect(r, 200, reason: 'got $r, adapter calls=${adapter.calls}');
  });

  test('T3b a copied replay still ends at the retry budget', () async {
    final adapter = FnAdapter((o, c) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return body(503);
    });
    final dio = mkDio(adapter);
    dio.interceptors.add(CopyingInterceptor());
    ResiliencePipeline.builder()
        .retry(maxAttempts: 3, backoff: const Backoff.constant(Duration.zero))
        .timeout(total: const Duration(milliseconds: 300))
        .build()
        .attachTo(dio);
    final behind = Behind();
    dio.interceptors.add(behind);
    final r = await dio
        .get<dynamic>('/x')
        .timeout(const Duration(seconds: 3))
        .then<Object>(
          (r) => r.statusCode!,
          onError: (Object e) => e.runtimeType,
        );
    expect(r, AllAttemptsExhaustedException);
    expect(adapter.calls, 3);
    expect(behind.errors, 1);
  });

  test('T6 attempts cut by the deadline trip the circuit', () async {
    final adapter = FnAdapter((o, c) => hang(c));
    final dio = mkDio(adapter);
    ResiliencePipeline.builder()
        .circuitBreaker(failureThreshold: 2)
        .timeout(total: const Duration(milliseconds: 50))
        .build()
        .attachTo(dio);
    final results = <Object>[];
    for (var i = 0; i < 4; i++) {
      results.add(
        await dio.get<dynamic>('/x').then<Object>(
              (r) => r.statusCode!,
              onError: (Object e) => e.runtimeType,
            ),
      );
    }
    expect(results.last, CircuitOpenException);
  });

  test('T7 a replay after sign-out drops the old token', () async {
    var n = 0;
    final adapter = FnAdapter((o, c) async => ++n == 1 ? body(503) : body(200));
    final dio = mkDio(adapter);
    final storage = MemoryTokenStorage();
    await storage.write(const TokenPair(access: 'secret-old'));
    final p = ResiliencePipeline.builder()
        .auth(tokenStorage: storage, refreshToken: (c) async => null)
        .retry(backoff: const Backoff.constant(Duration(milliseconds: 100)))
        .build()
      ..attachTo(dio);
    final f = dio.get<dynamic>('/me');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await p.signOut();
    await f;
    expect(adapter.requests[1].headers['Authorization'], isNull);
  });
}
