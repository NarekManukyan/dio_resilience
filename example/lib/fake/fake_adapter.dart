import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A scripted response returned by a [FakeHandler].
class FakeResult {
  const FakeResult(this.statusCode, {this.data, this.headers});

  final int statusCode;

  /// Response body. A [String] is sent verbatim; anything else is
  /// `jsonEncode`d.
  final Object? data;

  /// Extra response headers, merged over the default `content-type`.
  final Map<String, List<String>>? headers;
}

/// What a [FakeHandler] receives for one call into the fake wire.
class FakeCall {
  const FakeCall(this.options, this.wireCallNumber);

  final RequestOptions options;

  /// 1-indexed count of every call this adapter has served so far, across
  /// every endpoint and every screen instance — handy as the "requests on
  /// the wire" stat.
  final int wireCallNumber;
}

typedef FakeHandler = Future<FakeResult> Function(FakeCall call);

/// A scriptable [HttpClientAdapter] standing in for a real backend, so every
/// scenario in this demo runs offline and deterministically.
///
/// [handler] decides the outcome of each call; per-scenario state (attempt
/// counters, flakiness, latency) lives in the closure a screen passes in.
///
/// Two things every real adapter does are reproduced generically here so
/// screens don't have to:
///  - a [RequestOptions.receiveTimeout] set by `TimeoutStrategy.perAttempt`
///    is honoured: a handler slower than it fails with a receive-timeout
///    [DioException], the same as a real socket would;
///  - [cancelFuture] is raced against the handler, so a cancelled attempt
///    (caller cancellation, or the pipeline's own total-budget deadline)
///    ends at once instead of waiting out a latency nobody cares about
///    anymore.
class FakeHttpClientAdapter implements HttpClientAdapter {
  FakeHttpClientAdapter(this.handler, {this.onWireCall, this.onCancelled});

  final FakeHandler handler;

  /// Fired once per call, before [handler] runs.
  final void Function(RequestOptions options)? onWireCall;

  /// Fired when a call ends in cancellation (caller or deadline), instead of
  /// a scripted outcome.
  final void Function(RequestOptions options)? onCancelled;

  int _wireCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _wireCalls++;
    onWireCall?.call(options);

    try {
      var outcome = _raceCancel(
        handler(FakeCall(options, _wireCalls)),
        cancelFuture,
        options,
      );
      final receiveTimeout = options.receiveTimeout;
      if (receiveTimeout != null && receiveTimeout > Duration.zero) {
        outcome = outcome.timeout(
          receiveTimeout,
          onTimeout: () => throw DioException(
            requestOptions: options,
            type: DioExceptionType.receiveTimeout,
            message:
                'Fake receive timeout after ${receiveTimeout.inMilliseconds}ms',
          ),
        );
      }
      final result = await outcome;
      final body = switch (result.data) {
        null => '',
        final String s => s,
        final other => jsonEncode(other),
      };
      return ResponseBody.fromString(
        body,
        result.statusCode,
        headers: {
          'content-type': const ['application/json'],
          ...?result.headers,
        },
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) onCancelled?.call(options);
      rethrow;
    }
  }

  /// Ends the call the moment [cancelFuture] fires instead of waiting out a
  /// scripted latency the caller no longer cares about.
  Future<FakeResult> _raceCancel(
    Future<FakeResult> future,
    Future<void>? cancelFuture,
    RequestOptions options,
  ) {
    if (cancelFuture == null) return future;
    return Future.any<FakeResult>([
      future,
      cancelFuture.then(
        (_) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
        ),
      ),
    ]);
  }

  @override
  void close({bool force = false}) {}
}
