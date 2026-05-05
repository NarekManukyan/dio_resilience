import 'package:dio/dio.dart';

import 'conditions.dart';
import 'overrides.dart';
import 'token.dart';

/// Internal key used to stash [ResilienceOverrides] inside [Options.extra].
///
/// Dio's `RequestOptions.extra` is `Map<String, dynamic>`, so the key has
/// to be a String. The double-underscore prefix and package name make
/// collisions with other packages' `extra` keys vanishingly unlikely.
const _kResilienceKey = '__dio_resilience_overrides__';

/// Internal key used to stash a per-request rate-limit bucket key override
/// inside [Options.extra]. Read by [RateLimiterStrategy] during `onRequest`.
const String kRateLimitKeyOverride = '__dio_resilience_rate_limit_key__';

/// Internal key used to stash a per-request circuit key override
/// inside [Options.extra]. Read by [CircuitBreakerStrategy] during `onRequest`.
const String kCircuitKeyOverride = '_circuit_key_override';

/// Reads the per-request overrides from a [RequestOptions] or [Options], or
/// null if none were attached. Used internally by strategies and externally
/// by tests / advanced users that need to inspect what an `Options` chain
/// resolved to before the request fires.
ResilienceOverrides? overridesFor(Object request) {
  final extra = switch (request) {
    RequestOptions r => r.extra,
    Options o => o.extra,
    _ => throw ArgumentError(
        'overridesFor() expects Options or RequestOptions, got ${request.runtimeType}',
      ),
  };
  final v = extra?[_kResilienceKey];
  return v is ResilienceOverrides ? v : null;
}

/// Typed entry point for attaching resilience overrides to a Dio call.
extension ResilienceOptionsX on Options {
  /// Attach a full overrides bag to this request.
  Options resilience(ResilienceOverrides overrides) => copyWith(extra: {
        if (extra != null) ...extra!,
        _kResilienceKey: overrides,
      },);
}

/// Chainable single-purpose shortcuts for the common cases.
///
/// These are sugar over `Options().resilience(...)` so callers don't have
/// to construct a full [ResilienceOverrides] object for one flag.
extension ResilienceShortcuts on Options {
  Options noRetry() => _merge((current) => ResilienceOverrides(
        retry: RetryOverride.disabled,
        auth: current?.auth,
        timeout: current?.timeout,
        circuit: current?.circuit,
        rateLimit: current?.rateLimit,
        hedging: current?.hedging,
        fallback: current?.fallback,
      ),);

  Options noAuth() => _merge((current) => ResilienceOverrides(
        retry: current?.retry,
        auth: AuthOverride.disabled,
        timeout: current?.timeout,
        circuit: current?.circuit,
        rateLimit: current?.rateLimit,
        hedging: current?.hedging,
        fallback: current?.fallback,
      ),);

  Options withTimeout(Duration d) => _merge((current) => ResilienceOverrides(
        retry: current?.retry,
        auth: current?.auth,
        timeout: TimeoutOverride.total(d),
        circuit: current?.circuit,
        rateLimit: current?.rateLimit,
        hedging: current?.hedging,
        fallback: current?.fallback,
      ),);

  Options withAccount(AccountId id) => _merge((current) => ResilienceOverrides(
        retry: current?.retry,
        auth: AuthOverride.account(id),
        timeout: current?.timeout,
        circuit: current?.circuit,
        rateLimit: current?.rateLimit,
        hedging: current?.hedging,
        fallback: current?.fallback,
      ),);

  Options retryAttempts(int n) => _merge((current) => ResilienceOverrides(
        retry: RetryOverride.attempts(n),
        auth: current?.auth,
        timeout: current?.timeout,
        circuit: current?.circuit,
        rateLimit: current?.rateLimit,
        hedging: current?.hedging,
        fallback: current?.fallback,
      ),);

  Options dontRetryWhen(List<RetryCondition> conditions) =>
      _merge((current) => ResilienceOverrides(
            retry: RetryOverride.exceptWhen(conditions),
            auth: current?.auth,
            timeout: current?.timeout,
            circuit: current?.circuit,
            rateLimit: current?.rateLimit,
            hedging: current?.hedging,
            fallback: current?.fallback,
          ),);

  Options dontRetryOn(Set<int> statusCodes) =>
      dontRetryWhen([RetryCondition.statusIn(statusCodes)]);

  Options retryOnlyWhen(List<RetryCondition> conditions) =>
      _merge((current) => ResilienceOverrides(
            retry: RetryOverride.onlyWhen(conditions),
            auth: current?.auth,
            timeout: current?.timeout,
            circuit: current?.circuit,
            rateLimit: current?.rateLimit,
            hedging: current?.hedging,
            fallback: current?.fallback,
          ),);

