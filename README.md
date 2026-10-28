# dio_resilience

One Dio interceptor for token refresh, retry, timeouts, circuit breaking, rate limiting, hedging, challenges and fallback. The strategies share one context per request, so they work together instead of fighting each other.

<p align="center">
  <img src="https://raw.githubusercontent.com/NarekManukyan/dio_resilience/main/doc/recordings/circuit_breaker.gif" width="240" alt="Circuit breaker opening, failing fast, probing and closing again in the example app">
  <img src="https://raw.githubusercontent.com/NarekManukyan/dio_resilience/main/doc/recordings/challenge.gif" width="240" alt="A CAPTCHA challenge solved and the request replayed in the example app">
  <img src="https://raw.githubusercontent.com/NarekManukyan/dio_resilience/main/doc/recordings/overview_intro.gif" width="240" alt="Running a retry scenario with its event log and statistics in the example app">
</p>

## Why it exists

Most apps build resilience from separate pieces: one package for token refresh, another for retry and circuit breaking, timeouts set by hand. Stacked as separate interceptors, they don't know about each other:

- A retry fires before the token refresh finishes and wastes an attempt.
- The circuit breaker counts a `401` that a refresh was about to fix.
- A total timeout can't cover the retries, because each interceptor only sees its own attempt.
- An error logger behind the retry interceptor reports the same failure once per attempt.

`dio_resilience` runs every strategy inside one pipeline. A `PipelineContext` follows each request through all of its attempts, so:

- an auth refresh or a solved challenge doesn't use up a retry attempt;
- `total` is a deadline for the whole request, retries and waits included;
- a fallback answers whatever the others end with: exhausted retries, a timeout, an open circuit;
- interceptors registered behind the pipeline see the final error exactly once.

## Install

```yaml
dependencies:
  dio: ^5.4.0
  dio_resilience: ^0.3.0
```

## Quick start

```dart
import 'package:dio/dio.dart';
import 'package:dio_resilience/dio_resilience.dart';

final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

ResiliencePipeline.builder()
    .auth(
      tokenStorage: secureTokenStorage,
      refreshToken: (current) async {
        // A separate Dio, so the refresh call doesn't run through this pipeline.
        final res = await refreshDio.post<Map<String, dynamic>>(
          '/token/refresh',
          data: {'refresh_token': current?.refresh},
        );
        return TokenPair(
          access: res.data!['access_token'] as String,
          refresh: res.data!['refresh_token'] as String,
        );
      },
    )
    .retry(maxAttempts: 3)
    .timeout(total: const Duration(seconds: 30), perAttempt: const Duration(seconds: 10))
    .build()
    .attachTo(dio);

final me = await dio.get<Map<String, dynamic>>('/users/me');
```

Register the pipeline with `attachTo(dio)`, not `dio.interceptors.add`: it needs the `Dio` to replay requests through. Interceptors added before `attachTo` run ahead of the pipeline and see every attempt; interceptors added after it see each attempt's request and success, but only the final error.

## Strategies

Execution order is fixed: `auth → rateLimit → circuit → hedging → challenge → retry → timeout → fallback`.

| Strategy | Purpose | Builder |
|----------|---------|---------|
| Auth | Token injection, single-flight refresh, multi-account, `AuthState` stream | `.auth(...)` |
| Rate limit | Token-bucket or sliding-window throttle, per host or custom key | `.rateLimit(...)` |
| Circuit breaker | Closed / open / half-open with a rolling failure window | `.circuitBreaker(...)` |
| Hedging | Speculative parallel requests; first success wins | `.hedging(...)` |
| Challenge | Solve server-issued challenges (CAPTCHA, MFA step-up, attestation) and replay | `.challenge(...)` |
| Retry | Backoff variants, idempotent methods only, `Retry-After` aware | `.retry(...)` |
| Timeout | Per-attempt timeouts and a deadline for the whole request | `.timeout(...)` |
| Fallback | Canned response or alternate endpoint when everything else failed | `.fallback(...)` |

A strategy acts only on what it's configured for; leave out what you don't need.

<details>
<summary><b>Auth</b>: token injection, single-flight refresh, multi-account</summary>

Injects `Authorization: <scheme> <token>` on every request. With `refreshToken`, a `401` (or a `shouldRefresh` match) refreshes the token once for all concurrent requests and replays them.

