# Changelog

## 0.3.0 — 2026-10-29

This release fixes how strategies hand work to each other, so some defaults
change. Read **Breaking changes** before upgrading.

### Breaking changes

- **Retry only retries idempotent methods by default** (`GET`, `HEAD`,
  `OPTIONS`, `TRACE`, `PUT`, `DELETE`). A `POST` whose response got lost is no
  longer sent twice. Pass `retry(methods: null)` for the old behaviour, or
  `RetryOverride.policy(methods: {'POST'})` for one call.
- **`Retry-After` is capped**: longer than `maxRetryAfter` (default 30 s) ends
  the request with the server's answer instead of waiting. Pass
  `maxRetryAfter: null` to wait any value (still within the total budget).
- **`RetryCondition.networkError()` only matches real transport failures**:
  `connectionError`, or `unknown` caused by a socket error, a cut TLS
  handshake or a dropped HTTP connection. A response that failed to decode is
  no longer retried.
- **`AllAttemptsExhaustedException` keeps the last attempt's `type`** (it was
  always `unknown`) and requires `lastError`.
- **The auth strategy returns `RefreshFailedException` as a decision** instead
  of throwing it from `onError`; it now carries the `401` response. A request
  gets one refresh: a `401` for its refreshed token ends it instead of
  refreshing forever.
- **`AuthStrategy(multiAccountStorage:)` is replaced by `accountStorage:`**, an
  `AccountTokenStorage` keyed by `AccountId`. The old one could not tell
  accounts apart.
- **`refreshToken` is optional.** Without it the auth strategy only injects
  tokens and a `401` reaches the caller unchanged.
- **`PipelineContext.wasReplayedAfterRefresh` and `AuthPhase` are gone.**
  `StrategyDecision.replay(countsAsAttempt: false)` replaces the flag.
- **The total budget lives in `PipelineContext.totalBudget`**, not
  `ctx.meta['totalBudget']`.
- **`perAttempt` no longer sets `sendTimeout`.** Dio times the whole request
  body with it, so a per-attempt value failed large uploads.
- **`TimeoutOverride.total` keeps the pipeline's `perAttempt`, and
  `TimeoutOverride.perAttempt` keeps its `total`** (each used to clear the
  other).
- **`kCircuitKeyOverride` is now `'__dio_resilience_circuit_key__'`**, and a
  per-request `circuitKey(...)` now wins over `keyExtractor`.
- **`RateLimitException` (never thrown) is removed**; use
  `RateLimitExceededException`.
- **`RetryStrategy` has no `const` constructor** anymore (it takes a clock).

### Fixes

- **Retries no longer nest.** Each replay used to run inside the previous
  attempt's error handler, so interceptors added after the pipeline saw the
  final error once per attempt. The pipeline now replays in one loop and
  hands the outcome on once: interceptors behind it see each attempt's
  request, but only the final error.
- **Fallback runs after the other strategies give up.** An exhausted retry, a
  pipeline timeout, an open circuit, a failed refresh or a failed challenge
  now reaches the fallback handlers; before, any of these skipped fallback.
  Errors thrown in `onRequest` (open circuit, rate limit) now go through the
  error chain too.
- **`total` is a real deadline.** An attempt still in flight when the budget
  runs out is cancelled and the caller gets `PipelineTimeoutException`. A
  retry whose wait would not fit in the budget left fails at once (with
  `lastError`) instead of sleeping first.
- **Auth and challenge replays don't use up retry attempts**, and the first
  error after one is retried normally.
- **Auth refresh:** a `401` for a token another request already replaced
  replays with the new token instead of refreshing again; a request waiting on
  a failed refresh gets an exception about its own request; an already
  expired token is refreshed before sending; a failed preemptive refresh
  surfaces as `RefreshFailedException`; refresh is single-flight per account.
- **Retry waits honour cancellation**, and `Retry-After` HTTP-dates are parsed
  (all three RFC 9110 forms).
- **Endpoint fallback no longer recurses** when the alternate endpoint fails
  too, and forwards the caller's `CancelToken`.
- **Hedging:** branches are no longer retried one by one inside a round,
  cancelling the caller's token cancels every branch, and a typed exception
  from a branch keeps its type.
- **Circuit breaker:** cancelled requests and the pipeline's own decisions are
  not counted as failures, a half-open probe that is cancelled gives its slot
  back (the circuit could stay half-open forever), a replay of a half-open
  probe (retry, refresh, solved challenge) is no longer rejected as a second
  probe, a challenge-shaped 2xx no longer counts as a success, and
  `CircuitOverride.threshold` / `.cooldown` are honoured (they were ignored).
- **Rate limiter:** sees the total budget on a request's first attempt (the
  timeout strategy used to set it too late), and a request cancelled while
  waiting doesn't take a token.
- **Challenge:** a 2xx response the matcher flags is now solved (it used to
  skip the error chain), the circuit breaker skips only the challenge error
  itself (the flag used to stick for the rest of the request), and a throwing
  matcher or applier no longer breaks the pipeline.
- **`attachTo` registers the pipeline once**, even if called twice; adding the
  pipeline with `dio.interceptors.add` fails with a clear `StateError` on the
  first request instead of a `LateInitializationError` on the first retry; a
  pipeline attached to a second `Dio` throws.
- **The auth state stream emits only changes**, not `authenticated` on every
  request.

### New

