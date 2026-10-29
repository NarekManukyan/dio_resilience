# dio_resilience example

A tour of every `dio_resilience` 0.3.0 strategy, running against a
scriptable fake backend so it works fully offline and deterministically —
there is no real network call anywhere in this app.

## Running it

```sh
cd example
flutter pub get
flutter run
```

Or drive it hands-free, walking every screen and pressing every "Run"
button on its own (used to record the README's screenshots/GIFs):

```sh
flutter run --dart-define=DEMO_AUTOPLAY=true
```

## What each screen shows

- **Retry & backoff** — exponential-jitter backoff retrying a `503` twice
  then succeeding; a `POST` that is *not* retried (idempotent methods only);
  a server `Retry-After` honoured and capped by `maxRetryAfter`; retries
  exhausted into an `AllAttemptsExhaustedException` that still reads like
  the last failure.
- **Auth & token refresh** — five concurrent `401`s sharing a single
  in-flight refresh; a refresh that fails terminally and reports an
  `AuthRejection`; "no-refresh" mode where a `401` reaches the caller
  unchanged; two accounts kept apart with `withAccount()` and a
  `MemoryAccountTokenStorage`.
- **Timeout** — a total budget cutting off a still-in-flight attempt
  (`PipelineTimeoutException`), and a per-attempt cap that times out once
  and succeeds on the retried attempt.
- **Circuit breaker** — closed → open → half-open → closed, with a live
  state indicator driven by `CircuitStateChangedEvent`. Adjust the failure
  threshold, cooldown and half-open probe count and watch it trip.
- **Rate limiter** — token bucket vs. sliding window, `wait` vs. `fail`
  mode. Fires several requests at once and times when each one actually
  gets through.
- **Hedging** — races a slow primary request against a hedge branch fired
  after a delay; shows both branches, the winner, and the cancelled loser.
- **Challenge** — a mock CAPTCHA dialog standing in for a real
  challenge-response flow: a `200` whose body demands a challenge, a `428`
  challenge error, and a solver that fails on purpose
  (`ChallengeFailedException`).
- **Fallback** — a canned response after retries are exhausted, after the
  circuit opens, and an alternate-endpoint re-fire that succeeds.
- **Per-request overrides** — `Options().noRetry()`, `.withTimeout(...)`
  and the const `ResilienceExtras.noRetry` map, all against the same
  pipeline.
- **Cancellation** — cancelling a request mid-backoff; the pipeline never
  sends another attempt.

Every screen has:

- a plain-language explanation of the strategy;
- knobs for the numbers that matter (attempt counts, thresholds, delays,
  rates);
- a "Run" button and the outcome (response or typed exception);
- a live event log fed by `.onEvent(...)` (`ReplayEvent`, `RecoveredEvent`,
  `GaveUpEvent`, `CircuitStateChangedEvent`);
- a stats panel: logical calls vs. requests actually sent on the wire,
  retries, refreshes, fallbacks used, failures by exception type, and
  p50/p95 latency.

## Structure

```
lib/
  main.dart                 MaterialApp + routes
  autoplay.dart             --dart-define=DEMO_AUTOPLAY driver
  fake/fake_adapter.dart    scriptable HttpClientAdapter (latency, status
                            sequences, Retry-After, cancellation, receive
                            timeout)
  core/                     EventLog, DemoStats, the shared scenario runner
  widgets/                  ScenarioScaffold, knobs, log/stats/outcome panels
  scenarios/                one screen per strategy, plus the overview
```

## Tests

```sh
flutter test
```

`test/fake_adapter_test.dart` runs the retry strategy end-to-end against the
fake adapter (no UI); `test/retry_screen_test.dart` drives the retry screen
through the widget tree.
