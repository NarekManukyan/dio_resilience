import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../options_extension.dart';
import '../overrides.dart';
import '../pipeline_context.dart';
import '../strategy.dart';

// ---------------------------------------------------------------------------
// Public algorithm configuration
// ---------------------------------------------------------------------------

/// Selects the rate-limiting algorithm used by [RateLimiterStrategy].
///
/// Use [RateLimitAlgorithm.tokenBucket] (the default) for burst-friendly
/// limiting, or [RateLimitAlgorithm.slidingWindow] for strict N-per-window
/// semantics.
sealed class RateLimitAlgorithm {
  const RateLimitAlgorithm();

  /// Token-bucket algorithm.
  ///
  /// Tokens refill continuously at [ratePerSecond] tokens per second up to a
  /// maximum of [burst] tokens. A [burst] > 1 lets callers send a short spike
  /// of requests without being throttled.
  const factory RateLimitAlgorithm.tokenBucket({
    required double ratePerSecond,
    required int burst,
  }) = _TokenBucketConfig;

  /// Sliding-window algorithm.
  ///
  /// Allows at most [requests] calls inside any rolling [window] of time.
  /// Unlike a fixed-window counter, this never resets abruptly at a boundary.
  const factory RateLimitAlgorithm.slidingWindow({
    required int requests,
    required Duration window,
  }) = _SlidingWindowConfig;
}

final class _TokenBucketConfig extends RateLimitAlgorithm {
  final double ratePerSecond;
  final int burst;
  const _TokenBucketConfig({required this.ratePerSecond, required this.burst});
}

final class _SlidingWindowConfig extends RateLimitAlgorithm {
  final int requests;
  final Duration window;
  const _SlidingWindowConfig({required this.requests, required this.window});
}

// ---------------------------------------------------------------------------
// Mode
// ---------------------------------------------------------------------------

/// Controls what [RateLimiterStrategy] does when no token is immediately
/// available.
enum RateLimitMode {
  /// Block the request until a token becomes available. If the pipeline's
  /// total elapsed budget would be exceeded first, throw
  /// [RateLimitExceededException] instead of waiting indefinitely.
  wait,

  /// Throw [RateLimitExceededException] immediately without waiting.
  fail,
}

// ---------------------------------------------------------------------------
// In-memory bucket state (internal)
// ---------------------------------------------------------------------------

/// Token-bucket state for a single rate-limit key.
final class _TokenBucket {
  final double ratePerSecond;
  final int burst;

  double _tokens;
  DateTime _lastRefill;

  _TokenBucket({
    required this.ratePerSecond,
    required this.burst,
    required DateTime now,
  })  : _tokens = burst.toDouble(),
        _lastRefill = now;

  /// Refill tokens based on elapsed time, then try to consume one token.
  ///
  /// Returns `true` when a token was consumed, `false` when the bucket is
  /// empty.
  bool tryConsume(DateTime now) {
    _refill(now);
    if (_tokens >= 1.0) {
      _tokens -= 1.0;
      return true;
    }
    return false;
  }

  /// How long until the next token is available (given current fill rate).
  Duration timeUntilNextToken(DateTime now) {
    _refill(now);
    if (_tokens >= 1.0) return Duration.zero;
    final deficit = 1.0 - _tokens;
    final seconds = deficit / ratePerSecond;
    return Duration(microseconds: (seconds * 1e6).ceil());
  }

  void _refill(DateTime now) {
    final elapsed = now.difference(_lastRefill).inMicroseconds / 1e6;
    if (elapsed <= 0) return;
    _tokens = (_tokens + elapsed * ratePerSecond).clamp(0.0, burst.toDouble());
    _lastRefill = now;
  }
}

/// Sliding-window state for a single rate-limit key.
final class _SlidingWindow {
  final int maxRequests;
  final Duration window;

  /// Timestamps of recent requests, oldest first.
  final Queue<DateTime> _timestamps = Queue<DateTime>();

  _SlidingWindow({required this.maxRequests, required this.window});

  /// Prune timestamps older than [window], then check if a new request fits.
  ///
  /// Returns `true` and records the timestamp when allowed; `false` otherwise.
  bool tryConsume(DateTime now) {
    _prune(now);
    if (_timestamps.length < maxRequests) {
      _timestamps.addLast(now);
      return true;
    }
    return false;
  }

  /// How long until the oldest recorded request falls outside the window.
  Duration timeUntilNextToken(DateTime now) {
    _prune(now);
    if (_timestamps.length < maxRequests) return Duration.zero;
    final oldest = _timestamps.first;
    final expiresAt = oldest.add(window);
    final wait = expiresAt.difference(now);
    return wait > Duration.zero ? wait : Duration.zero;
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(window);
    // Use `!isAfter` so that a timestamp exactly at the cutoff is dropped.
    // With strict `isBefore`, a wait of exactly `window` would still see the
    // boundary entry and report no available slot, causing an infinite spin
    // in `_acquireSlidingWindow` when callers wake up at the boundary.
    while (_timestamps.isNotEmpty && !_timestamps.first.isAfter(cutoff)) {
      _timestamps.removeFirst();
    }
  }
}

// ---------------------------------------------------------------------------
// Strategy
// ---------------------------------------------------------------------------