  /// Disable rate limiting for this single request. Equivalent to setting
  /// `rateLimit: RateLimitOverride.disabled`.
  Options noRateLimit() => _merge((current) => ResilienceOverrides(
        retry: current?.retry,
        auth: current?.auth,
        timeout: current?.timeout,
        circuit: current?.circuit,
        rateLimit: RateLimitOverride.disabled,
        hedging: current?.hedging,
        fallback: current?.fallback,
      ),);

  /// Override the rate-limit bucket key for this request. The [key] replaces
  /// whatever the strategy's `keyExtractor` would have produced, allowing
  /// fine-grained per-endpoint or per-user bucketing at the call site.
  ///
  /// The key is stored in [Options.extra] under a well-known internal key;
  /// [RateLimiterStrategy] reads it during `onRequest`.
  Options rateLimitKey(String key) {
    return copyWith(extra: {
      if (extra != null) ...extra!,
      kRateLimitKeyOverride: key,
    },);
  }

  /// Disable hedging for this request.
  Options noHedging() => _merge((current) => ResilienceOverrides(
        retry: current?.retry,
        auth: current?.auth,
        timeout: current?.timeout,
        circuit: current?.circuit,
        rateLimit: current?.rateLimit,
        hedging: HedgingOverride.disabled,
        fallback: current?.fallback,
      ),);

  /// Enable or tune hedging for this request.
  ///
  /// [max] overrides the maximum number of parallel hedged branches.
  /// [delay] overrides the inter-hedge delay.
  /// Provide [max] or [delay] (or both). When both are provided the resulting
  /// override only stores one; chain two calls for independent overrides.
  Options hedge({int? max, Duration? delay}) {
    assert(
      max != null || delay != null,
      'hedge() requires at least one of max or delay',
    );
    return _merge((current) => ResilienceOverrides(
          retry: current?.retry,
          auth: current?.auth,
          timeout: current?.timeout,
          circuit: current?.circuit,
          rateLimit: current?.rateLimit,
          hedging: max != null
              ? HedgingOverride.maxParallel(max)
              : HedgingOverride.delay(delay!),
          fallback: current?.fallback,
        ),);
  }

  /// Disable the circuit breaker for this single request. Equivalent to
  /// setting `circuit: CircuitOverride.disabled`.
  Options noCircuit() => _merge((current) => ResilienceOverrides(
        retry: current?.retry,
        auth: current?.auth,
        timeout: current?.timeout,
        circuit: CircuitOverride.disabled,
        rateLimit: current?.rateLimit,
        hedging: current?.hedging,
        fallback: current?.fallback,
      ),);

  /// Pin this request to a specific circuit key, bypassing the strategy's
  /// default per-host keying. Useful when multiple paths on the same host
  /// should trip independently, or multiple hosts should share one circuit.
  Options circuitKey(String key) {
    return copyWith(extra: {
      if (extra != null) ...extra!,
      kCircuitKeyOverride: key,
    },);
  }

  /// Disable the fallback strategy for this single request.
  Options noFallback() => _merge((current) => ResilienceOverrides(
        retry: current?.retry,
        auth: current?.auth,
        timeout: current?.timeout,
        circuit: current?.circuit,
        rateLimit: current?.rateLimit,
        hedging: current?.hedging,
        fallback: FallbackOverride.disabled,
      ),);

  /// Substitute a canned [response] if this request fails.
  ///
  /// Equivalent to `FallbackOverride.response((_) => response)` but without
  /// needing to construct a full [ResilienceOverrides] bag.
  Options fallbackTo(Response<dynamic> response) =>
      _merge((current) => ResilienceOverrides(
            retry: current?.retry,
            auth: current?.auth,
            timeout: current?.timeout,
            circuit: current?.circuit,
            rateLimit: current?.rateLimit,
            hedging: current?.hedging,
            fallback: FallbackOverride.response((_) => response),
          ),);

  /// Override the fallback handler list for this request.
  Options fallbackHandlers(List<FallbackHandler> handlers) =>
      _merge((current) => ResilienceOverrides(
            retry: current?.retry,
            auth: current?.auth,
            timeout: current?.timeout,
            circuit: current?.circuit,
            rateLimit: current?.rateLimit,
            hedging: current?.hedging,
            fallback: FallbackOverride.handlers(handlers),
          ),);

  Options _merge(
    ResilienceOverrides Function(ResilienceOverrides? current) transform,
  ) {
    final current = extra?[_kResilienceKey];
    final currentTyped = current is ResilienceOverrides ? current : null;
    return resilience(transform(currentTyped));
  }
}
