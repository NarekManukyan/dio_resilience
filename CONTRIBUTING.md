# Contributing

## Setup

Clone the repo and get dependencies:

```bash
dart pub get
```

## Running tests

```bash
dart test
```

Tests live in `test/` and cover auth, retry, timeout, and override behavior.

## Running analysis

```bash
dart analyze
```

Ensure no warnings or errors. The project follows the style defined in `analysis_options.yaml`.

## Code style

Follow the analysis options and Dart conventions:

- Use single quotes in strings (unless interpolation requires double quotes).
- Format with `dart format` (automatic via pre-commit if configured).
- Document public APIs with doc comments (`///`).
- Keep lines under 80 characters where practical.

## Adding a new strategy

To add a new resilience strategy (e.g., circuit breaker in v0.2):

1. **Create the strategy file** in `lib/src/strategies/` implementing `ResilienceStrategy` with `onRequest()`, `onResponse()`, and `onError()` methods.
2. **Add to the builder** in `lib/src/pipeline.dart`: add a field and method to `ResiliencePipelineBuilder` for configuration.
3. **Create override types** in `lib/src/overrides.dart`: add a sealed class for per-request overrides (e.g., `CircuitOverride`).
4. **Add to shortcuts** in `lib/src/options_extension.dart` if there are common per-call patterns.
5. **Write tests** in `test/` covering normal flow, error paths, and interactions with other strategies.

Export the new strategy from `lib/dio_resilience.dart`.
