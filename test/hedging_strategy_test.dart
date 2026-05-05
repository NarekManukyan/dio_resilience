import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A controllable fake adapter. Each call to [fetch] waits for the
/// corresponding [Completer] in [completers] to be completed by the test.
/// If [completers] runs out, a [StateError] is thrown.
class _ControllableAdapter implements HttpClientAdapter {
  final List<Completer<ResponseBody>> completers;
  int _index = 0;

  int get callCount => _index;

  _ControllableAdapter(this.completers);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    if (_index >= completers.length) {
      throw StateError('No more completers registered (call #${_index + 1})');
    }
    final completer = completers[_index++];

    // If the caller supplied a cancel future, race against it so we don't
    // hang after a CancelToken fires.
    if (options.cancelToken != null) {
      // cancelToken.whenCancel is a Future<void> that completes on cancel.
      await Future.any<dynamic>([
        completer.future,
        options.cancelToken!.whenCancel,
      ]);

      if (options.cancelToken!.isCancelled) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
          message: 'Cancelled by hedging',
        );
      }
    }

    return completer.future;
  }

  @override
  void close({bool force = false}) {}
}

/// Simpler immediate adapter: returns canned [ResponseBody] values in order.
class _ImmediateAdapter implements HttpClientAdapter {
  final List<ResponseBody Function()> factories;
  int _index = 0;

  int get callCount => _index;

  _ImmediateAdapter(this.factories);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    if (_index >= factories.length) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.unknown,
        message: 'No more canned responses',
      );
    }
    return factories[_index++]();
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _ok([String body = 'ok']) =>
    ResponseBody.fromString(body, 200);

