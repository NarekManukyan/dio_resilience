# Changelog

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