- **Challenge strategy**: pluggable challenge-response handling for
  server-issued proof flows (CAPTCHA, MFA step-up, device attestation) via
  `ChallengeConfig<T>` (matcher, solver, applier). Generic over the token
  type. Single-flight is opt-in, since most challenge tokens are single-use.
  Per-solve timeout and a per-request `maxAttempts` guard. Throws
  `ChallengeFailedException` with a `ChallengeFailureReason`
  (`solverError` / `solverTimeout` / `maxAttemptsExceeded`).
  `ChallengeOverride.disabled` / `.noChallenge()` opt out per request. Runs
  before retry; the circuit breaker doesn't count challenges as failures.
- **`.onEvent(...)`**: `ReplayEvent`, `RecoveredEvent`, `GaveUpEvent` and
  `CircuitStateChangedEvent`, for logs and metrics.
- **`onAuthFailure(AuthRejection)`**: called for every request whose
  credentials were rejected, with the token it carried, its account, the
  response and the refresh error. Replaces `onRefreshFailed` (deprecated).
  `clearTokensOnRefreshFailure: false` leaves the session to the app.
- **Multi-account auth**: `AccountTokenStorage`, `MemoryAccountTokenStorage`
  and `refreshAccountToken`.
- **`ResilienceExtras`**: const `extra` maps (`noRetry`, `noAuth`,
  `noTimeout`, `noCircuit`, `noRateLimit`, `noHedging`, `noFallback`,
  `noChallenge`) for Retrofit's `@Extras` and other const-only call sites.
  `kResilienceOverridesKey` and `kSkipAuthKey` are public too.
- **`retry(methods:, maxRetryAfter:)`** and `RetryOverride.policy(methods:)`.
- **`ResilienceStrategy.onStart`**: a hook that runs once per request before
  any `onRequest`.
- **`PipelineContext.replayCount`, `remainingBudget`, `isBudgetExhausted`**.
- **`ResilienceOverrides.copyWith`**, and `parseHttpDate`.

## 0.2.0 — 2026-05-05

New strategies:

- **Circuit breaker**: closed / open / half-open states with rolling failure window, configurable cooldown and half-open probe budget. Per-host keying with custom `keyExtractor` hook. `CircuitOverride.disabled / threshold / cooldown` per-request overrides. `.noCircuit()` and `.circuitKey(...)` `Options` shortcuts. Throws typed `CircuitOpenException` when short-circuiting.
- **Rate limiter**: pluggable algorithm via `RateLimitAlgorithm.tokenBucket(...)` (burst-friendly) or `RateLimitAlgorithm.slidingWindow(...)` (strict). `RateLimitMode.wait` (block until token, respecting total budget) or `RateLimitMode.fail` (throw immediately). Per-host keying with `keyExtractor` hook. `RateLimitOverride.disabled / bypass`. `.noRateLimit()` / `.rateLimitKey(...)` shortcuts. Throws `RateLimitExceededException`.
- **Hedging**: speculative parallel requests after a configurable inter-hedge delay; first success wins, losers cancelled via `CancelToken`. Defaults to GET/HEAD only via `shouldHedge` predicate. `HedgingOverride.disabled / maxParallel(n) / delay(d)`. `.noHedging()` / `.hedge(...)` shortcuts. Counts as a single attempt for the retry strategy so retry still fires on a failed hedging round.
- **Fallback**: walks an ordered list of `FallbackHandler`s; supports canned `Response` (`FallbackHandler.response(...)`), alternate endpoint refire (`FallbackHandler.endpoint(url, method:)`), and conditional wrappers (`FallbackHandler.predicate(...)`). Endpoint fallback re-fires through the same Dio so other strategies still apply, with a guard flag preventing recursive fallback. `FallbackOverride.disabled / response / handlers`. `.noFallback()` / `.fallbackTo(...)` / `.fallbackHandlers(...)` shortcuts.

Pipeline:

- New `ResilienceStrategy.onDispatch` hook that lets a strategy own request dispatch (used by hedging). Default returns `null`; existing strategies are unaffected.
- Strategy execution order: `auth → rateLimit → circuit → hedging → retry → timeout → fallback`.
- Total-budget exhaustion now surfaces as `PipelineTimeoutException` from `onError` instead of propagating the underlying transport error.

Bug fixes (carried over from 0.1):

- `RefreshFailedException` is now thrown directly from the auth strategy instead of being wrapped in a generic `DioException`. The unawaited single-flight completer error no longer escapes when there are no concurrent waiters.
- `overridesFor()` now accepts both `RequestOptions` and `Options`, removing the need for `as RequestOptions` casts at call sites.
- `RetryCondition.responseBodyContains` and `RetryCondition.responseField` correctly evaluate when the test/eval input only specifies a response body (no status code).

## 0.1.0 — 2026-04-28

Initial release.

- Auth strategy with single-flight token refresh, multi-account support, AuthState stream.
- Retry strategy with all backoff variants (constant / linear / exponential / exponential-jitter), Retry-After header support.
- Timeout strategy with per-attempt and total budget enforcement.
- Typed override system: ResilienceOverrides + sealed RetryOverride / AuthOverride / TimeoutOverride classes.
- RetryCondition typed conditions (status, statusIn, statusBetween, networkError, timeout, dioMessageContains, responseBodyContains, responseField, predicate, plus or/and/negated combinators).
- Options extensions: .resilience(), .noRetry(), .noAuth(), .withTimeout(), .withAccount(), .retryAttempts(), .dontRetryOn(), .dontRetryWhen(), .retryOnlyWhen().
- Stub override types for circuit breaker, rate limiter, hedging, fallback (v0.2).
