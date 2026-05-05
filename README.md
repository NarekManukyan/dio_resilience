# dio_resilience

A unified Dio interceptor bundling token refresh, retry, timeout, circuit breaker, rate limiting, hedging, and fallback — strategies that coordinate so they don't fight each other.

## Why it exists

Most HTTP clients handle resilience piecemeal: `fresh_dio` for token refresh, `polly_dart` for retry and circuit breaking, manual timeout configuration. When you combine them, they don't know about each other:

- Retry happens before token refresh completes, wasting an attempt.
- Circuit breaker trips while the auth token is being refreshed.
- Timeout fires globally while a single auth refresh is still in flight.

`dio_resilience` bundles auth, retry, timeout, circuit breaker, rate limiting, hedging, and fallback into a single pipeline. Strategies share a `PipelineContext` tracking total elapsed time, attempt counts, and in-flight token refreshes. They coordinate so a retry won't fire if auth is already refreshing, hedging counts as a single attempt for retry, and total-budget breaches surface as a typed `PipelineTimeoutException`.

## Quick start

```dart
import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';

final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

ResiliencePipeline.builder()
  .auth(
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
  .retry(maxAttempts: 3)
  .timeout(total: const Duration(seconds: 30), perAttempt: const Duration(seconds: 10))
  .build()
  .attachTo(dio);

final res = await dio.get('/users/me');
```

## Strategies

Execution order is fixed: `auth → rateLimit → circuit → hedging → retry → timeout → fallback`.

| Strategy | Purpose | Builder |
|----------|---------|---------|
| Auth | OAuth/JWT injection + single-flight refresh, multi-account, `AuthState` stream | `.auth(...)` |
| Rate limit | Token-bucket or sliding-window throttle, per-host or custom key | `.rateLimit(...)` |
| Circuit breaker | Closed / open / half-open with rolling failure window and cooldown | `.circuitBreaker(...)` |
| Hedging | Speculative parallel requests; first success wins | `.hedging(...)` |
| Retry | Constant / linear / exponential / exponential-jitter backoff, `Retry-After` aware | `.retry(...)` |
| Timeout | Per-attempt and total-budget enforcement | `.timeout(...)` |
| Fallback | Canned response or alternate endpoint on terminal failure | `.fallback(...)` |

<details>
<summary><b>Auth</b> — OAuth/JWT injection, single-flight refresh, multi-account</summary>

Injects `Authorization: Bearer <token>` (or custom scheme), runs single-flight token refresh on 401, supports multi-account storage, and streams `AuthState` transitions.

```dart
ResiliencePipeline.builder()
  .auth(
    // Use a SEPARATE Dio inside refreshToken — don't recurse through the
    // pipeline you're configuring. Common pattern: a top-level
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
    tokenStorage: MemoryTokenStorage(),
    scheme: 'Bearer',
    preemptiveRefreshWindow: const Duration(minutes: 1),
    onRefreshFailed: () => navigator.go('/sign-in'),
    isRefreshRequest: (req) => req.path == '/token/refresh',
    shouldRefresh: (err) => err.response?.statusCode == 401,
  )
  .build()
  .attachTo(dio);
```

**Per-call overrides**

| Shortcut | Override |
|----------|----------|
| `Options().noAuth()` | `AuthOverride.disabled` |
| `Options().withAccount(AccountId('alice'))` | `AuthOverride.account(...)` |

**Auth state stream**

```dart
pipeline.authStateStream.listen((state) {
  // AuthState.idle | authenticated | refreshing | unauthenticated | forcedLogout
});
await pipeline.signOut();
```

Throws typed `RefreshFailedException` (a `DioException` subtype) when refresh fails terminally; storage is cleared and `onRefreshFailed` fires.
</details>

<details>
<summary><b>Rate limit</b> — token-bucket or sliding-window, wait/fail modes</summary>

