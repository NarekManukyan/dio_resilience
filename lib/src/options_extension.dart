import 'package:dio/dio.dart';

import 'conditions.dart';
import 'overrides.dart';
import 'token.dart';

/// Key under which a [ResilienceOverrides] bag is stored in
/// [Options.extra]. Public so a const extras map (Retrofit's `@Extras`) can
/// carry a bag: `{kResilienceOverridesKey: ResilienceOverrides(...)}`.
const String kResilienceOverridesKey = '__dio_resilience_overrides__';

/// Key for a per-request rate-limit bucket key in [Options.extra]. Read by
/// [RateLimiterStrategy] during `onRequest`.
const String kRateLimitKeyOverride = '__dio_resilience_rate_limit_key__';

/// Key for a per-request circuit key in [Options.extra]. Read by
/// [CircuitBreakerStrategy].
const String kCircuitKeyOverride = '__dio_resilience_circuit_key__';

/// Flag in [Options.extra] marking a call that brings its own credentials,
/// or none: the auth strategy neither injects a token nor refreshes on a
/// `401`. Kept as `isRefreshRequest` so 0.1/0.2 call sites keep working.
const String kSkipAuthKey = 'isRefreshRequest';

/// Const `extra` maps that switch one strategy off for a request.
///
/// Unlike the `Options` shortcuts these are plain const maps, so they work
/// where only a const map fits (Retrofit's `@Extras`, a provider's `extras:`
/// parameter) and combine by spreading:
///
/// ```dart
/// @Extras({...ResilienceExtras.noRetry, ...ResilienceExtras.noAuth})
/// ```
///
/// A field set in a [ResilienceOverrides] bag on the same request wins over
/// the flag.
abstract final class ResilienceExtras {
  static const String noRetryKey = '__dio_resilience_no_retry__';
  static const String noTimeoutKey = '__dio_resilience_no_timeout__';
  static const String noCircuitKey = '__dio_resilience_no_circuit__';
  static const String noRateLimitKey = '__dio_resilience_no_rate_limit__';
  static const String noHedgingKey = '__dio_resilience_no_hedging__';
  static const String noFallbackKey = '__dio_resilience_no_fallback__';
  static const String noChallengeKey = '__dio_resilience_no_challenge__';

  static const Map<String, Object> noRetry = {noRetryKey: true};

  /// Skip token injection and refresh: the call carries its own
  /// credentials, so a `401` is its own answer, not an expired session.
  static const Map<String, Object> noAuth = {kSkipAuthKey: true};
  static const Map<String, Object> noTimeout = {noTimeoutKey: true};
  static const Map<String, Object> noCircuit = {noCircuitKey: true};
  static const Map<String, Object> noRateLimit = {noRateLimitKey: true};
  static const Map<String, Object> noHedging = {noHedgingKey: true};
  static const Map<String, Object> noFallback = {noFallbackKey: true};
  static const Map<String, Object> noChallenge = {noChallengeKey: true};
}

/// Reads the per-request overrides from a [RequestOptions] or [Options]: the
/// [ResilienceOverrides] bag, with any [ResilienceExtras] flag filling a
/// field the bag leaves null. Null when neither is attached. Used internally
/// by strategies and externally by tests / advanced users that need to
/// inspect what an `Options` chain resolved to before the request fires.
ResilienceOverrides? overridesFor(Object request) {
  final extra = switch (request) {
    RequestOptions r => r.extra,
    Options o => o.extra,
    _ => throw ArgumentError(
        'overridesFor() expects Options or RequestOptions, got ${request.runtimeType}',
      ),
  };
  if (extra == null) return null;
  final v = extra[kResilienceOverridesKey];
  final bag = v is ResilienceOverrides ? v : null;
  bool flag(String key) => extra[key] == true;

  final fromFlags = ResilienceOverrides(
    retry: flag(ResilienceExtras.noRetryKey) ? RetryOverride.disabled : null,
    auth: flag(kSkipAuthKey) ? AuthOverride.disabled : null,
    timeout:
        flag(ResilienceExtras.noTimeoutKey) ? TimeoutOverride.disabled : null,
    circuit:
        flag(ResilienceExtras.noCircuitKey) ? CircuitOverride.disabled : null,
    rateLimit: flag(ResilienceExtras.noRateLimitKey)
        ? RateLimitOverride.disabled
        : null,
    hedging:
        flag(ResilienceExtras.noHedgingKey) ? HedgingOverride.disabled : null,
    fallback:
        flag(ResilienceExtras.noFallbackKey) ? FallbackOverride.disabled : null,
    challenge: flag(ResilienceExtras.noChallengeKey)
        ? ChallengeOverride.disabled
        : null,
  );
  if (fromFlags.isEmpty) return bag;
  if (bag == null) return fromFlags;
  return ResilienceOverrides(
    retry: bag.retry ?? fromFlags.retry,
    auth: bag.auth ?? fromFlags.auth,
    timeout: bag.timeout ?? fromFlags.timeout,
    circuit: bag.circuit ?? fromFlags.circuit,
    rateLimit: bag.rateLimit ?? fromFlags.rateLimit,
    hedging: bag.hedging ?? fromFlags.hedging,
    fallback: bag.fallback ?? fromFlags.fallback,
    challenge: bag.challenge ?? fromFlags.challenge,
  );
}

