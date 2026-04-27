# dio_resilience

A unified Dio interceptor bundling token refresh, retry, timeout, circuit breaker, rate limiting, and fallback — strategies that coordinate so they don't fight each other.

## Why it exists

Most HTTP clients handle resilience piecemeal: `fresh_dio` for token refresh, `polly_dart` for retry and circuit breaking, manual timeout configuration. When you combine them, they don't know about each other:

- Retry happens before token refresh completes, wasting an attempt.
- Circuit breaker trips while the auth token is being refreshed.
- Timeout fires globally while a single auth refresh is still in flight.

`dio_resilience` bundles auth, retry, timeout, and (soon) circuit breaker, rate limiting, hedging, and fallback into a single pipeline. Strategies share a context tracking total elapsed time, attempt counts, and in-flight token refreshes. They coordinate so a retry won't fire if auth is already refreshing, and the timeout budget respects both initial and retry attempts.

## Quick start

```dart
import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';

final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

// Build and attach the pipeline
dio.interceptors.add(
  ResiliencePipeline.builder()
    .auth(
      // Use a SEPARATE Dio inside refreshToken — don't recurse through the
      // pipeline you're configuring. A common pattern is a top-level
      // `final _refreshDio = Dio(BaseOptions(baseUrl: 'https://auth.example.com'));`
      refreshToken: (current) async {
        final res = await _refreshDio.post(
          '/token/refresh',
          data: {'refresh_token': current?.refresh},
        );
        return TokenPair(
          access: res.data['access_token'] as String,
          refresh: res.data['refresh_token'] as String,
        );
      },
      preemptiveRefreshWindow: const Duration(minutes: 1),
    )
    .retry(
      maxAttempts: 3,
      backoff: Backoff.exponentialJitter(
        initial: Duration(milliseconds: 200),
        multiplier: 2.0,
        maxDelay: Duration(seconds: 10),
      ),
    )
    .timeout(
      total: Duration(seconds: 30),
      perAttempt: Duration(seconds: 10),
    )
    .build()
    ..attachTo(dio)
);

// Make a request; auth, retry, and timeout are automatic
final res = await dio.get('/users/me');
```

## Per-call overrides

Each strategy can be overridden per-request using extension methods on `Options`:

### Skip retry for a single request

```dart
dio.post(
  '/upload',
  options: Options().noRetry(),
);
```

### Skip retry only for specific status codes

```dart
dio.post(
  '/charge',
  options: Options().dontRetryOn({409, 422}),
);
```

### Skip retry when a condition matches

```dart
dio.post(
  '/withdraw',
  options: Options().dontRetryWhen([
    RetryCondition.dioMessageContains('insufficient_funds'),
  ]),
);
```

Other shortcuts: `.noAuth()`, `.withTimeout(Duration)`, `.withAccount(AccountId)`, `.retryAttempts(int)`, `.retryOnlyWhen(List<RetryCondition>)`.

## RetryCondition built-in matchers

- `status(int)` — Retry only if status code matches exactly.
- `statusIn(Set<int>)` — Retry if status code is in the set.
- `statusBetween(int min, int max)` — Retry if status code is between min and max (inclusive).
- `networkError()` — Retry on network errors (connection, DNS, etc.).
- `timeout()` — Retry on any timeout (connect, send, receive).
- `dioMessageContains(String)` — Retry if DioException.message contains text (case-insensitive by default).
- `responseBodyContains(String)` — Retry if response body stringified contains text.
- `responseField(String path, {Object? equals})` — Retry if dotted JSON path equals a value.
- `predicate(bool Function(RetryEvaluation))` — Custom predicate; full access to error, attempt number, elapsed time.

All conditions are combinable with `.or()`, `.and()`, `.negated()`.

## Override sealed-class types

- `RetryOverride.disabled` — Skip retry.
- `RetryOverride.attempts(int)` — Override max attempts.
- `RetryOverride.policy({...})` — Full custom backoff and conditions.
- `AuthOverride.disabled` — Skip auth refresh.
- `AuthOverride.account(AccountId)` — Use a different account.
- `TimeoutOverride.disabled` — Disable timeout enforcement.
- `TimeoutOverride.total(Duration)` — Set total budget.
- `TimeoutOverride.perAttempt(Duration)` — Set per-attempt budget.

## What's in v0.1 vs v0.2

**v0.1** (current):

- Auth strategy: single-flight token refresh, multi-account support, AuthState stream.
- Retry strategy: all backoff variants (constant, linear, exponential, exponential-jitter), Retry-After header support.
- Timeout strategy: per-attempt and total budget enforcement.
- Typed override system: ResilienceOverrides + sealed RetryOverride / AuthOverride / TimeoutOverride.
- RetryCondition predicates and combinators.
- Options extensions for per-request overrides.

**v0.2** (planned):

- Circuit breaker strategy.
- Rate limiter strategy.
- Hedging strategy (speculative retries).
- Fallback strategy (fallback responses or endpoints).

## Roadmap

- v0.2: Circuit breaker, rate limiter, hedging, fallback.
- Testing improvements and real-world feedback.

## License

MIT
