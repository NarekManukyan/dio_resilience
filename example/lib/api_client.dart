// ignore_for_file: avoid_print

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';

/// Singleton API client with configured resilience pipeline.
final apiClient = _ApiClient();

class _ApiClient {
  late final Dio _dio;
  int _flakyAttempts = 0;

  _ApiClient() {
    _dio = Dio();

    // Configure the resilience pipeline
    ResiliencePipeline.builder()
        .auth(
          refreshToken: _refreshToken,
          onRefreshFailed: () => print('Auth refresh failed'),
        )
        .retry(maxAttempts: 3)
        .timeout(total: const Duration(seconds: 10))
        .build()
        .attachTo(_dio);

    // Replace with fake adapter for demo
    _dio.httpClientAdapter = _FakeHttpClientAdapter(this);
  }

  /// Mock token refresh endpoint.
  ///
  /// In a real app you would use a SEPARATE [Dio] instance here so the
  /// refresh request itself doesn't recurse through this pipeline.
  Future<TokenPair?> _refreshToken(TokenPair? current) async {
    print('Refreshing token...');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return const TokenPair(
      access: 'refreshed_access_token',
      refresh: 'new_refresh_token',
    );
  }

  /// GET /flaky — returns 503 twice, then 200.
  Future<void> testFlaky() async {
    _flakyAttempts = 0;
    final response = await _dio.get<String>('http://localhost/flaky');
    print('Flaky response: ${response.statusCode}');
  }

  /// GET /protected — requires Bearer token, demonstrates auth refresh.
  Future<void> testAuthRefresh() async {
    final response =
        await _dio.get<String>('http://localhost/protected');
    print('Protected response: ${response.data}');
  }

  /// GET /slow — delays 12s, exceeds 10s timeout.
  Future<void> testTimeout() async {
    try {
      await _dio.get<String>('http://localhost/slow');
    } catch (e) {
      print('Timeout error caught: $e');
      rethrow;
    }
  }

  /// POST /charge — returns 409 duplicate, no retry.
  Future<void> testDontRetry() async {
    try {
      await _dio
          .post<String>(
            'http://localhost/charge',
            options: Options().dontRetryOn({409}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      print('Duplicate charge (no retry): $e');
      rethrow;
    }
  }

  Stream<AuthState> get authStateStream => _dio.interceptors
      .whereType<ResiliencePipeline>()
      .first
      .authStateStream;

  void resetFlakyCounter() => _flakyAttempts = 0;
}

/// Fake HTTP adapter that scripts responses without a real server.
class _FakeHttpClientAdapter implements HttpClientAdapter {
  final _ApiClient _client;

  _FakeHttpClientAdapter(this._client);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri.toString();

    // Simulate /flaky: return 503 twice, then 200
    if (uri.contains('/flaky')) {
      _client._flakyAttempts++;
      if (_client._flakyAttempts < 3) {
        return ResponseBody.fromString(
          'Service unavailable',
          503,
          headers: {'content-type': ['application/json']},
        );
      }
      return ResponseBody.fromString(
        '{"status":"ok"}',
        200,
        headers: {'content-type': ['application/json']},
      );
    }

    // Simulate /protected: 401 without token or with seed token, 200 with refreshed
    if (uri.contains('/protected')) {
      final auth = options.headers['Authorization'] as String?;
      if (auth == null || auth == 'Bearer seed_access_token') {
        return ResponseBody.fromString(
          'Unauthorized',
          401,
          headers: {'content-type': ['application/json']},
        );
      }
      if (auth == 'Bearer refreshed_access_token') {
        return ResponseBody.fromString(
          '{"data":"protected","user":"user123"}',
          200,
          headers: {'content-type': ['application/json']},
        );
      }
    }

    // Simulate /oauth/refresh
    if (uri.contains('/oauth/refresh')) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return ResponseBody.fromString(
        '{"accessToken":"refreshed_access_token","refreshToken":"new_refresh_token"}',
        200,
        headers: {'content-type': ['application/json']},
      );
    }

    // Simulate /slow: sleep 12 seconds (exceeds 10s timeout)
    if (uri.contains('/slow')) {
      await Future<void>.delayed(const Duration(seconds: 12));
      return ResponseBody.fromString(
        '{"status":"ok"}',
        200,
        headers: {'content-type': ['application/json']},
      );
    }

    // Simulate /charge: always 409 duplicate
    if (uri.contains('/charge')) {
      return ResponseBody.fromString(
        '{"error":"duplicate_charge"}',
        409,
        headers: {'content-type': ['application/json']},
      );
    }

    // Default: 404
    return ResponseBody.fromString(
      'Not found',
      404,
      headers: {'content-type': ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}