/// Typed entry point for attaching resilience overrides to a Dio call.
extension ResilienceOptionsX on Options {
  /// Attach a full overrides bag to this request.
  Options resilience(ResilienceOverrides overrides) => copyWith(
        extra: {
          if (extra != null) ...extra!,
          kResilienceOverridesKey: overrides,
        },
      );
}

/// Chainable single-purpose shortcuts for the common cases.
///
/// These are sugar over `Options().resilience(...)` so callers don't have
/// to construct a full [ResilienceOverrides] object for one flag. Each one
/// keeps the overrides earlier calls in the chain set.
extension ResilienceShortcuts on Options {
  Options noRetry() => _merge((o) => o.copyWith(retry: RetryOverride.disabled));

  Options noAuth() => _merge((o) => o.copyWith(auth: AuthOverride.disabled));

  Options withTimeout(Duration d) =>
      _merge((o) => o.copyWith(timeout: TimeoutOverride.total(d)));

  Options withAccount(AccountId id) =>
      _merge((o) => o.copyWith(auth: AuthOverride.account(id)));

  Options retryAttempts(int n) =>
      _merge((o) => o.copyWith(retry: RetryOverride.attempts(n)));

  Options dontRetryWhen(List<RetryCondition> conditions) =>
      _merge((o) => o.copyWith(retry: RetryOverride.exceptWhen(conditions)));

  Options dontRetryOn(Set<int> statusCodes) =>
      dontRetryWhen([RetryCondition.statusIn(statusCodes)]);

  Options retryOnlyWhen(List<RetryCondition> conditions) =>
      _merge((o) => o.copyWith(retry: RetryOverride.onlyWhen(conditions)));

  /// Disable rate limiting for this single request. Equivalent to setting
  /// `rateLimit: RateLimitOverride.disabled`.
  Options noRateLimit() =>
      _merge((o) => o.copyWith(rateLimit: RateLimitOverride.disabled));

  /// Override the rate-limit bucket key for this request. The [key] replaces
  /// whatever the strategy's `keyExtractor` would have produced, allowing
  /// fine-grained per-endpoint or per-user bucketing at the call site.
  ///
  /// The key is stored in [Options.extra] under [kRateLimitKeyOverride];
  /// [RateLimiterStrategy] reads it during `onRequest`.
  Options rateLimitKey(String key) => copyWith(
        extra: {
          if (extra != null) ...extra!,
          kRateLimitKeyOverride: key,
        },
      );

  /// Disable hedging for this request.
  Options noHedging() =>
      _merge((o) => o.copyWith(hedging: HedgingOverride.disabled));

  /// Enable or tune hedging for this request.
  ///
  /// [max] overrides the maximum number of parallel hedged branches.
  /// [delay] overrides the inter-hedge delay. Provide one of them; when both
  /// are provided only [max] is kept.
  Options hedge({int? max, Duration? delay}) {
    assert(
      max != null || delay != null,
      'hedge() requires at least one of max or delay',
    );
    return _merge(
      (o) => o.copyWith(
        hedging: max != null
            ? HedgingOverride.maxParallel(max)
            : HedgingOverride.delay(delay!),
      ),
    );
  }

  /// Disable the circuit breaker for this single request. Equivalent to
  /// setting `circuit: CircuitOverride.disabled`.
  Options noCircuit() =>
      _merge((o) => o.copyWith(circuit: CircuitOverride.disabled));

  /// Disable the challenge strategy for this single request. Matched signals
  /// fall through to retry/fallback as if no challenge strategy were
  /// configured. Equivalent to setting `challenge: ChallengeOverride.disabled`.
  Options noChallenge() =>
      _merge((o) => o.copyWith(challenge: ChallengeOverride.disabled));

  /// Pin this request to a specific circuit key, bypassing the strategy's
  /// default per-host keying and its `keyExtractor`. Useful when multiple
  /// paths on the same host should trip independently, or multiple hosts
  /// should share one circuit.
  Options circuitKey(String key) => copyWith(
        extra: {
          if (extra != null) ...extra!,
          kCircuitKeyOverride: key,
        },
      );

  /// Disable the fallback strategy for this single request.
  Options noFallback() =>
      _merge((o) => o.copyWith(fallback: FallbackOverride.disabled));

  /// Substitute a canned [response] if this request fails.
  ///
  /// Equivalent to `FallbackOverride.response((_) => response)` but without
  /// needing to construct a full [ResilienceOverrides] bag.
  Options fallbackTo(Response<dynamic> response) => _merge(
        (o) => o.copyWith(fallback: FallbackOverride.response((_) => response)),
      );

  /// Override the fallback handler list for this request.
  Options fallbackHandlers(List<FallbackHandler> handlers) => _merge(
        (o) => o.copyWith(fallback: FallbackOverride.handlers(handlers)),
      );

  Options _merge(
    ResilienceOverrides Function(ResilienceOverrides current) transform,
  ) {
    final current = extra?[kResilienceOverridesKey];
    return resilience(
      transform(
        current is ResilienceOverrides ? current : const ResilienceOverrides(),
      ),
    );
  }
}
