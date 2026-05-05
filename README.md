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

## Strategies

| Strategy | Purpose | Builder |
|----------|---------|---------|
| Auth | OAuth/JWT injection + single-flight refresh, multi-account, `AuthState` stream | `.auth(...)` |
| Rate limit | Token-bucket or sliding-window throttle, per-host or custom key | `.rateLimit(...)` |
| Circuit breaker | Closed/open/half-open with rolling failure window and cooldown | `.circuitBreaker(...)` |
| Hedging | Speculative parallel requests; first success wins | `.hedging(...)` |
| Retry | Constant / linear / exponential / exponential-jitter backoff, `Retry-After` aware | `.retry(...)` |
| Timeout | Per-attempt and total-budget enforcement | `.timeout(...)` |
| Fallback | Canned response or alternate endpoint on terminal failure | `.fallback(...)` |

Execution order is fixed: `auth → rateLimit → circuit → hedging → retry → timeout → fallback`. Strategies coordinate via a shared `PipelineContext` so retry won't fire while auth is mid-refresh, hedging counts as a single attempt for retry, and total-timeout breaches surface as a typed `PipelineTimeoutException`.

## Hedging

```dart
ResiliencePipeline.builder()
  .hedging(
    maxParallel: 2,
    delay: const Duration(milliseconds: 100),
    // Default: only GET/HEAD. Override for idempotent POSTs.
    shouldHedge: (req) => req.method == 'GET',
  )
  .build();
```

Per-request: `Options().noHedging()`, `Options().hedge(max: 3, delay: Duration(milliseconds: 50))`.

## Circuit breaker

```dart
ResiliencePipeline.builder()
  .circuitBreaker(
    failureThreshold: 5,
    windowDuration: const Duration(seconds: 60),
    cooldown: const Duration(seconds: 30),
    halfOpenProbes: 1,
    keyExtractor: (req) => req.uri.host, // default
  )
  .build();
```

Per-request: `Options().noCircuit()`, `Options().circuitKey('user-api')`. Throws `CircuitOpenException` (a `DioException` subtype) when the breaker is open.

## Rate limit

```dart
ResiliencePipeline.builder()
  .rateLimit(
    algorithm: RateLimitAlgorithm.tokenBucket(ratePerSecond: 10, burst: 20),
    mode: RateLimitMode.wait, // or .fail
  )
  .build();
```

Per-request: `Options().noRateLimit()`, `Options().rateLimitKey('user:42')`. Throws `RateLimitExceededException` in `fail` mode or when the wait would exceed the total timeout budget.

## Fallback

```dart
ResiliencePipeline.builder()
  .fallback(handlers: [
    FallbackHandler.predicate(
      (e) => e.response?.statusCode == 503,
      FallbackHandler.endpoint('/cached/users/me'),
    ),
    FallbackHandler.response(
      (e, req) => Response(requestOptions: req, statusCode: 200, data: const {}),
    ),
  ])
  .build();
```

Per-request: `Options().noFallback()`, `Options().fallbackTo(cachedResponse)`, `Options().fallbackHandlers([...])`.

## Roadmap

- Pluggable storage for circuit / rate-limit state (Redis, Hive).
- Metrics hooks (per-strategy counters, latency histograms).
- More backoff algorithms; SetCookie / Retry-After semantics for additional headers.

## License

MIT
