import 'package:dio/dio.dart';
import 'package:dio_resilience/src/exceptions.dart';
import 'package:dio_resilience/src/options_extension.dart';
import 'package:dio_resilience/src/overrides.dart';
import 'package:dio_resilience/src/pipeline_context.dart';
import 'package:dio_resilience/src/strategies/rate_limiter_strategy.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a [RequestOptions] for [url].
RequestOptions _req(String url, {Map<String, dynamic>? extra}) =>
    RequestOptions(path: url, extra: extra ?? {});

/// Build a [PipelineContext] for [url].
PipelineContext _ctx(String url, {Map<String, dynamic>? extra}) =>
    PipelineContext(_req(url, extra: extra));

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('RateLimiterStrategy — token bucket', () {
    test('allows up to burst requests immediately', () {
      fakeAsync((fake) {
        final now = fake.getClock(DateTime(2025)).now;
        final strategy = RateLimiterStrategy(
          algorithm: const RateLimitAlgorithm.tokenBucket(
            ratePerSecond: 1,
            burst: 3,
          ),
          mode: RateLimitMode.fail,
          now: now,
        );

        // 3 burst slots should all succeed without any delay.
        for (var i = 0; i < 3; i++) {
          Object? err;
          strategy
              .onRequest(_ctx('https://api.example.com/endpoint'))
              .catchError((Object e) => err = e);
          fake.flushMicrotasks();
          expect(err, isNull, reason: 'request $i should be allowed');
        }
      });
    });

    test('throttles after burst is exhausted in fail mode', () {
      fakeAsync((fake) {
        final now = fake.getClock(DateTime(2025)).now;
        final strategy = RateLimiterStrategy(
          algorithm: const RateLimitAlgorithm.tokenBucket(
            ratePerSecond: 1,
            burst: 2,
          ),
          mode: RateLimitMode.fail,
          now: now,
        );

        // Drain the bucket.
        for (var i = 0; i < 2; i++) {
          strategy.onRequest(_ctx('https://api.example.com/')).ignore();
          fake.flushMicrotasks();
        }

        // Next request must fail immediately.
        Object? err;
        strategy
            .onRequest(_ctx('https://api.example.com/'))
            .catchError((Object e) => err = e);
        fake.flushMicrotasks();

        expect(err, isA<RateLimitExceededException>());
      });
    });

    test('wait mode blocks until token is available then succeeds', () {
      fakeAsync((fake) {
        final now = fake.getClock(DateTime(2025)).now;

        final strategy = RateLimiterStrategy(
          algorithm: const RateLimitAlgorithm.tokenBucket(
            ratePerSecond: 1, // 1 token/sec
            burst: 1,
          ),
          mode: RateLimitMode.wait,
          now: now,
        );

        // First request drains the single token.
        strategy.onRequest(_ctx('https://api.example.com/')).ignore();
        fake.flushMicrotasks();

        // Second request should be pending (waiting for refill).
        var completed = false;
        strategy
            .onRequest(_ctx('https://api.example.com/'))
            .then((_) => completed = true)
            .ignore();
        fake.flushMicrotasks();
        expect(completed, isFalse);

        // Advance 1 second — token refills, Future.delayed fires.
        fake.elapse(const Duration(seconds: 1));
        expect(completed, isTrue);
      });
    });

    test('wait mode throws when total budget would be exceeded', () {
      fakeAsync((fake) {
        final now = fake.getClock(DateTime(2025)).now;
        final strategy = RateLimiterStrategy(
          algorithm: const RateLimitAlgorithm.tokenBucket(
            ratePerSecond: 1,
            burst: 1,
          ),
          mode: RateLimitMode.wait,
          now: now,
        );

        // Drain the single token.
        strategy.onRequest(_ctx('https://api.example.com/')).ignore();
        fake.flushMicrotasks();

        // Second request with a very short budget already consumed.
        final ctx = _ctx('https://api.example.com/');
        ctx.totalBudget = const Duration(milliseconds: 100);
        // Stop the stopwatch so elapsed is always 0 but budget is tiny and
        // the wait (≥1 s) exceeds the remaining budget (100 ms).
        // The strategy compares wait > remaining — 1 s > 100 ms → throw.

        Object? err;
        strategy.onRequest(ctx).catchError((Object e) => err = e);
        fake.flushMicrotasks();

        expect(err, isA<RateLimitExceededException>());
        final exc = err! as RateLimitExceededException;
        expect(exc.key, equals('api.example.com'));
      });
    });
  });

  // -------------------------------------------------------------------------

  group('RateLimiterStrategy — sliding window', () {
    test('allows N requests within window', () {
      fakeAsync((fake) {
        final now = fake.getClock(DateTime(2025)).now;
        final strategy = RateLimiterStrategy(
          algorithm: const RateLimitAlgorithm.slidingWindow(
            requests: 3,
            window: Duration(seconds: 10),
          ),
          mode: RateLimitMode.fail,
          now: now,
        );

        for (var i = 0; i < 3; i++) {
          Object? err;
          strategy
              .onRequest(_ctx('https://svc.example.com/'))
              .catchError((Object e) => err = e);
          fake.flushMicrotasks();
          expect(err, isNull, reason: 'request $i should be allowed');
        }
      });
    });

    test('enforces N-per-window: (N+1)th request fails immediately', () {
      fakeAsync((fake) {
        final now = fake.getClock(DateTime(2025)).now;
        final strategy = RateLimiterStrategy(
          algorithm: const RateLimitAlgorithm.slidingWindow(
            requests: 2,
            window: Duration(seconds: 5),
          ),
          mode: RateLimitMode.fail,
          now: now,
        );

        for (var i = 0; i < 2; i++) {
          strategy.onRequest(_ctx('https://svc.example.com/')).ignore();
          fake.flushMicrotasks();
        }

        Object? err;
        strategy
            .onRequest(_ctx('https://svc.example.com/'))
            .catchError((Object e) => err = e);
        fake.flushMicrotasks();

        expect(err, isA<RateLimitExceededException>());
      });
    });

    test('sliding window resets after window elapses', () {
      fakeAsync((fake) {
        final now = fake.getClock(DateTime(2025)).now;
        final strategy = RateLimiterStrategy(
          algorithm: const RateLimitAlgorithm.slidingWindow(
            requests: 2,
            window: Duration(seconds: 5),
          ),
          mode: RateLimitMode.fail,
          now: now,
        );

        // Fill the window.
        for (var i = 0; i < 2; i++) {
          strategy.onRequest(_ctx('https://svc.example.com/')).ignore();
          fake.flushMicrotasks();
        }

        // Advance past the window — old timestamps expire.
        fake.elapse(const Duration(seconds: 6));

        Object? err;
        strategy
            .onRequest(_ctx('https://svc.example.com/'))
            .catchError((Object e) => err = e);
        fake.flushMicrotasks();

        expect(err, isNull, reason: 'window expired — request should succeed');
      });
    });

    test('wait mode blocks until oldest timestamp leaves window', () {
      fakeAsync((fake) {
        final now = fake.getClock(DateTime(2025)).now;
        final strategy = RateLimiterStrategy(
          algorithm: const RateLimitAlgorithm.slidingWindow(
            requests: 1,
            window: Duration(seconds: 2),
          ),
          mode: RateLimitMode.wait,
          now: now,
        );

        // Use the single slot.
        strategy.onRequest(_ctx('https://svc.example.com/')).ignore();
        fake.flushMicrotasks();

        // Second request waits.
        var completed = false;
        strategy
            .onRequest(_ctx('https://svc.example.com/'))
            .then((_) => completed = true)
            .ignore();
        fake.flushMicrotasks();
        expect(completed, isFalse);

        // Advance 2 s — window clears.
        fake.elapse(const Duration(seconds: 2));
        expect(completed, isTrue);
      });
    });
  });

  // -------------------------------------------------------------------------

  group('RateLimiterStrategy — per-key isolation', () {
    test('different hosts use independent buckets', () {
      fakeAsync((fake) {
        final now = fake.getClock(DateTime(2025)).now;
        final strategy = RateLimiterStrategy(
          algorithm: const RateLimitAlgorithm.tokenBucket(
            ratePerSecond: 1,
            burst: 1,
          ),
          mode: RateLimitMode.fail,
          now: now,
        );

        // Drain host-a bucket.
        strategy.onRequest(_ctx('https://host-a.example.com/')).ignore();
        fake.flushMicrotasks();

        // host-b bucket is still full — should succeed.
        Object? err;
        strategy
            .onRequest(_ctx('https://host-b.example.com/'))
            .catchError((Object e) => err = e);
        fake.flushMicrotasks();

        expect(err, isNull, reason: 'host-b has its own independent bucket');
      });
    });

    test('custom keyExtractor uses returned key for bucketing', () {
      fakeAsync((fake) {
        final now = fake.getClock(DateTime(2025)).now;
        // Always bucket everything under the same key, regardless of host.
        final strategy = RateLimiterStrategy(
          algorithm: const RateLimitAlgorithm.tokenBucket(
            ratePerSecond: 1,
            burst: 1,
          ),
          mode: RateLimitMode.fail,
          keyExtractor: (_) => 'global',
          now: now,
        );

        // First request drains the global bucket.
        strategy.onRequest(_ctx('https://host-a.example.com/')).ignore();
        fake.flushMicrotasks();

        // Even a different host uses the same bucket — should fail.
        Object? err;
        strategy
            .onRequest(_ctx('https://host-b.example.com/'))
            .catchError((Object e) => err = e);
        fake.flushMicrotasks();

        expect(err, isA<RateLimitExceededException>());
        expect((err! as RateLimitExceededException).key, equals('global'));
      });
    });

    test('inline rateLimitKey() override routes to separate bucket', () {
      fakeAsync((fake) {
        final now = fake.getClock(DateTime(2025)).now;
        final strategy = RateLimiterStrategy(
          algorithm: const RateLimitAlgorithm.tokenBucket(
            ratePerSecond: 1,
            burst: 1,
          ),
          mode: RateLimitMode.fail,
          now: now,
        );

        // Drain the default host bucket.
        strategy.onRequest(_ctx('https://api.example.com/')).ignore();
        fake.flushMicrotasks();

        // Request with an inline key hits a different, still-full bucket.
        final opts = Options().rateLimitKey('premium-tier');
        final req = RequestOptions(
          path: 'https://api.example.com/',
          extra: opts.extra ?? {},
        );
        final ctx = PipelineContext(req);

        Object? err;
        strategy.onRequest(ctx).catchError((Object e) => err = e);
        fake.flushMicrotasks();

        expect(err, isNull, reason: 'inline key routes to a fresh bucket');
      });
    });
  });

  // -------------------------------------------------------------------------

  group('RateLimiterStrategy — overrides', () {
    test('RateLimitOverride.disabled skips token acquisition entirely', () {
      fakeAsync((fake) {
        final now = fake.getClock(DateTime(2025)).now;
        // burst: 0 means every real acquisition would fail immediately.
        final strategy = RateLimiterStrategy(
          algorithm: const RateLimitAlgorithm.tokenBucket(
            ratePerSecond: 1,
            burst: 0,
          ),
          mode: RateLimitMode.fail,
          now: now,
        );

        final extra = <String, dynamic>{
          '__dio_resilience_overrides__': const ResilienceOverrides(
            rateLimit: RateLimitOverride.disabled,
          ),
        };
        final ctx = _ctx('https://api.example.com/', extra: extra);

        Object? err;
        strategy.onRequest(ctx).catchError((Object e) => err = e);
        fake.flushMicrotasks();

        expect(err, isNull, reason: 'disabled override bypasses limiting');
      });
    });

    test('RateLimitOverride.bypass skips token acquisition', () {
      fakeAsync((fake) {
        final now = fake.getClock(DateTime(2025)).now;
        final strategy = RateLimiterStrategy(
          algorithm: const RateLimitAlgorithm.tokenBucket(
            ratePerSecond: 1,
            burst: 0,
          ),
          mode: RateLimitMode.fail,
          now: now,
        );

        final extra = <String, dynamic>{
          '__dio_resilience_overrides__': const ResilienceOverrides(
            rateLimit: RateLimitOverride.bypass,
          ),
        };
        final ctx = _ctx('https://api.example.com/', extra: extra);

        Object? err;
        strategy.onRequest(ctx).catchError((Object e) => err = e);
        fake.flushMicrotasks();

        expect(err, isNull, reason: 'bypass override skips limiting');
      });
    });

    test('noRateLimit() extension sets disabled override', () {
      final opts = Options().noRateLimit();
      final overrides =
          opts.extra!['__dio_resilience_overrides__'] as ResilienceOverrides;
      expect(overrides.rateLimit, isA<RateLimitDisabled>());
    });
  });

  // -------------------------------------------------------------------------

  group('RateLimiterStrategy — exception properties', () {
    test('RateLimitExceededException carries key and requestOptions', () {
      fakeAsync((fake) {
        final now = fake.getClock(DateTime(2025)).now;
        final strategy = RateLimiterStrategy(
          algorithm: const RateLimitAlgorithm.tokenBucket(
            ratePerSecond: 1,
            burst: 1,
          ),
          mode: RateLimitMode.fail,
          now: now,
        );

        // Drain the token.
        strategy.onRequest(_ctx('https://api.example.com/')).ignore();
        fake.flushMicrotasks();

        Object? err;
        strategy
            .onRequest(_ctx('https://api.example.com/items'))
            .catchError((Object e) => err = e);
        fake.flushMicrotasks();

        expect(err, isA<RateLimitExceededException>());
        final exc = err! as RateLimitExceededException;
        expect(exc.key, equals('api.example.com'));
        expect(exc.requestOptions, isNotNull);
        expect(exc.message, contains('api.example.com'));
      });
    });
  });

  // -------------------------------------------------------------------------

  group('RateLimiterStrategy — strategy metadata', () {
    test('name returns "rate_limiter"', () {
      final strategy = RateLimiterStrategy(
        algorithm: const RateLimitAlgorithm.tokenBucket(
          ratePerSecond: 10,
          burst: 10,
        ),
      );
      expect(strategy.name, equals('rate_limiter'));
    });
  });
}
