# Changelog

## 0.1.0 — 2026-04-28

Initial release.

- Auth strategy with single-flight token refresh, multi-account support, AuthState stream.
- Retry strategy with all backoff variants (constant / linear / exponential / exponential-jitter), Retry-After header support.
- Timeout strategy with per-attempt and total budget enforcement.
- Typed override system: ResilienceOverrides + sealed RetryOverride / AuthOverride / TimeoutOverride classes.
- RetryCondition typed conditions (status, statusIn, statusBetween, networkError, timeout, dioMessageContains, responseBodyContains, responseField, predicate, plus or/and/negated combinators).
- Options extensions: .resilience(), .noRetry(), .noAuth(), .withTimeout(), .withAccount(), .retryAttempts(), .dontRetryOn(), .dontRetryWhen(), .retryOnlyWhen().
- Stub override types for circuit breaker, rate limiter, hedging, fallback (v0.2).
