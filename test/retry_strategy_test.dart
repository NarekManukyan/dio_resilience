import 'package:dio/dio.dart';
import 'package:dio_resilience/src/conditions.dart';
import 'package:dio_resilience/src/exceptions.dart';
import 'package:dio_resilience/src/overrides.dart';
import 'package:dio_resilience/src/pipeline_context.dart';
import 'package:dio_resilience/src/strategy.dart';
import 'package:dio_resilience/src/strategies/retry_strategy.dart';
import 'package:test/test.dart';

void main() {
  group('RetryStrategy', () {
    late RetryStrategy strategy;
    late PipelineContext ctx;
    late RequestOptions request;

    setUp(() {
      strategy = RetryStrategy();
      request = RequestOptions(path: 'https://example.com/test');
      ctx = PipelineContext(request);
    });

    test('Default policy retries on 503 with backoff', () async {
      // First attempt fails with 503.
      ctx.attemptNumber = 1;
      final response = Response<dynamic>(
        statusCode: 503,
        requestOptions: request,
      );
      final error = DioException(
        requestOptions: request,
        response: response,
        type: DioExceptionType.badResponse,
        message: 'Service Unavailable',
      );

      final decision = await strategy.onError(ctx, error);

      // Verify decision is a replay with a delay.
      var hasDelay = false;
      if (decision != null) {
        final result = switch (decision) {
          ReplayDecision(delay: final d) => d,
          _ => null,
        };
        hasDelay = result != null && result.inMilliseconds > 0;
      }
      expect(hasDelay, isTrue);
    });

    test('Default policy does not retry on 400', () async {
      ctx.attemptNumber = 1;
      final response = Response<dynamic>(
        statusCode: 400,
        requestOptions: request,
      );
      final error = DioException(
        requestOptions: request,
        response: response,
        type: DioExceptionType.badResponse,
        message: 'Bad Request',
      );

      final decision = await strategy.onError(ctx, error);

      expect(decision, isNull);
    });

    test('Retries exhaust and throw AllAttemptsExhaustedException', () async {
      // Max attempts is 3 by default. On attempt 3, it should fail.
      ctx.attemptNumber = 3;
      final response = Response<dynamic>(
        statusCode: 503,
        requestOptions: request,
      );
      final error = DioException(
        requestOptions: request,
        response: response,
        type: DioExceptionType.badResponse,
        message: 'Service Unavailable',
      );

      final decision = await strategy.onError(ctx, error);

      // Verify decision is a fail with AllAttemptsExhaustedException.
      var isExhausted = false;
      if (decision != null) {
        final failError = switch (decision) {
          FailDecision(error: final e) => e,
          _ => null,
        };
        isExhausted = failError is AllAttemptsExhaustedException;
      }
      expect(isExhausted, isTrue);
    });

    test('RetryOverride.disabled disables retry entirely', () async {
      ctx.attemptNumber = 1;
      request = request.copyWith(
        extra: {
          '__dio_resilience_overrides__': const ResilienceOverrides(
            retry: RetryOverride.disabled,
          ),
        },
      );
      ctx = PipelineContext(request);

      final response = Response<dynamic>(
        statusCode: 503,
        requestOptions: request,
      );
      final error = DioException(
        requestOptions: request,
        response: response,
        type: DioExceptionType.badResponse,
        message: 'Service Unavailable',
      );

      final decision = await strategy.onError(ctx, error);

      expect(decision, isNull);
    });

    test('RetryOverride.exceptWhen blocks specified conditions', () async {
      ctx.attemptNumber = 1;
      request = request.copyWith(
        extra: {
          '__dio_resilience_overrides__': const ResilienceOverrides(
            retry: RetryOverride.exceptWhen(
              [RetryCondition.status(503)],
            ),
          ),
        },
      );
      ctx = PipelineContext(request);

      final response = Response<dynamic>(
        statusCode: 503,
        requestOptions: request,
      );
      final error = DioException(
        requestOptions: request,
        response: response,
        type: DioExceptionType.badResponse,
        message: 'Service Unavailable',
      );

      final decision = await strategy.onError(ctx, error);

      expect(decision, isNull);
    });

    test('RetryOverride.onlyWhen changes retry predicate', () async {
      ctx.attemptNumber = 1;
      request = request.copyWith(
        extra: {
          '__dio_resilience_overrides__': const ResilienceOverrides(
            retry: RetryOverride.onlyWhen(
              [RetryCondition.status(504)],
            ),
          ),
        },
      );
      ctx = PipelineContext(request);

      // 503 should NOT be retried under onlyWhen([504]).
      final response503 = Response<dynamic>(
        statusCode: 503,
        requestOptions: request,
      );
      final error503 = DioException(
        requestOptions: request,
        response: response503,
        type: DioExceptionType.badResponse,
        message: 'Service Unavailable',
      );

      final decision503 = await strategy.onError(ctx, error503);
      expect(decision503, isNull);

      // But 504 should be retried.
      ctx.attemptNumber = 1; // Reset.
      final response504 = Response<dynamic>(
        statusCode: 504,
        requestOptions: request,
      );
      final error504 = DioException(
        requestOptions: request,
        response: response504,
        type: DioExceptionType.badResponse,
        message: 'Gateway Timeout',
      );

      final decision504 = await strategy.onError(ctx, error504);
      var hasDelay = false;
      if (decision504 != null) {
        final result = switch (decision504) {
          ReplayDecision(delay: final d) => d,
          _ => null,
        };
        hasDelay = result != null && result.inMilliseconds > 0;
      }
      expect(hasDelay, isTrue);
    });

    test('Retry-After header (numeric seconds) overrides computed backoff',
        () async {
      ctx.attemptNumber = 1;
      final response = Response<dynamic>(
        statusCode: 429,
        requestOptions: request,
        headers: Headers.fromMap({
          'retry-after': ['60']
        }),
      );
      final error = DioException(
        requestOptions: request,
        response: response,
        type: DioExceptionType.badResponse,
        message: 'Too Many Requests',
      );

      final decision =
          await RetryStrategy(maxRetryAfter: null).onError(ctx, error);

      var delayInSeconds = 0;
      if (decision != null) {
        final delay = switch (decision) {
          ReplayDecision(delay: final d) => d,
          _ => null,
        };
        if (delay != null) {
          delayInSeconds = delay.inSeconds;
        }
      }
      expect(delayInSeconds, greaterThanOrEqualTo(60));
    });

    test('Retry-After longer than maxRetryAfter ends the request', () async {
      final response = Response<dynamic>(
        statusCode: 503,
        requestOptions: request,
        headers: Headers.fromMap({
          'retry-after': ['600']
        }),
      );
      final error = DioException(
        requestOptions: request,
        response: response,
        type: DioExceptionType.badResponse,
      );

      expect(await strategy.onError(ctx, error), isNull);
    });

    test('Retry-After as an HTTP-date waits until that date', () async {
      final now = DateTime.utc(2026, 5, 5, 12);
      final dated = RetryStrategy(now: () => now);
      final response = Response<dynamic>(
        statusCode: 503,
        requestOptions: request,
        headers: Headers.fromMap({
          'retry-after': ['Tue, 05 May 2026 12:00:20 GMT'],
        }),
      );
      final error = DioException(
        requestOptions: request,
        response: response,
        type: DioExceptionType.badResponse,
      );

      final decision = await dated.onError(ctx, error);
      expect(
        decision,
        isA<ReplayDecision>().having(
          (d) => d.delay,
          'delay',
          const Duration(seconds: 20),
        ),
      );
    });

    test('does not retry a POST by default', () async {
      final post =
          RequestOptions(path: 'https://example.com/test', method: 'POST');
      final postCtx = PipelineContext(post);
      final error = DioException(
        requestOptions: post,
        response: Response<dynamic>(statusCode: 503, requestOptions: post),
        type: DioExceptionType.badResponse,
      );

      expect(await strategy.onError(postCtx, error), isNull);
    });
  });
}
