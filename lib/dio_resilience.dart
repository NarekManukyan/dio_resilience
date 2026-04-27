/// dio_resilience — a unified Dio interceptor bundling retry, timeout,
/// auth/token-refresh, and (in v0.2) circuit breaker, rate limiter,
/// hedging and fallback strategies that coordinate via a shared pipeline
/// context.
///
/// See README.md for an overview and ResiliencePipeline for the entry point.
library;

export 'src/backoff.dart';
export 'src/conditions.dart';
export 'src/exceptions.dart';
export 'src/options_extension.dart';
export 'src/overrides.dart';
export 'src/pipeline.dart';
export 'src/pipeline_context.dart';
export 'src/storage/memory_token_storage.dart';
export 'src/strategies/auth_strategy.dart';
export 'src/strategies/retry_strategy.dart';
export 'src/strategies/timeout_strategy.dart';
export 'src/strategy.dart';
export 'src/token.dart';