Local client-side throttle. Token bucket allows bursts; sliding window enforces strict N-per-window. `wait` mode blocks until a token is available (respecting the pipeline's total budget); `fail` mode throws immediately.

```dart
// Token bucket: 10 req/s steady state, 20-request burst capacity.
ResiliencePipeline.builder()
  .rateLimit(
    algorithm: RateLimitAlgorithm.tokenBucket(ratePerSecond: 10, burst: 20),
    mode: RateLimitMode.wait,
    keyExtractor: (req) => req.uri.host, // default — per-host bucket
  )
  .build();

// Sliding window: at most 5 requests in any rolling 1-second window.
ResiliencePipeline.builder()
  .rateLimit(
    algorithm: RateLimitAlgorithm.slidingWindow(
      requests: 5,
      window: const Duration(seconds: 1),
    ),
    mode: RateLimitMode.fail,
  )
  .build();
```

**Per-call overrides**

| Shortcut | Override |
|----------|----------|
| `Options().noRateLimit()` | `RateLimitOverride.disabled` |
| `Options().rateLimitKey('user:42')` | Route to a per-user bucket instead of the default host bucket |

Throws `RateLimitExceededException` in `fail` mode, or in `wait` mode when the wait would exceed the request's remaining total-timeout budget.
</details>

<details>
<summary><b>Circuit breaker</b> — closed / open / half-open with rolling window</summary>

Trips open after `failureThreshold` failures inside a rolling `windowDuration`. Stays open for `cooldown`, then transitions to half-open and lets `halfOpenProbes` requests through; success closes the circuit, failure reopens it.

```dart
ResiliencePipeline.builder()
  .circuitBreaker(
    failureThreshold: 5,
    windowDuration: const Duration(seconds: 60),
    cooldown: const Duration(seconds: 30),
    halfOpenProbes: 1,
    keyExtractor: (req) => req.uri.host, // default — separate breaker per host
  )
  .build();
```

**Per-call overrides**

| Shortcut | Override |
|----------|----------|
| `Options().noCircuit()` | `CircuitOverride.disabled` |
| `Options().circuitKey('user-api')` | Pin this call to a specific breaker key |

Throws `CircuitOpenException` (a `DioException` subtype) when the breaker short-circuits a call. Retry strategy never replays a `CircuitOpenException` — short-circuited calls are terminal.
</details>

<details>
<summary><b>Hedging</b> — speculative parallel requests, first success wins</summary>

Fires up to `maxParallel` parallel requests with `delay` between each launch. The first success resolves the call and cancels losers via `CancelToken`. Defaults to GET/HEAD only — override `shouldHedge` for idempotent POSTs.

```dart
ResiliencePipeline.builder()
  .hedging(
    maxParallel: 2,
    delay: const Duration(milliseconds: 100),
    shouldHedge: (req) => req.method == 'GET',
  )
  .build();
```

**Per-call overrides**

| Shortcut | Override |
|----------|----------|
| `Options().noHedging()` | `HedgingOverride.disabled` |
| `Options().hedge(max: 3, delay: const Duration(milliseconds: 50))` | Tune for one call |

A hedging round (all branches) counts as a single attempt for the retry strategy, so retry still fires after a fully-failed hedging round.
</details>

<details>
<summary><b>Retry</b> — backoff variants, conditional matchers</summary>

```dart
ResiliencePipeline.builder()
  .retry(
    maxAttempts: 3,
    backoff: const Backoff.exponentialJitter(
      initial: Duration(milliseconds: 200),
      multiplier: 2.0,
      maxDelay: Duration(seconds: 10),
    ),
    retryOn: const [
      RetryCondition.statusBetween(500, 599),
      RetryCondition.networkError(),
      RetryCondition.timeout(),
    ],
    doNotRetryOn: const [
      RetryCondition.status(409),
    ],
  )
  .build();
```

Backoff variants: `Backoff.constant(d)`, `Backoff.linear(initial, increment)`, `Backoff.exponential(initial, multiplier, maxDelay)`, `Backoff.exponentialJitter(...)`. `Retry-After` headers (seconds or HTTP-date) override computed delay.

**Per-call overrides**

| Shortcut | Override |
|----------|----------|
| `Options().noRetry()` | `RetryOverride.disabled` |
| `Options().retryAttempts(5)` | `RetryOverride.attempts(5)` |
| `Options().dontRetryOn({409, 422})` | `RetryOverride.exceptWhen([statusIn({409,422})])` |
| `Options().dontRetryWhen([...])` | `RetryOverride.exceptWhen([...])` |
| `Options().retryOnlyWhen([...])` | `RetryOverride.onlyWhen([...])` |

**RetryCondition matchers**

| Matcher | Triggers retry when |
|---------|---------------------|
| `status(int)` | Status code matches exactly |
| `statusIn(Set<int>)` | Status code is in the set |
| `statusBetween(int, int)` | Status code is in `[min, max]` (inclusive) |
| `networkError()` | Connection error or `unknown` with non-null cause |
| `timeout()` | Connect / send / receive timeout |
| `dioMessageContains(String)` | `DioException.message` contains text (case-insensitive) |
| `responseBodyContains(String)` | Stringified response body contains text |
| `responseField(path, equals: v)` | Dotted JSON path resolves to `v` |
| `predicate(fn)` | Custom predicate over `RetryEvaluation` |

Combine with `.or(...)`, `.and(...)`, `.negated()`. Retry never replays `DioResilienceException` (circuit-open / refresh-failed / pipeline-timeout / rate-limit-exceeded) — those are terminal decisions made by sibling strategies.
</details>

<details>
<summary><b>Timeout</b> — per-attempt and total-budget enforcement</summary>

```dart
ResiliencePipeline.builder()
  .timeout(
    total: const Duration(seconds: 30),
    perAttempt: const Duration(seconds: 10),
  )
  .build();
```

`perAttempt` is applied to Dio's per-request `connectTimeout` / `sendTimeout` / `receiveTimeout` (only shortened, never extended). `total` is enforced by the pipeline across all attempts (initial + retries + auth replays). When the total budget is exceeded, the pipeline raises `PipelineTimeoutException` from `onError` — the underlying transport error is replaced with the typed exception so callers can pattern-match the deadline.

**Per-call overrides**

| Shortcut | Override |
|----------|----------|
| `Options().withTimeout(const Duration(seconds: 5))` | `TimeoutOverride.total(...)` |
| Use `TimeoutOverride.perAttempt(...)` via `.resilience(...)` | Override per-attempt only |
| `Options().resilience(ResilienceOverrides(timeout: TimeoutOverride.disabled))` | Skip enforcement |
</details>

<details>
<summary><b>Fallback</b> — canned response or alternate endpoint on failure</summary>

Walks an ordered handler list on terminal error; first match wins. Runs last in the pipeline, only when no other strategy resolved the call.

```dart
ResiliencePipeline.builder()
  .fallback(handlers: [
    // Try a cached/alternate endpoint first when the primary returns 503.
    FallbackHandler.predicate(
      (e) => e.response?.statusCode == 503,
      FallbackHandler.endpoint('/cached/users/me'),
    ),
    // Otherwise return a canned empty payload so the UI keeps rendering.
    FallbackHandler.response((e, req) => Response(
      requestOptions: req,
      statusCode: 200,
      data: const <String, dynamic>{},
    )),
  ])
  .build();
```

Endpoint fallback re-fires through the same Dio (so other strategies still apply on the alt request) but a guard flag prevents recursive fallback if the alt endpoint also fails.

**Per-call overrides**

| Shortcut | Override |
|----------|----------|
| `Options().noFallback()` | `FallbackOverride.disabled` |
| `Options().fallbackTo(cachedResponse)` | `FallbackOverride.response(...)` |
| `Options().fallbackHandlers([...])` | `FallbackOverride.handlers([...])` |
</details>

## Per-call overrides — full surface

Every strategy honors a per-request `ResilienceOverrides` bag attached via `Options().resilience(...)`. Convenience shortcuts cover the common cases — see each strategy's toggle above. Sealed override types:

```text
RetryOverride        disabled | attempts(int) | exceptWhen([...]) | onlyWhen([...]) | policy({...})
AuthOverride         disabled | account(AccountId)
TimeoutOverride      disabled | total(Duration) | perAttempt(Duration)
CircuitOverride      disabled | threshold(int) | cooldown(Duration)
RateLimitOverride    disabled | bypass
HedgingOverride      disabled | maxParallel(int) | delay(Duration)
FallbackOverride     disabled | response(fn) | handlers([...])
```

## Roadmap

- Pluggable storage for circuit / rate-limit state (Redis, Hive).
- Metrics hooks (per-strategy counters, latency histograms).
- More backoff algorithms; expanded `Retry-After` semantics for additional headers.

## License

MIT
