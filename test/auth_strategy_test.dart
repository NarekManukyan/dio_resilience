import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';
import 'package:test/test.dart';

/// Fake in-memory token storage for testing.
class FakeStorage implements TokenStorage {
  TokenPair? _pair;

  @override
  Future<TokenPair?> read() async => _pair;

  @override
  Future<void> write(TokenPair pair) async {
    _pair = pair;
  }

  @override
  Future<void> clear() async {
    _pair = null;
  }
}

void main() {
  group('AuthStrategy', () {
    late AuthStrategy strategy;
    late FakeStorage storage;
    late int refreshCallCount;
    late TokenPair refreshedToken;

    setUp(() {
      storage = FakeStorage();
      refreshCallCount = 0;
      refreshedToken = const TokenPair(access: 'new_access', refresh: 'new_refresh');
    });

    tearDown(() {
      strategy.dispose();
    });

    /// Test 1: Token gets injected as Authorization header on request.
    test('injects token as Authorization header on request', () async {
      const token = TokenPair(access: 'test_token');
      await storage.write(token);

      strategy = AuthStrategy(
        storage: storage,
        refreshToken: (_) async => refreshedToken,
      );

      final request = RequestOptions(path: '/api/test');
      final ctx = PipelineContext(request);

      await strategy.onRequest(ctx);

      expect(ctx.request.headers['Authorization'], equals('Bearer test_token'));
    });

    /// Test 2: 401 triggers refresh, replay returns success.
    test('401 triggers refresh and replays request', () async {
      const initialToken = TokenPair(access: 'old_token');
      await storage.write(initialToken);

      strategy = AuthStrategy(
        storage: storage,
        refreshToken: (_) async {
          refreshCallCount++;
          return refreshedToken;
        },
      );

      final request = RequestOptions(path: '/api/test');
      final ctx = PipelineContext(request);

      // Simulate a 401 error
      final errorResponse = Response<dynamic>(
        statusCode: 401,
        requestOptions: request,
      );
      final error = DioException(
        requestOptions: request,
        response: errorResponse,
        type: DioExceptionType.badResponse,
      );

      final decision = await strategy.onError(ctx, error);

      expect(decision, isA<ReplayDecision>());
      expect(refreshCallCount, equals(1));
      expect(ctx.wasReplayedAfterRefresh, isTrue);

      // Verify token was updated in storage
      final storedToken = await storage.read();
      expect(storedToken?.access, equals('new_access'));
    });

    /// Test 3: Concurrent 401s share a single refresh (single-flight).
    test('concurrent 401s use single-flight refresh via Completer', () async {
      const initialToken = TokenPair(access: 'old_token');
      await storage.write(initialToken);

      final refreshCompleter = Completer<TokenPair>();

      strategy = AuthStrategy(
        storage: storage,
        refreshToken: (_) async {
          refreshCallCount++;
          return refreshCompleter.future;
        },
      );

      final request1 = RequestOptions(path: '/api/test1');
      final ctx1 = PipelineContext(request1);
      final errorResponse1 = Response<dynamic>(
        statusCode: 401,
        requestOptions: request1,
      );
      final error1 = DioException(
        requestOptions: request1,
        response: errorResponse1,
        type: DioExceptionType.badResponse,
      );

      final request2 = RequestOptions(path: '/api/test2');
      final ctx2 = PipelineContext(request2);
      final errorResponse2 = Response<dynamic>(
        statusCode: 401,
        requestOptions: request2,
      );
      final error2 = DioException(
        requestOptions: request2,
        response: errorResponse2,
        type: DioExceptionType.badResponse,
      );

      // Fire both errors concurrently
      final future1 = strategy.onError(ctx1, error1);
      final future2 = strategy.onError(ctx2, error2);

      // Allow first refresh to start
      await Future<void>.delayed(Duration.zero);

      // Complete the refresh
      refreshCompleter.complete(refreshedToken);

      await future1;
      await future2;

      // Verify refresh was called only once (single-flight)
      expect(refreshCallCount, equals(1));
    });

    /// Test 4: Refresh failure clears storage and throws RefreshFailedException.
    test('refresh failure clears storage and throws RefreshFailedException',
        () async {
      const initialToken = TokenPair(access: 'old_token');
      await storage.write(initialToken);

      strategy = AuthStrategy(
        storage: storage,
        refreshToken: (_) async => throw Exception('Network error'),
      );

      final request = RequestOptions(path: '/api/test');
      final ctx = PipelineContext(request);

      final errorResponse = Response<dynamic>(
        statusCode: 401,
        requestOptions: request,
      );
      final error = DioException(
        requestOptions: request,
        response: errorResponse,
        type: DioExceptionType.badResponse,
      );

      expect(
        () => strategy.onError(ctx, error),
        throwsA(isA<RefreshFailedException>()),
      );

      // Verify storage was cleared
      final storedToken = await storage.read();
      expect(storedToken, isNull);
    });

    /// Test 5: Preemptive refresh fires when accessExpiresAt is near.
    test('preemptive refresh triggers when token is near expiry', () async {
      final now = DateTime.now();
      final expiresIn30Seconds = now.add(const Duration(seconds: 30));
      final token = TokenPair(
        access: 'old_token',
        accessExpiresAt: expiresIn30Seconds,
      );
      await storage.write(token);

      strategy = AuthStrategy(
        storage: storage,
        refreshToken: (_) async {
          refreshCallCount++;
          return refreshedToken;
        },
        preemptiveRefreshWindow: const Duration(minutes: 1),
      );

      final request = RequestOptions(path: '/api/test');
      final ctx = PipelineContext(request);

      await strategy.onRequest(ctx);

      // Verify refresh was triggered
      expect(refreshCallCount, equals(1));

      // Verify the new token was injected
      expect(
        ctx.request.headers['Authorization'],
        equals('Bearer new_access'),
      );
    });

    /// Test 6: AuthOverride.disabled skips both injection and refresh handling.
    test('AuthOverride.disabled skips injection and refresh', () async {
      const token = TokenPair(access: 'test_token');
      await storage.write(token);

      strategy = AuthStrategy(
        storage: storage,
        refreshToken: (_) async => refreshedToken,
      );

      // Test skipped injection on request
      final request = RequestOptions(path: '/api/test');
      request.extra['__dio_resilience_overrides__'] = const ResilienceOverrides(
        auth: AuthOverride.disabled,
      );
      final ctx = PipelineContext(request);

      await strategy.onRequest(ctx);

      // Authorization header should not be injected
      expect(ctx.request.headers['Authorization'], isNull);

      // Test skipped refresh on error
      final errorResponse = Response<dynamic>(
        statusCode: 401,
        requestOptions: request,
      );
      final error = DioException(
        requestOptions: request,
        response: errorResponse,
        type: DioExceptionType.badResponse,
      );

      final decision = await strategy.onError(ctx, error);

      // No decision should be made (auth is disabled)
      expect(decision, isNull);
      expect(refreshCallCount, equals(0));
    });

    /// Test 7: Custom scheme is honored.
    test('custom Authorization scheme is honored', () async {
      const token = TokenPair(access: 'test_token');
      await storage.write(token);

      strategy = AuthStrategy(
        storage: storage,
        refreshToken: (_) async => refreshedToken,
        scheme: 'Token',
      );

      final request = RequestOptions(path: '/api/test');
      final ctx = PipelineContext(request);

      await strategy.onRequest(ctx);

      expect(ctx.request.headers['Authorization'], equals('Token test_token'));
    });

    /// Test 8: authStateStream emits state transitions.
    test('authStateStream emits state transitions', () async {
      const token = TokenPair(access: 'test_token');
      await storage.write(token);

      strategy = AuthStrategy(
        storage: storage,
        refreshToken: (_) async => refreshedToken,
      );

      final states = <AuthState>[];
      strategy.authStateStream.listen((state) {
        states.add(state);
      });

      final request = RequestOptions(path: '/api/test');
      final ctx = PipelineContext(request);

      await strategy.onRequest(ctx);

      // Expect at least authenticated state
      expect(states, contains(AuthState.authenticated));
    });

    /// Test 9: isRefreshRequest predicate prevents auth on refresh endpoint.
    test('isRefreshRequest predicate prevents auth on refresh endpoint',
        () async {
      const token = TokenPair(access: 'test_token');
      await storage.write(token);

      strategy = AuthStrategy(
        storage: storage,
        refreshToken: (_) async => refreshedToken,
        isRefreshRequest: (req) => req.path.contains('/refresh'),
      );

      final request = RequestOptions(path: '/api/refresh');
      final ctx = PipelineContext(request);

      await strategy.onRequest(ctx);

      // Authorization should not be injected on refresh endpoint
      expect(ctx.request.headers['Authorization'], isNull);
    });
  });
}
