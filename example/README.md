# dio_resilience Example App

A minimal Flutter app demonstrating the `dio_resilience` package: a unified Dio interceptor bundling auth/token-refresh, retry, and timeout strategies.

## Running

```bash
cd example
flutter run
```

## What Each Button Does

1. **Test Retry (Flaky)** — Calls `GET /flaky`, which returns `503` twice in a row, then `200`. Demonstrates exponential jitter retry with maxAttempts=3.

2. **Test Auth Refresh** — Calls `GET /protected`, which returns `401` without a valid bearer token. The auth strategy intercepts the `401`, calls the mock `POST /oauth/refresh` endpoint, and replays the original request with the new token. Success = `200` with data.

3. **Test Timeout** — Calls `GET /slow`, which sleeps for 12 seconds. The timeout strategy has a 10-second total budget, so this request fails with `PipelineTimeoutException` before the response arrives.

4. **Test Don't Retry (409)** — Calls `POST /charge`, which always returns `409` (duplicate). Uses `.dontRetryOn({409})` to skip retry and fail immediately.

The app also displays the current auth state (idle/refreshing/etc.) at the top via `pipeline.authStateStream`.

## How It Works

- **api_client.dart** configures a `ResiliencePipeline` with auth, retry, and timeout strategies.
- **_FakeHttpClientAdapter** intercepts HTTP calls and returns scripted responses without a real backend.
- **home_page.dart** provides a simple UI to invoke each scenario and display results.

All strategies coordinate — retry doesn't burn budget on auth-induced replays, and total timeout applies across all attempts.
