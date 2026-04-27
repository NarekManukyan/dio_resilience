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

/// Reads the per-request overrides from a [RequestOptions], or null if none
/// were attached. Used internally by strategies.
ResilienceOverrides? overridesFor(RequestOptions request) {
  final v = request.extra[_kResilienceKey];
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

  Options _merge(
    ResilienceOverrides Function(ResilienceOverrides? current) transform,
  ) {
    final current = extra?[_kResilienceKey];
    final currentTyped = current is ResilienceOverrides ? current : null;
    return resilience(transform(currentTyped));
  }
}