/// A rate-limiting strategy that throttles outgoing requests using either a
/// **token-bucket** or a **sliding-window** algorithm.
///
/// ## Key concepts
///
/// * **Per-host keying** — by default each unique host gets its own bucket.
///   Provide [keyExtractor] to bucket by any dimension (path, tenant, etc.).
/// * **Per-request override** — callers can attach
///   `Options().rateLimitKey('custom')` or `Options().noRateLimit()` to skip
///   or redirect to a different bucket for a single call.
/// * **Clock injection** — pass [now] in tests to avoid real wall-clock
///   dependencies.
///
/// ## Usage
///
/// ```dart
/// ResiliencePipeline.builder()
///   .rateLimit(
///     algorithm: RateLimitAlgorithm.tokenBucket(ratePerSecond: 10, burst: 20),
///     mode: RateLimitMode.wait,
///   )
///   .build()
///   .attachTo(dio);
/// ```
final class RateLimiterStrategy extends ResilienceStrategy {
  @override
  String get name => 'rate_limiter';

  /// The algorithm configuration (token-bucket or sliding-window).
  final RateLimitAlgorithm algorithm;

  /// What to do when no token is immediately available.
  final RateLimitMode mode;

  /// Extracts the bucket key from a request. Defaults to the request's host.
  final String Function(RequestOptions)? keyExtractor;

  /// Clock override for testing. Defaults to [DateTime.now].
  final DateTime Function() now;

  // In-memory state keyed by rate-limit key.
  final Map<String, _TokenBucket> _buckets = {};
  final Map<String, _SlidingWindow> _windows = {};

  RateLimiterStrategy({
    required this.algorithm,
    this.mode = RateLimitMode.wait,
    this.keyExtractor,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  @override
  Future<void> onRequest(PipelineContext ctx) async {
    final override = _rateLimitOverride(ctx.request);

    // Disabled or bypassed — skip entirely.
    if (override is RateLimitDisabled || override is RateLimitBypassed) {
      return;
    }

    final key = _resolveKey(ctx.request);

    switch (algorithm) {
      case _TokenBucketConfig(:final ratePerSecond, :final burst):
        await _acquireTokenBucket(
          ctx: ctx,
          key: key,
          ratePerSecond: ratePerSecond,
          burst: burst,
        );
      case _SlidingWindowConfig(:final requests, :final window):
        await _acquireSlidingWindow(
          ctx: ctx,
          key: key,
          maxRequests: requests,
          window: window,
        );
    }
  }

  // -------------------------------------------------------------------------
  // Token-bucket acquisition
  // -------------------------------------------------------------------------

  Future<void> _acquireTokenBucket({
    required PipelineContext ctx,
    required String key,
    required double ratePerSecond,
    required int burst,
  }) async {
    final bucket = _buckets.putIfAbsent(
      key,
      () => _TokenBucket(
        ratePerSecond: ratePerSecond,
        burst: burst,
        now: now(),
      ),
    );

    while (true) {
      final current = now();
      if (bucket.tryConsume(current)) return;

      final wait = bucket.timeUntilNextToken(current);
      await _waitOrFail(ctx: ctx, key: key, wait: wait);
    }
  }

  // -------------------------------------------------------------------------
  // Sliding-window acquisition
  // -------------------------------------------------------------------------

  Future<void> _acquireSlidingWindow({
    required PipelineContext ctx,
    required String key,
    required int maxRequests,
    required Duration window,
  }) async {
    final sw = _windows.putIfAbsent(
      key,
      () => _SlidingWindow(maxRequests: maxRequests, window: window),
    );

    while (true) {
      final current = now();
      if (sw.tryConsume(current)) return;

      final wait = sw.timeUntilNextToken(current);
      await _waitOrFail(ctx: ctx, key: key, wait: wait);
    }
  }

  // -------------------------------------------------------------------------
  // Shared wait-or-fail logic
  // -------------------------------------------------------------------------

  Future<void> _waitOrFail({
    required PipelineContext ctx,
    required String key,
    required Duration wait,
  }) async {
    if (mode == RateLimitMode.fail) {
      throw RateLimitExceededException(
        requestOptions: ctx.request,
        key: key,
        stackTrace: StackTrace.current,
      );
    }

    // mode == RateLimitMode.wait
    // Check total budget before sleeping.
    final remaining = ctx.remainingBudget;
    if (remaining != null && (remaining <= Duration.zero || wait > remaining)) {
      throw RateLimitExceededException(
        requestOptions: ctx.request,
        key: key,
        stackTrace: StackTrace.current,
      );
    }

    await Future<void>.delayed(wait);

    // A request cancelled while it waited must not take a token.
    final cancelled = ctx.request.cancelToken?.cancelError;
    if (cancelled != null) throw cancelled;
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Resolve the bucket key for a request: per-request inline key →
  /// custom keyExtractor → host fallback.
  String _resolveKey(RequestOptions request) {
    // Inline key set via Options().rateLimitKey('...')
    final inlineKey = request.extra[kRateLimitKeyOverride];
    if (inlineKey is String && inlineKey.isNotEmpty) return inlineKey;

    // Custom extractor provided at strategy construction time.
    if (keyExtractor != null) return keyExtractor!(request);

    // Default: host (with port if non-standard).
    final uri = request.uri;
    final port = uri.hasPort &&
            ((uri.scheme == 'https' && uri.port != 443) ||
                (uri.scheme == 'http' && uri.port != 80))
        ? ':${uri.port}'
        : '';
    return '${uri.host}$port';
  }

  RateLimitOverride? _rateLimitOverride(RequestOptions request) =>
      overridesFor(request)?.rateLimit;
}
