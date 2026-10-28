import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';
import 'package:dio_resilience_example/fake/fake_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retries a 503 twice then succeeds on the third attempt', () async {
    var attempts = 0;
    final dio = Dio();
    ResiliencePipeline.builder()
        .retry(
          maxAttempts: 3,
          backoff: const Backoff.constant(Duration(milliseconds: 1)),
        )
        .build()
        .attachTo(dio);
    dio.httpClientAdapter = FakeHttpClientAdapter((call) async {
      attempts++;
      if (attempts < 3) {
        return const FakeResult(503, data: {'error': 'down'});
      }
      return const FakeResult(200, data: {'status': 'ok'});
    });

    final response = await dio.get<dynamic>('/flaky');

    expect(response.statusCode, 200);
    expect(attempts, 3);
  });

  test('exhausts retries and keeps the last failure type', () async {
    final dio = Dio();
    ResiliencePipeline.builder()
        .retry(
          maxAttempts: 2,
          backoff: const Backoff.constant(Duration(milliseconds: 1)),
        )
        .build()
        .attachTo(dio);
    dio.httpClientAdapter = FakeHttpClientAdapter(
      (call) async => const FakeResult(503, data: {'error': 'down'}),
    );

    await expectLater(
      dio.get<dynamic>('/always-down'),
      throwsA(isA<AllAttemptsExhaustedException>()),
    );
  });

  test('a cancelled attempt ends immediately instead of waiting out the latency', () async {
    final dio = Dio();
    ResiliencePipeline.builder().build().attachTo(dio);
    dio.httpClientAdapter = FakeHttpClientAdapter(
      (call) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return const FakeResult(200, data: {'status': 'ok'});
      },
    );

    final token = CancelToken();
    final future = dio.get<dynamic>('/slow', cancelToken: token);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel('caller cancelled');

    await expectLater(
      future,
      throwsA(isA<DioException>().having((e) => e.type, 'type', DioExceptionType.cancel)),
    );
  });
}