```dart
ResiliencePipeline.builder()
    .auth(
      tokenStorage: secureTokenStorage,        // your TokenStorage
      refreshToken: (current) async => refresh(current),
      preemptiveRefreshWindow: const Duration(minutes: 1),
      onAuthFailure: (rejection) {
        // Every request whose credentials were rejected, with the token it carried.
        if (rejection.refreshAttempted) router.go('/sign-in');
      },
      isRefreshRequest: (req) => req.path == '/token/refresh',
    )
    .build()
    .attachTo(dio);
```

How refresh behaves:

- One refresh at a time per account; concurrent `401`s wait for it.
- A `401` for a token that another request already replaced replays with the new token instead of refreshing again.
- A token that is expired, or expires within `preemptiveRefreshWindow`, is refreshed before the request goes out.
- A request gets one refresh. A `401` for the refreshed token ends it with `RefreshFailedException`.
- When refresh fails, the caller gets `RefreshFailedException` (a `DioException`, carrying the `401` response and the refresh error). Storage is cleared unless `clearTokensOnRefreshFailure: false`.
- The refresh replay doesn't count against the retry budget.

**Without refresh.** Leave out `refreshToken` when your backend has no refresh endpoint. The strategy then only injects tokens: a `401` reaches the caller unchanged, and `onAuthFailure` reports it with the token that was sent, so an app with several sessions knows which one ended.

**Several accounts.** Requests sent with `Options().withAccount(AccountId('bob'))` read and refresh that account's tokens:

```dart
.auth(
  tokenStorage: activeAccountStorage,
  accountStorage: MemoryAccountTokenStorage(),   // or your AccountTokenStorage
  refreshAccountToken: (account, current) async => refreshFor(account, current),
)
```

**Calls that bring their own credentials** (sign-in, OTP): mark them with `Options().noAuth()`, `extra: ResilienceExtras.noAuth`, or `isRefreshRequest`. The strategy then neither injects a token nor treats a `401` as an expired session.

**Auth state stream**

```dart
pipeline.authStateStream.listen((state) {
  // idle | authenticated | refreshing | unauthenticated | forcedLogout, on change only
});
await pipeline.signOut();
```
</details>

<details>
<summary><b>Rate limit</b>: token bucket or sliding window, wait or fail</summary>

A client-side throttle. A token bucket allows bursts; a sliding window allows at most N requests in any rolling window. `wait` mode holds the request until a slot frees up, within the request's total budget; `fail` mode throws at once.

```dart
// 10 requests per second, bursts of up to 20.
.rateLimit(
  algorithm: const RateLimitAlgorithm.tokenBucket(ratePerSecond: 10, burst: 20),
  mode: RateLimitMode.wait,
)

// At most 5 requests in any rolling second.
.rateLimit(
  algorithm: const RateLimitAlgorithm.slidingWindow(requests: 5, window: Duration(seconds: 1)),
  mode: RateLimitMode.fail,
)
```

| Per call | Effect |
|----------|--------|
| `Options().noRateLimit()` | Skip the limiter |
| `Options().rateLimitKey('user:42')` | Use another bucket than the host's |

Throws `RateLimitExceededException` in `fail` mode, or in `wait` mode when the wait wouldn't fit in the remaining budget. A request cancelled while waiting doesn't take a token.
</details>

<details>
<summary><b>Circuit breaker</b>: closed / open / half-open</summary>

Opens after `failureThreshold` failures inside `windowDuration`, rejects calls for `cooldown`, then lets `halfOpenProbes` requests through: success closes it, failure opens it again. Circuits are per host by default.

```dart
.circuitBreaker(
  failureThreshold: 5,
  windowDuration: const Duration(seconds: 60),
  cooldown: const Duration(seconds: 30),
  halfOpenProbes: 1,
)
```

Not counted as failures: cancelled requests, server challenges, and the pipeline's own decisions (an open circuit, a rate limit, exhausted retries). A cancelled half-open probe gives its slot back.

| Per call | Effect |
|----------|--------|
| `Options().noCircuit()` | Skip the breaker |
| `Options().circuitKey('payments')` | Use this circuit, whatever the host or `keyExtractor` |
| `ResilienceOverrides(circuit: CircuitOverride.threshold(2))` | Trip this key sooner |
| `ResilienceOverrides(circuit: CircuitOverride.cooldown(...))` | Another cooldown for this key |

