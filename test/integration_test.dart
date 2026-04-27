import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';
import 'package:test/test.dart';

void main() {
  group('ResiliencePipeline Integration Tests', () {
    test('end-to-end retry: 503 twice, third succeeds', () async {
      final responses = [
        _createErrorResponse(503),
        _createErrorResponse(503),
        _createSuccessResponse('OK'),
      ];

      final adapter = FakeDioAdapter(responses);
      final dio = Dio()..httpClientAdapter = adapter;

      final pipeline = ResiliencePipeline.builder()
          .retry(maxAttempts: 3)
          .build()
          ..attachTo(dio);

      final response = await dio.get<String>('/test');

      expect(response.statusCode, 200);
      expect(response.data, 'OK');
      expect(adapter.callCount, 3);

      pipeline.dispose();
    });

    test('end-to-end auth refresh: 401 → refresh → replay succeeds', () async {
      final tokenStorage = MemoryTokenStorage();
      await tokenStorage.write(
        const TokenPair(access: 'old_token', refresh: 'refresh_token'),
      );

      var refreshCalls = 0;
      final responses = [
        _createErrorResponse(401),
        _createSuccessResponse('OK'),
      ];

      final adapter = FakeDioAdapter(responses);
      final dio = Dio()..httpClientAdapter = adapter;

      final pipeline = ResiliencePipeline.builder()
          .auth(
            tokenStorage: tokenStorage,
            refreshToken: (current) async {
              refreshCalls++;
              return const TokenPair(
                access: 'new_token',
                refresh: 'refresh_token',
              );
            },
          )
          .build()
          ..attachTo(dio);

      final response = await dio.get<String>('/test');

      expect(response.statusCode, 200);
      expect(response.data, 'OK');
      expect(refreshCalls, 1);

      pipeline.dispose();
    });

    test('end-to-end auth refresh fails → RefreshFailedException', () async {
      final tokenStorage = MemoryTokenStorage();
      await tokenStorage.write(
        const TokenPair(access: 'old_token', refresh: 'refresh_token'),
      );

      final responses = [
        _createErrorResponse(401),
      ];

      final adapter = FakeDioAdapter(responses);
      final dio = Dio()..httpClientAdapter = adapter;

      final pipeline = ResiliencePipeline.builder()
          .auth(
            tokenStorage: tokenStorage,
            refreshToken: (current) async => null, // Refresh fails
          )
          .build()
          ..attachTo(dio);

      expect(
        () => dio.get<String>('/test'),
        throwsA(isA<RefreshFailedException>()),
      );

      pipeline.dispose();
    });

    test('end-to-end timeout: total budget exceeded → PipelineTimeoutException',
        () async {
      final responses = [
        _createErrorResponse(503),
        _createErrorResponse(503),
      ];

      final adapter = FakeDioAdapter(responses, delayMs: 100);
      final dio = Dio()..httpClientAdapter = adapter;

      final pipeline = ResiliencePipeline.builder()
          .retry(maxAttempts: 3, backoff: const Backoff.constant(Duration.zero))
          .timeout(total: const Duration(milliseconds: 150))
          .build()
          ..attachTo(dio);

      expect(
        () => dio.get<String>('/test'),
        throwsA(isA<PipelineTimeoutException>()),
      );

      pipeline.dispose();
    });
  });
}

/// Creates a fake success response.
Response<String> _createSuccessResponse(String data) {
  return Response<String>(
    data: data,
    statusCode: 200,
    requestOptions: RequestOptions(path: '/test'),
  );
}

/// Creates a fake error response.
Response<String> _createErrorResponse(int statusCode) {
  return Response<String>(
    statusCode: statusCode,
    requestOptions: RequestOptions(path: '/test'),
  );
}

/// Simple fake adapter that returns canned responses.
class FakeDioAdapter implements HttpClientAdapter {
  final List<Response<dynamic>> responses;
  final int delayMs;
  int _index = 0;

  int get callCount => _index;

  FakeDioAdapter(this.responses, {this.delayMs = 0});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    if (delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }

    if (_index >= responses.length) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.unknown,
        message: 'No more canned responses',
      );
    }

    final response = responses[_index++];

    if (response.statusCode != null && response.statusCode! >= 400) {
      throw DioException(
        requestOptions: options,
        response: response,
        type: DioExceptionType.unknown,
      );
    }

    final data = response.data ?? '';
    return ResponseBody.fromString(
      data.toString(),
      response.statusCode ?? 200,
      headers: response.headers.map,
    );
  }

  @override
  void close({bool force = false}) {}
}