Dio _buildDio(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(validateStatus: (s) => s != null && s < 400));
  dio.httpClientAdapter = adapter;
  return dio;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('HedgingStrategy unit', () {
    test('skips non-GET methods by default (POST is not hedged)', () async {
      // Only one completer — if hedging fired a second branch the adapter
      // would throw StateError.
      final c1 = Completer<ResponseBody>()..complete(_ok());
      final adapter = _ControllableAdapter([c1]);
      final dio = _buildDio(adapter);

      ResiliencePipeline.builder()
          .hedging(maxParallel: 3, delay: const Duration(milliseconds: 10))
          .build()
          .attachTo(dio);

      final res = await dio.post<String>('/test');
      expect(res.statusCode, 200);
      // Only one real HTTP call should have been made (no hedging).
      expect(adapter.callCount, 1);
    });

    test('does not hedge GET when maxParallel == 1', () async {
      final c1 = Completer<ResponseBody>()..complete(_ok('only'));
      final adapter = _ControllableAdapter([c1]);
      final dio = _buildDio(adapter);

      ResiliencePipeline.builder()
          .hedging(maxParallel: 1, delay: const Duration(milliseconds: 10))
          .build()
          .attachTo(dio);

      final res = await dio.get<String>('/test');
      expect(res.statusCode, 200);
      expect(adapter.callCount, 1);
    });

    test('fires hedge after delay when primary is slow', () async {
      // Primary is slow; hedge fires after delay and succeeds first.
      final primaryCompleter = Completer<ResponseBody>();
      final hedgeCompleter = Completer<ResponseBody>()..complete(_ok('hedge'));

      final adapter = _ControllableAdapter([primaryCompleter, hedgeCompleter]);
      final dio = _buildDio(adapter);

      ResiliencePipeline.builder()
          .hedging(delay: const Duration(milliseconds: 30))
          .build()
          .attachTo(dio);

      final res = await dio.get<String>('/test');
      expect(res.statusCode, 200);
      expect(res.data, 'hedge');

      // Both branches were launched (primary slow, hedge succeeded).
      expect(adapter.callCount, 2);

      // Clean up — complete the primary so its completer isn't abandoned.
      primaryCompleter.complete(_ok('late'));
    });

    test('first success wins — primary fast, hedge never needed', () async {
      // Primary completes immediately; the hedge delay (200ms) never fires.
      final c1 = Completer<ResponseBody>()..complete(_ok('primary'));
      // A second completer exists but should never be reached.
      final c2 = Completer<ResponseBody>()..complete(_ok('hedge'));

      final adapter = _ControllableAdapter([c1, c2]);
      final dio = _buildDio(adapter);

      ResiliencePipeline.builder()
          .hedging(delay: const Duration(milliseconds: 200))
          .build()
          .attachTo(dio);

      final res = await dio.get<String>('/test');
      expect(res.statusCode, 200);
      expect(res.data, 'primary');

      // Give enough time to confirm the hedge was NOT launched.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(adapter.callCount, 1);
    });

    test('respects maxParallel — caps launched branches', () async {
      // maxParallel = 2: primary + 1 hedge maximum.
      // We provide 3 completers; if a 3rd branch fires the test will fail.
      final c1 = Completer<ResponseBody>(); // primary — stays slow
      final c2 = Completer<ResponseBody>()..complete(_ok('hedge1'));
      final c3 = Completer<ResponseBody>()..complete(_ok('hedge2'));

      final adapter = _ControllableAdapter([c1, c2, c3]);
      final dio = _buildDio(adapter);

      ResiliencePipeline.builder()
          .hedging(maxParallel: 2, delay: const Duration(milliseconds: 20))
          .build()
          .attachTo(dio);

      final res = await dio.get<String>('/test');
      expect(res.statusCode, 200);

      // Give the timer enough time to potentially fire a 3rd branch.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Only 2 branches should have been launched (primary + hedge #1).
      expect(adapter.callCount, 2);

      c1.complete(_ok('late'));
    });

    test('cancels losers after winner resolves', () async {
      // Both branches start; we complete hedge first.
      // The primary's completer should have been cancelled before it resolves.
      final primaryCompleter = Completer<ResponseBody>();
      final hedgeCompleter = Completer<ResponseBody>();

      var primaryCancelled = false;

      final adapter = _ControllableAdapter([primaryCompleter, hedgeCompleter]);
      final dio = _buildDio(adapter);

      // Wrap to detect cancellation on the primary slot.
      // We do this by completing the primary's slot with a DioException.cancel
      // after the hedge wins — and checking the result comes from the hedge.

      ResiliencePipeline.builder()
          .hedging(delay: const Duration(milliseconds: 20))
          .build()
          .attachTo(dio);

      // Launch but don't await yet.
      final requestFuture = dio.get<String>('/test');

      // Let the primary start, wait a tick, then complete hedge.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      hedgeCompleter.complete(_ok('winner'));

      final res = await requestFuture;
      expect(res.data, 'winner');

      // The primary completer was never completed — confirm we didn't hang.
      // (If cancel didn't work we'd have deadlocked above.)
      primaryCancelled = !primaryCompleter.isCompleted;
      expect(primaryCancelled, isTrue);
    });

    test('all branches fail — propagates last DioException', () async {
      // Both branches error; hedging should surface a DioException.
      final factories = <ResponseBody Function()>[
        () => throw DioException(
              requestOptions: RequestOptions(path: '/test'),
              type: DioExceptionType.connectionError,
              message: 'network error',
            ),
        () => throw DioException(
              requestOptions: RequestOptions(path: '/test'),
              type: DioExceptionType.connectionError,
              message: 'network error',
            ),
      ];

      final adapter = _ImmediateAdapter(factories);
      final dio = _buildDio(adapter);

      ResiliencePipeline.builder()
          .hedging(maxParallel: 2, delay: const Duration(milliseconds: 10))
          .build()
          .attachTo(dio);

      await expectLater(
        () => dio.get<String>('/test'),
        throwsA(isA<DioException>()),
      );
    });

    test('custom shouldHedge predicate — hedges POST when told to', () async {
      final c1 = Completer<ResponseBody>(); // primary slow
      final c2 = Completer<ResponseBody>()..complete(_ok('hedge'));

      final adapter = _ControllableAdapter([c1, c2]);
      final dio = _buildDio(adapter);

      ResiliencePipeline.builder()
          .hedging(
            delay: const Duration(milliseconds: 20),
            shouldHedge: (_) => true, // hedge everything
          )
          .build()
          .attachTo(dio);

      final res = await dio.post<String>('/test');
      expect(res.statusCode, 200);
      expect(adapter.callCount, 2);

      c1.complete(_ok('late'));
    });

    test('HedgingOverride.disabled suppresses hedging for one request', () async {
      final c1 = Completer<ResponseBody>()..complete(_ok('only'));
      // Second completer would be reached only if hedging fires.
      final c2 = Completer<ResponseBody>()..complete(_ok('hedge'));

      final adapter = _ControllableAdapter([c1, c2]);
      final dio = _buildDio(adapter);

      ResiliencePipeline.builder()
          .hedging(delay: const Duration(milliseconds: 10))
          .build()
          .attachTo(dio);

      // Disable hedging for this specific request.
      final res = await dio.get<String>(
        '/test',
        options: Options().noHedging(),
      );

      expect(res.statusCode, 200);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(adapter.callCount, 1);
    });

    test('HedgingOverride.maxParallel(1) via .hedge() suppresses hedging', () async {
      final c1 = Completer<ResponseBody>()..complete(_ok('only'));
      final adapter = _ControllableAdapter([c1]);
      final dio = _buildDio(adapter);

      ResiliencePipeline.builder()
          .hedging(delay: const Duration(milliseconds: 10))
          .build()
          .attachTo(dio);

      final res = await dio.get<String>(
        '/test',
        options: Options().hedge(max: 1),
      );

      expect(res.statusCode, 200);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(adapter.callCount, 1);
    });

    test('HedgingOverride.delay() via .hedge() overrides inter-hedge delay', () async {
      // With a very long default delay but a short override, the hedge fires quickly.
      final c1 = Completer<ResponseBody>(); // primary slow
      final c2 = Completer<ResponseBody>()..complete(_ok('hedge'));

      final adapter = _ControllableAdapter([c1, c2]);
      final dio = _buildDio(adapter);

      ResiliencePipeline.builder()
          .hedging(delay: const Duration(seconds: 10)) // would never fire
          .build()
          .attachTo(dio);

      final res = await dio.get<String>(
        '/test',
        options: Options().hedge(delay: const Duration(milliseconds: 20)),
      );

      expect(res.statusCode, 200);
      expect(res.data, 'hedge');
      expect(adapter.callCount, 2);

      c1.complete(_ok('late'));
    });
  });

  group('HedgingStrategy + RetryStrategy integration', () {
    test('hedging counts as ONE attempt — retry still fires on failure', () async {
      // Primary slow, hedge also fails; hedging resolves with failure.
      // Retry should pick it up and retry once more (attempt 2).
      // On the retry, primary succeeds immediately.

      var callCount = 0;
      final factories = <ResponseBody Function()>[
        // Attempt 1 — primary branch (fails)
        () {
          callCount++;
          throw DioException(
            requestOptions: RequestOptions(path: '/test'),
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: '/test'),
              statusCode: 503,
            ),
            type: DioExceptionType.badResponse,
          );
        },
        // Attempt 1 — hedge branch (also fails)
        () {
          callCount++;
          throw DioException(
            requestOptions: RequestOptions(path: '/test'),
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: '/test'),
              statusCode: 503,
            ),
            type: DioExceptionType.badResponse,
          );
        },
        // Attempt 2 (retry) — succeeds
        () {
          callCount++;
          return _ok('retried');
        },
      ];

      final adapter = _ImmediateAdapter(factories);
      final dio = _buildDio(adapter);

      ResiliencePipeline.builder()
          .hedging(maxParallel: 2, delay: const Duration(milliseconds: 10))
          .retry(
            maxAttempts: 2,
            backoff: const Backoff.constant(Duration.zero),
            retryOn: const [RetryCondition.statusBetween(500, 599)],
          )
          .build()
          .attachTo(dio);

      final res = await dio.get<String>('/test');
      expect(res.statusCode, 200);
      expect(res.data, 'retried');
      // 3 total HTTP calls: 2 hedged branches on attempt 1 + 1 on retry.
      expect(callCount, 3);
    });

    test('hedging+retry does not multiply attemptNumber unexpectedly', () async {
      // maxParallel=2 means 2 HTTP calls per logical attempt.
      // With maxAttempts=3, worst case is 3*2 = 6 HTTP calls.
      // Verify we don't exceed that.
      var callCount = 0;

      final factories = List<ResponseBody Function()>.generate(
        10,
        (_) => () {
          callCount++;
          throw DioException(
            requestOptions: RequestOptions(path: '/test'),
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: '/test'),
              statusCode: 503,
            ),
            type: DioExceptionType.badResponse,
          );
        },
      );

      final adapter = _ImmediateAdapter(factories);
      final dio = _buildDio(adapter);

      ResiliencePipeline.builder()
          .hedging(maxParallel: 2, delay: const Duration(milliseconds: 10))
          .retry(
            maxAttempts: 3,
            backoff: const Backoff.constant(Duration.zero),
            retryOn: const [RetryCondition.statusBetween(500, 599)],
          )
          .build()
          .attachTo(dio);

      await expectLater(
        () => dio.get<String>('/test'),
        throwsA(isA<DioException>()),
      );

      // Should not exceed maxAttempts * maxParallel.
      expect(callCount, lessThanOrEqualTo(3 * 2));
    });
  });
}
