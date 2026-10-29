import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_resilience/src/overrides.dart';
import 'package:dio_resilience/src/pipeline_context.dart';
import 'package:dio_resilience/src/strategies/fallback_strategy.dart';
import 'package:dio_resilience/src/strategy.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a minimal [DioException] with an optional status code.
DioException _dioError(
  RequestOptions opts, {
  int? statusCode,
  DioExceptionType type = DioExceptionType.badResponse,
}) {
  return DioException(
    requestOptions: opts,
    type: type,
    response: statusCode == null
        ? null
        : Response<dynamic>(
            statusCode: statusCode,
            requestOptions: opts,
          ),
  );
}

/// Builds a 200 [Response].
Response<dynamic> _ok(RequestOptions opts, {Object? data}) => Response<dynamic>(
      statusCode: 200,
      requestOptions: opts,
      data: data,
    );

/// Attaches [overrides] to [opts] and returns a new [PipelineContext].
PipelineContext _ctxWith(RequestOptions opts, ResilienceOverrides overrides) {
  final patched = opts.copyWith(
    extra: {
      ...opts.extra,
      '__dio_resilience_overrides__': overrides,
    },
  );
  return PipelineContext(patched);
}

// ---------------------------------------------------------------------------
// Fake Dio
//
// Implements [Dio] via noSuchMethod so we are insulated from version-specific
// method signature changes. Only [request], [options], [interceptors], and
// [close] have real implementations; everything else throws [UnimplementedError]
// through [noSuchMethod].
// ---------------------------------------------------------------------------

class _FakeDio implements Dio {
  final List<String> calledUrls = [];
  final Map<String, Response<dynamic>> _responses = {};
  final Map<String, DioException Function(RequestOptions)> _errors = {};

  void respondWith(String url, Response<dynamic> response) =>
      _responses[url] = response;

  void rejectWith(
    String url,
    DioException Function(RequestOptions) builder,
  ) =>
      _errors[url] = builder;

