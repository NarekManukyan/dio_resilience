import 'backoff.dart';
import 'conditions.dart';
import 'token.dart';

/// Per-request override bag passed via `Options().resilience(...)`.
///
/// All fields are nullable; only the strategies you set are overridden — the
/// rest fall through to the pipeline's default config.
class ResilienceOverrides {
  final RetryOverride? retry;
  final AuthOverride? auth;
  final TimeoutOverride? timeout;
  final CircuitOverride? circuit;
  final RateLimitOverride? rateLimit;
  final HedgingOverride? hedging;
  final FallbackOverride? fallback;

  const ResilienceOverrides({
    this.retry,
    this.auth,
    this.timeout,
    this.circuit,
    this.rateLimit,
    this.hedging,
    this.fallback,
  });
}

// ===================== Retry =====================

sealed class RetryOverride {
  const RetryOverride();

  /// Disable retry for this request.
  static const RetryOverride disabled = RetryDisabled();

  /// Use the pipeline default policy, but skip retry whenever any of
  /// [conditions] matches.
  const factory RetryOverride.exceptWhen(List<RetryCondition> conditions) =
      RetryExceptWhen;

  /// Replace the pipeline's predicate — retry ONLY when one of [conditions]
  /// matches.
  const factory RetryOverride.onlyWhen(List<RetryCondition> conditions) =
      RetryOnlyWhen;

  /// Tweak the retry budget without changing the predicate.
  const factory RetryOverride.attempts(int n) = RetryAttempts;

  /// Full custom policy.
  const factory RetryOverride.policy({
    int? maxAttempts,
    Backoff? backoff,
    List<RetryCondition>? retryOn,
    List<RetryCondition>? doNotRetryOn,
  }) = RetryPolicy;
}

/// "Do not retry this request" — see [RetryOverride.disabled].
final class RetryDisabled extends RetryOverride {
  const RetryDisabled();
}

final class RetryExceptWhen extends RetryOverride {
  final List<RetryCondition> conditions;
  const RetryExceptWhen(this.conditions);
}

final class RetryOnlyWhen extends RetryOverride {
  final List<RetryCondition> conditions;
  const RetryOnlyWhen(this.conditions);
}

final class RetryAttempts extends RetryOverride {
  final int attempts;
  const RetryAttempts(this.attempts);
}

final class RetryPolicy extends RetryOverride {
  final int? maxAttempts;
  final Backoff? backoff;
  final List<RetryCondition>? retryOn;
  final List<RetryCondition>? doNotRetryOn;
  const RetryPolicy({
    this.maxAttempts,
    this.backoff,
    this.retryOn,
    this.doNotRetryOn,
  });
}

// ===================== Auth =====================

sealed class AuthOverride {
  const AuthOverride();
  static const AuthOverride disabled = AuthDisabled();
  const factory AuthOverride.account(AccountId id) = AuthAccount;
}

/// "Skip auth header injection and refresh handling" —
/// see [AuthOverride.disabled].
final class AuthDisabled extends AuthOverride {
  const AuthDisabled();
}

final class AuthAccount extends AuthOverride {
  final AccountId account;
  const AuthAccount(this.account);
}

// ===================== Timeout =====================

sealed class TimeoutOverride {
  const TimeoutOverride();
  static const TimeoutOverride disabled = TimeoutDisabled();
  const factory TimeoutOverride.total(Duration d) = TimeoutTotal;
  const factory TimeoutOverride.perAttempt(Duration d) = TimeoutPerAttempt;
}

/// "Skip timeout enforcement for this request" —
/// see [TimeoutOverride.disabled].
final class TimeoutDisabled extends TimeoutOverride {
  const TimeoutDisabled();
}

final class TimeoutTotal extends TimeoutOverride {
  final Duration duration;
  const TimeoutTotal(this.duration);
}

final class TimeoutPerAttempt extends TimeoutOverride {
  final Duration duration;
  const TimeoutPerAttempt(this.duration);
}

// ===================== Circuit / RateLimit / Hedging / Fallback =====================
// These are stubs for v0.2; they exist so the override surface compiles and
// users writing forward-compatible code don't see TODOs.

sealed class CircuitOverride {
  const CircuitOverride();
  static const CircuitOverride disabled = CircuitDisabled();
}

final class CircuitDisabled extends CircuitOverride {
  const CircuitDisabled();
}

sealed class RateLimitOverride {
  const RateLimitOverride();
  static const RateLimitOverride disabled = RateLimitDisabled();
}

final class RateLimitDisabled extends RateLimitOverride {
  const RateLimitDisabled();
}

sealed class HedgingOverride {
  const HedgingOverride();
  static const HedgingOverride disabled = HedgingDisabled();
}

final class HedgingDisabled extends HedgingOverride {
  const HedgingDisabled();
}

sealed class FallbackOverride {
  const FallbackOverride();
  static const FallbackOverride disabled = FallbackDisabled();
}

final class FallbackDisabled extends FallbackOverride {
  const FallbackDisabled();
}