A rejected call throws `CircuitOpenException`. Retry never replays it; a fallback can answer it. State changes are reported as `CircuitStateChangedEvent` (see [Events](#events-and-metrics)).
</details>

<details>
<summary><b>Hedging</b>: speculative parallel requests</summary>

Sends up to `maxParallel` copies of a slow request, `delay` apart. The first success wins and the others are cancelled. GET and HEAD only by default.

```dart
.hedging(
  maxParallel: 2,
  delay: const Duration(milliseconds: 100),
  shouldHedge: (req) => req.method == 'GET',
)
```

| Per call | Effect |
|----------|--------|
| `Options().noHedging()` | Send one copy |
| `Options().hedge(max: 3)` | Tune this call |

A hedging round counts as one attempt: if every branch fails, retry replays the round. Cancelling the caller's token cancels every branch.
</details>

<details>
<summary><b>Challenge</b>: CAPTCHA, MFA step-up, device attestation</summary>

When the server answers with a challenge, solve it, attach the proof and replay the request.

```dart
.challenge(
  ChallengeConfig<String>(
    // When is a response or error a challenge? A 2xx can be one too.
    matcher: (signal) => switch (signal) {
      ChallengeOnResponse(:final response) => response.statusCode == 428,
      ChallengeOnError() => false,
    },
    // Produce the proof: show a CAPTCHA, ask for an MFA code, call an attestation API.
    solver: (request, response) => showCaptcha(response?.data),
    // Attach it to the request before the replay.
    applier: (request, token) => request.headers['X-Captcha-Token'] = token,
    solverTimeout: const Duration(minutes: 2),
    maxAttempts: 1,
  ),
)
```

- Runs before retry, so a challenge doesn't use up retry attempts, and the circuit breaker doesn't count it as a failure.
- `singleFlight: true` lets concurrent requests share one solve (for reusable tokens such as attestation). Off by default, since a CAPTCHA token is single-use.
- When solving fails, the request fails with `ChallengeFailedException` and a `reason`: `solverError`, `solverTimeout` or `maxAttemptsExceeded`.
- `Options().noChallenge()` or `ResilienceExtras.noChallenge` skips it per call.
</details>

<details>
<summary><b>Retry</b>: backoff, conditions, Retry-After</summary>

```dart
.retry(
  maxAttempts: 3,
  backoff: const Backoff.exponentialJitter(
    initial: Duration(milliseconds: 200),
    maxDelay: Duration(seconds: 10),
  ),
  retryOn: const [
    RetryCondition.statusBetween(500, 599),
    RetryCondition.networkError(),
    RetryCondition.timeout(),
  ],
  doNotRetryOn: const [RetryCondition.status(501)],
  methods: kIdempotentMethods,                        // the default
  maxRetryAfter: const Duration(seconds: 30),         // the default
)
```

- **Only idempotent methods are retried by default** (`GET HEAD OPTIONS TRACE PUT DELETE`), so a `POST` whose response got lost is never sent twice. `methods: null` retries any method; `RetryOverride.policy(methods: {'POST'})` opts in one call.
- **`Retry-After`** (seconds or an HTTP-date) replaces a shorter backoff. One longer than `maxRetryAfter` ends the request with the server's answer instead of waiting.
- **Exhausted retries** end in `AllAttemptsExhaustedException`, which keeps the last attempt's `type`, `response` and `error` (and the attempt itself as `lastError`): a run of timeouts still reads as a timeout.
- Replays for an auth refresh or a solved challenge don't count as attempts.

Backoff: `Backoff.constant`, `Backoff.linear`, `Backoff.exponential`, `Backoff.exponentialJitter` (the default), `Backoff.none`.

| Per call | Effect |
|----------|--------|
| `Options().noRetry()` | No retry |
| `Options().retryAttempts(5)` | Another budget |
| `Options().dontRetryOn({409, 422})` | Skip these statuses |
| `Options().dontRetryWhen([...])` / `.retryOnlyWhen([...])` | Narrow or replace the conditions |
| `RetryOverride.policy(...)` | Budget, backoff, conditions and methods at once |

**Conditions**

| Condition | Matches when |
|-----------|--------------|
| `status(int)` / `statusIn({...})` / `statusBetween(a, b)` | The status code matches |
| `networkError()` | The connection failed or dropped (not a response that failed to decode) |
| `timeout()` | Connect, send or receive timeout |
| `dioMessageContains(text)` | `DioException.message` contains the text |
| `responseBodyContains(text)` | The response body contains the text |
| `responseField('error.code', equals: v)` | A dotted JSON path equals `v` |
| `predicate(fn)` | Your function says so |

Combine with `.or(...)`, `.and(...)`, `.negated()`, `RetryCondition.any([...])`, `RetryCondition.all([...])`. Retry never replays the pipeline's own exceptions (open circuit, failed refresh, timeout, rate limit).
</details>

<details>
<summary><b>Timeout</b>: per attempt, and a deadline for the whole request</summary>

```dart
.timeout(
  total: const Duration(seconds: 30),
  perAttempt: const Duration(seconds: 10),
)
```

- **`total`** is a deadline for the request: every attempt, backoff wait, refresh and rate-limit wait included. An attempt still in flight when it passes is cancelled; a retry whose wait wouldn't fit is not sent. Either way the caller gets `PipelineTimeoutException` (with `lastError` when a retry was skipped). The caller's own `CancelToken` keeps working.
- **`perAttempt`** lowers each attempt's `connectTimeout` and `receiveTimeout` (never raises them). `sendTimeout` is left alone: Dio times the whole request body with it, which would fail any large upload.

| Per call | Effect |
|----------|--------|
| `Options().withTimeout(const Duration(seconds: 5))` | Another total budget |
| `ResilienceOverrides(timeout: TimeoutOverride.perAttempt(...))` | Another per-attempt timeout |
| `ResilienceExtras.noTimeout` | No timeouts from the pipeline |
</details>

<details>
<summary><b>Fallback</b>: when everything else failed</summary>

Runs last and answers whatever the other strategies end with: exhausted retries, a pipeline timeout, an open circuit, a failed refresh or challenge, or an error nothing else handled. Handlers are tried in order; the first that produces a response wins. Cancellations are never answered.

```dart
.fallback(handlers: [
  // A mirror when the primary is down.
  FallbackHandler.predicate(
    (e) => e is AllAttemptsExhaustedException || e is CircuitOpenException,
    FallbackHandler.endpoint('https://mirror.example.com/users/me'),
  ),
  // Otherwise an empty payload so the UI keeps rendering.
  FallbackHandler.response((e, req) => Response(
        requestOptions: req,
        statusCode: 200,
        data: const <String, dynamic>{},
      )),
])
```

An endpoint fallback goes through the same `Dio`, so the other strategies apply to it, but it never falls back again itself.

| Per call | Effect |
|----------|--------|
| `Options().noFallback()` | No fallback |
| `Options().fallbackTo(cachedResponse)` | Answer with this response |
| `Options().fallbackHandlers([...])` | Other handlers for this call |
</details>

## Per-call overrides

Every strategy reads a per-request `ResilienceOverrides` bag, attached with `Options().resilience(...)` or the shortcuts above (they chain: `Options().noRetry().withTimeout(d)`).

```text
RetryOverride      disabled | attempts(n) | exceptWhen([...]) | onlyWhen([...]) | policy(...)
AuthOverride       disabled | account(AccountId)
TimeoutOverride    disabled | total(d) | perAttempt(d)
CircuitOverride    disabled | threshold(n) | cooldown(d)
RateLimitOverride  disabled | bypass
HedgingOverride    disabled | maxParallel(n) | delay(d)
FallbackOverride   disabled | response(fn) | handlers([...])
ChallengeOverride  disabled
```

**Const call sites (Retrofit).** Where only a const map fits, such as Retrofit's `@Extras` or a generated client's `extras:` parameter, use `ResilienceExtras`. The maps combine by spreading; a field set in an overrides bag on the same request wins over the flag.

```dart
@GET('/search')
@Extras({...ResilienceExtras.noRetry, ...ResilienceExtras.noHedging})
Future<SearchPage> search(@Query('q') String q);

// A whole bag works too:
@Extras({kResilienceOverridesKey: ResilienceOverrides(retry: RetryOverride.attempts(5))})
```

## Events and metrics

`.onEvent(...)` reports what the pipeline does, for logs, analytics and metrics:

```dart
ResiliencePipeline.builder()
    .retry()
    .circuitBreaker()
    .onEvent((event) => switch (event) {
          ReplayEvent(:final strategy, :final attemptNumber, :final delay) =>
            log('replay by $strategy, attempt $attemptNumber in $delay'),
          RecoveredEvent(:final strategy) => metrics.count('recovered.$strategy'),
          GaveUpEvent(:final error) => metrics.count('failed.${error.runtimeType}'),
          CircuitStateChangedEvent(:final key, :final to) => log('circuit $key is $to'),
        })
    .build()
    .attachTo(dio);
```

| Event | When |
|-------|------|
| `ReplayEvent` | A strategy sends the request again: `retry`, `auth` or `challenge` |
| `RecoveredEvent` | A strategy answered with a substitute response (fallback) |
| `GaveUpEvent` | The request failed for good; carries the error the caller gets |
| `CircuitStateChangedEvent` | A circuit moved between closed, open and half-open |

## Exceptions

Every exception the pipeline makes is a `DioException` (a `DioResilienceException`), so existing `on DioException` handlers keep working.

| Exception | Thrown when |
|-----------|-------------|
| `AllAttemptsExhaustedException` | Retries ran out (keeps the last attempt's type, response and error) |
| `PipelineTimeoutException` | The total budget ran out |
| `RefreshFailedException` | The token refresh failed, or the refreshed token was rejected |
| `CircuitOpenException` | The circuit is open |
| `RateLimitExceededException` | The rate limiter refused the call |
| `ChallengeFailedException` | A challenge couldn't be solved |

## Writing a strategy

Extend `ResilienceStrategy` and override the hooks you need: `onStart` (once per request), `onRequest` (every attempt), `onResponse`, `onError` (return a `StrategyDecision`: `replay`, `respond` or `fail`, or `null` to pass) and `onDispatch` (take over sending, as hedging does). A `fail` decision hands its error to the strategies after yours, so a fallback can still answer it. The built-in strategies are good examples.

## Example app

[`example/`](example) is a Flutter app with a screen for every strategy, a scriptable fake backend (no server needed), a live event log fed by `onEvent`, and request statistics: logical calls vs. requests on the wire, retries, refreshes, fallbacks, failures by type, p50/p95 latency.

```sh
cd example
flutter run                                   # pick a scenario and press Run
flutter run --dart-define=DEMO_AUTOPLAY=true  # walks through every screen on its own
```

| Retry | Auth | Timeout | Hedging |
|:-:|:-:|:-:|:-:|
| <img src="https://raw.githubusercontent.com/NarekManukyan/dio_resilience/main/doc/screenshots/02_retry_backoff.png" width="180" alt="Retry screen"> | <img src="https://raw.githubusercontent.com/NarekManukyan/dio_resilience/main/doc/screenshots/03_auth_refresh.png" width="180" alt="Auth screen"> | <img src="https://raw.githubusercontent.com/NarekManukyan/dio_resilience/main/doc/screenshots/04_timeout.png" width="180" alt="Timeout screen"> | <img src="https://raw.githubusercontent.com/NarekManukyan/dio_resilience/main/doc/screenshots/07_hedging.png" width="180" alt="Hedging screen"> |
| **Fallback** | **Overrides** | **Cancellation** | **Rate limit** |
| <img src="https://raw.githubusercontent.com/NarekManukyan/dio_resilience/main/doc/screenshots/09_fallback.png" width="180" alt="Fallback screen"> | <img src="https://raw.githubusercontent.com/NarekManukyan/dio_resilience/main/doc/screenshots/10_overrides.png" width="180" alt="Overrides screen"> | <img src="https://raw.githubusercontent.com/NarekManukyan/dio_resilience/main/doc/screenshots/11_cancellation.png" width="180" alt="Cancellation screen"> | <img src="https://raw.githubusercontent.com/NarekManukyan/dio_resilience/main/doc/screenshots/06_rate_limiter.png" width="180" alt="Rate limiter screen"> |

## Upgrading from 0.2

0.3.0 changes some defaults; see the [changelog](CHANGELOG.md#030--2026-10-29). In short: retry skips non-idempotent methods and caps `Retry-After`, `networkError()` no longer matches decoding errors, `total` cancels an attempt in flight, the auth strategy's `multiAccountStorage` became `accountStorage`, and `onRefreshFailed` is deprecated in favour of `onAuthFailure`.

## License

MIT