  @override
  Future<Response<T>> request<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    calledUrls.add(path);
    if (_errors.containsKey(path)) {
      throw _errors[path]!(RequestOptions(path: path));
    }
    if (_responses.containsKey(path)) {
      return _responses[path]! as Response<T>;
    }
    throw DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.unknown,
      message: 'No canned response for $path',
    );
  }

  @override
  BaseOptions options = BaseOptions();

  @override
  Interceptors get interceptors => _interceptors;
  final Interceptors _interceptors = Interceptors();

  @override
  void close({bool force = false}) {}

  /// Catch-all for every other Dio method we don't need in tests.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '${invocation.memberName} not implemented in _FakeDio',
      );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late RequestOptions request;
  late PipelineContext ctx;

  setUp(() {
    request = RequestOptions(path: 'https://primary.example.com/api');
    ctx = PipelineContext(request);
  });

  // ── 1. ResponseFallbackHandler ──────────────────────────────────────────

  group('ResponseFallbackHandler', () {
    test('returns canned response on any error', () async {
      final strategy = FallbackStrategy(
        handlers: [
          FallbackHandler.response(
            (err, opts) => _ok(opts, data: {'cached': true}),
          ),
        ],
      );

      final error = _dioError(request, statusCode: 503);
      final decision = await strategy.onError(ctx, error);

      expect(decision, isA<RespondDecision>());
      final response = (decision! as RespondDecision).response;
      expect(response.statusCode, 200);
      expect((response.data as Map)['cached'], isTrue);
    });

    test('receives the original DioException and RequestOptions', () async {
      DioException? capturedErr;
      RequestOptions? capturedOpts;

      final strategy = FallbackStrategy(
        handlers: [
          FallbackHandler.response((err, opts) {
            capturedErr = err;
            capturedOpts = opts;
            return _ok(opts);
          }),
        ],
      );

      final error = _dioError(request, statusCode: 404);
      await strategy.onError(ctx, error);

      expect(capturedErr, same(error));
      expect(capturedOpts, same(request));
    });
  });

  // ── 2. EndpointFallbackHandler ──────────────────────────────────────────

  group('EndpointFallbackHandler', () {
    test('re-fires to alternate URL and returns its response', () async {
      const altUrl = 'https://mirror.example.com/api';
      final fake = _FakeDio();
      fake.respondWith(
        altUrl,
        _ok(RequestOptions(path: altUrl), data: 'alt'),
      );

      final strategy = FallbackStrategy(
        handlers: [const FallbackHandler.endpoint(altUrl)],
      );
      strategy.injectDio(fake);

      final error = _dioError(request, statusCode: 503);
      final decision = await strategy.onError(ctx, error);

      expect(decision, isA<RespondDecision>());
      expect(fake.calledUrls, contains(altUrl));
      expect((decision! as RespondDecision).response.data, 'alt');
    });

    test('method override is forwarded to the re-fired request', () async {
      const altUrl = 'https://mirror.example.com/api';
      final fake = _FakeDio();
      fake.respondWith(altUrl, _ok(RequestOptions(path: altUrl)));

      final strategy = FallbackStrategy(
        handlers: [const FallbackHandler.endpoint(altUrl, method: 'GET')],
      );
      strategy.injectDio(fake);

      final error = _dioError(request, statusCode: 503);
      final decision = await strategy.onError(ctx, error);

      expect(decision, isA<RespondDecision>());
      expect(fake.calledUrls, contains(altUrl));
    });

    test('returns null (no recursion) when alt endpoint also fails', () async {
      const altUrl = 'https://mirror.example.com/api';
      final fake = _FakeDio();
      fake.rejectWith(
        altUrl,
        (opts) => _dioError(opts, statusCode: 500),
      );

      final strategy = FallbackStrategy(
        handlers: [const FallbackHandler.endpoint(altUrl)],
      );
      strategy.injectDio(fake);

      final error = _dioError(request, statusCode: 503);
      final decision = await strategy.onError(ctx, error);

      // Alt endpoint failed — strategy must return null, not recurse.
      expect(decision, isNull);
      // Only one call to the alt URL — no retry loop.
      expect(fake.calledUrls.where((u) => u == altUrl).length, 1);
    });

    test('fallback_in_flight flag prevents re-entry', () async {
      // Simulate a recursive call: the meta flag must cause immediate return.
      ctx.meta['fallback_in_flight'] = true;

      final strategy = FallbackStrategy(
        handlers: [
          FallbackHandler.response((err, opts) => _ok(opts)),
        ],
      );

      final decision =
          await strategy.onError(ctx, _dioError(request, statusCode: 503));

      expect(decision, isNull);
    });
  });

  // ── 3. PredicateFallbackHandler ─────────────────────────────────────────

  group('PredicateFallbackHandler', () {
    test('inner handler fires when predicate is true', () async {
      final strategy = FallbackStrategy(
        handlers: [
          FallbackHandler.predicate(
            (err) => err.response?.statusCode == 503,
            FallbackHandler.response(
              (err, opts) => _ok(opts, data: 'matched'),
            ),
          ),
        ],
      );

      final error = _dioError(request, statusCode: 503);
      final decision = await strategy.onError(ctx, error);

      expect(decision, isA<RespondDecision>());
      expect((decision! as RespondDecision).response.data, 'matched');
    });

    test('inner handler is skipped when predicate is false', () async {
      final strategy = FallbackStrategy(
        handlers: [
          FallbackHandler.predicate(
            (err) => err.response?.statusCode == 404,
            FallbackHandler.response(
              (err, opts) => _ok(opts, data: 'matched'),
            ),
          ),
        ],
      );

      // 503 does not satisfy the predicate for 404.
      final error = _dioError(request, statusCode: 503);
      final decision = await strategy.onError(ctx, error);

      expect(decision, isNull);
    });

    test('predicate wrapping an endpoint handler delegates correctly',
        () async {
      const altUrl = 'https://mirror.example.com/api';
      final fake = _FakeDio();
      fake.respondWith(
        altUrl,
        _ok(RequestOptions(path: altUrl), data: 'ep'),
      );

      final strategy = FallbackStrategy(
        handlers: [
          FallbackHandler.predicate(
            (err) => err.type == DioExceptionType.connectionError,
            const FallbackHandler.endpoint(altUrl),
          ),
        ],
      );
      strategy.injectDio(fake);

      final networkError = DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
      );
      final decision = await strategy.onError(ctx, networkError);

      expect(decision, isA<RespondDecision>());
      expect((decision! as RespondDecision).response.data, 'ep');
    });
  });

  // ── 4. Multiple handlers walked in order ────────────────────────────────

  group('Handler ordering', () {
    test('first matching handler wins — second is not tried', () async {
      var secondCalled = false;

      final strategy = FallbackStrategy(
        handlers: [
          FallbackHandler.response(
            (err, opts) => _ok(opts, data: 'first'),
          ),
          FallbackHandler.response((err, opts) {
            secondCalled = true;
            return _ok(opts, data: 'second');
          }),
        ],
      );

      final error = _dioError(request, statusCode: 503);
      final decision = await strategy.onError(ctx, error);

      expect((decision! as RespondDecision).response.data, 'first');
      expect(secondCalled, isFalse);
    });

    test('skipped predicate moves to next handler', () async {
      final strategy = FallbackStrategy(
        handlers: [
          // predicate does not match
          FallbackHandler.predicate(
            (err) => err.response?.statusCode == 404,
            FallbackHandler.response(
              (err, opts) => _ok(opts, data: 'miss'),
            ),
          ),
          // this one matches
          FallbackHandler.response(
            (err, opts) => _ok(opts, data: 'hit'),
          ),
        ],
      );

      final error = _dioError(request, statusCode: 503);
      final decision = await strategy.onError(ctx, error);

      expect((decision! as RespondDecision).response.data, 'hit');
    });

    test('returns null when no handler matches', () async {
      final strategy = FallbackStrategy(
        handlers: [
          FallbackHandler.predicate(
            (err) => false,
            FallbackHandler.response((err, opts) => _ok(opts)),
          ),
        ],
      );

      final error = _dioError(request, statusCode: 503);
      final decision = await strategy.onError(ctx, error);

      expect(decision, isNull);
    });
  });

  // ── 5. Override: disabled ────────────────────────────────────────────────

  group('FallbackOverride.disabled', () {
    test('skips all handlers when override is disabled', () async {
      final strategy = FallbackStrategy(
        handlers: [
          FallbackHandler.response((err, opts) => _ok(opts)),
        ],
      );

      ctx = _ctxWith(
        request,
        const ResilienceOverrides(fallback: FallbackOverride.disabled),
      );

      final error = _dioError(request, statusCode: 503);
      final decision = await strategy.onError(ctx, error);

      expect(decision, isNull);
    });
  });

  // ── 6. Override: response ────────────────────────────────────────────────

  group('FallbackOverride.response', () {
    test('per-request response override replaces pipeline handlers', () async {
      // Pipeline handler would return data: 'pipeline'.
      final strategy = FallbackStrategy(
        handlers: [
          FallbackHandler.response(
            (err, opts) => _ok(opts, data: 'pipeline'),
          ),
        ],
      );

      ctx = _ctxWith(
        request,
        ResilienceOverrides(
          fallback: FallbackOverride.response(
            (err) => Response<dynamic>(
              statusCode: 200,
              requestOptions: request,
              data: 'override',
            ),
          ),
        ),
      );

      final error = _dioError(request, statusCode: 503);
      final decision = await strategy.onError(ctx, error);

      expect(decision, isA<RespondDecision>());
      expect((decision! as RespondDecision).response.data, 'override');
    });
  });

  // ── 7. Override: handlers ────────────────────────────────────────────────

  group('FallbackOverride.handlers', () {
    test('per-request handler list replaces pipeline default', () async {
      // Pipeline returns 'pipeline', override returns 'custom'.
      final strategy = FallbackStrategy(
        handlers: [
          FallbackHandler.response(
            (err, opts) => _ok(opts, data: 'pipeline'),
          ),
        ],
      );

      ctx = _ctxWith(
        request,
        ResilienceOverrides(
          fallback: FallbackOverride.handlers([
            FallbackHandler.response(
              (err, opts) => _ok(opts, data: 'custom'),
            ),
          ]),
        ),
      );

      final error = _dioError(request, statusCode: 503);
      final decision = await strategy.onError(ctx, error);

      expect((decision! as RespondDecision).response.data, 'custom');
    });
  });

  // ── 8. Passthrough / no-op cases ────────────────────────────────────────

  group('Passthrough / no-op cases', () {
    test('returns null with empty handler list', () async {
      final strategy = FallbackStrategy(handlers: []);
      final decision =
          await strategy.onError(ctx, _dioError(request, statusCode: 503));
      expect(decision, isNull);
    });

    test('fallback_in_flight set externally causes no-op', () async {
      ctx.meta['fallback_in_flight'] = true;

      final strategy = FallbackStrategy(
        handlers: [
          FallbackHandler.response((err, opts) => _ok(opts)),
        ],
      );

      final decision =
          await strategy.onError(ctx, _dioError(request, statusCode: 503));
      expect(decision, isNull);
    });
  });

  // ── 9. Endpoint handler without injectDio ────────────────────────────────

  group('Endpoint handler without injectDio', () {
    test('returns null gracefully when Dio was not injected', () async {
      // FallbackStrategy created but never had injectDio called.
      final strategy = FallbackStrategy(
        handlers: [
          const FallbackHandler.endpoint('https://mirror.example.com/api'),
        ],
      );

      final decision =
          await strategy.onError(ctx, _dioError(request, statusCode: 503));
      expect(decision, isNull);
    });
  });
}
