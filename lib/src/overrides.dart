import 'package:dio/dio.dart';

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

// ===================== Circuit =====================

sealed class CircuitOverride {
  const CircuitOverride();

  /// Disable the circuit breaker for this request.
  static const CircuitOverride disabled = CircuitDisabled();

  /// Override the failure threshold for this request's circuit key.
  const factory CircuitOverride.threshold(int count) = CircuitThreshold;

  /// Override the cooldown duration for this request's circuit key.
  const factory CircuitOverride.cooldown(Duration d) = CircuitCooldown;
}

/// "Skip circuit breaker for this request" — see [CircuitOverride.disabled].
final class CircuitDisabled extends CircuitOverride {
  const CircuitDisabled();
}

/// Override failure threshold — see [CircuitOverride.threshold].
final class CircuitThreshold extends CircuitOverride {
  final int count;
  const CircuitThreshold(this.count);
}

/// Override cooldown duration — see [CircuitOverride.cooldown].
final class CircuitCooldown extends CircuitOverride {
  final Duration duration;
  const CircuitCooldown(this.duration);
}

// ===================== RateLimit =====================

sealed class RateLimitOverride {
  const RateLimitOverride();

  /// Disable rate limiting entirely for this request.
  static const RateLimitOverride disabled = RateLimitDisabled();

  /// Skip rate-limit token acquisition for this request, but do not disable
  /// the strategy globally. Useful for health-check or admin endpoints that
  /// must always pass through regardless of the current bucket state.
  static const RateLimitOverride bypass = RateLimitBypassed();
}

/// "Disable rate limiting for this request" — see [RateLimitOverride.disabled].
final class RateLimitDisabled extends RateLimitOverride {
  const RateLimitDisabled();
}

/// "Bypass token acquisition for this request" — see [RateLimitOverride.bypass].
final class RateLimitBypassed extends RateLimitOverride {
  const RateLimitBypassed();
}

// ===================== Hedging =====================

sealed class HedgingOverride {
  const HedgingOverride();

  /// Disable hedging for this request.
  static const HedgingOverride disabled = HedgingDisabled();

  /// Override the maximum number of parallel hedged requests for this request.
  const factory HedgingOverride.maxParallel(int n) = HedgingMaxParallel;

  /// Override the delay before launching each additional hedged request.
  const factory HedgingOverride.delay(Duration d) = HedgingDelay;
}

final class HedgingDisabled extends HedgingOverride {
  const HedgingDisabled();
}

final class HedgingMaxParallel extends HedgingOverride {
  final int n;
  const HedgingMaxParallel(this.n);
}

final class HedgingDelay extends HedgingOverride {
  final Duration d;
  const HedgingDelay(this.d);
}

// ===================== Fallback =====================

/// A handler that the fallback strategy walks in order when a request fails.
///
/// Three concrete variants are available via the sealed-class factories:
///
/// - [FallbackHandler.response] — return a canned [Response] immediately.
/// - [FallbackHandler.endpoint] — re-fire the request to an alternate URL.
/// - [FallbackHandler.predicate] — guard another handler behind a condition.
sealed class FallbackHandler {
  const FallbackHandler();

  /// Return a canned response constructed from the failing [DioException] and
  /// its [RequestOptions].
  ///
  /// Example:
  /// ```dart
  /// FallbackHandler.response((err, opts) => Response(
  ///   requestOptions: opts,
  ///   statusCode: 200,
  ///   data: {'cached': true},
  /// ))
  /// ```
  const factory FallbackHandler.response(
    Response<dynamic> Function(DioException, RequestOptions) builder,
  ) = ResponseFallbackHandler;

  /// Re-fire the original request to [url] (optionally changing [method]).
  ///
  /// The re-fired request travels through the same Dio instance so other
  /// pipeline strategies (auth, retry, timeout) still apply. A meta flag
  /// `fallback_in_flight` is set on the context before the re-fire so that
  /// the fallback strategy skips itself for the secondary request, preventing
  /// infinite recursion.
  ///
  /// Headers, query parameters, data, and extra options are inherited from the
  /// original request unless overridden by [method].
  const factory FallbackHandler.endpoint(
    String url, {
    String? method,
  }) = EndpointFallbackHandler;

  /// Wrap another [handler] behind a [predicate].
  ///
  /// The inner [handler] is only attempted when [predicate] returns `true` for
  /// the current [DioException]. If the predicate returns `false` the pipeline
  /// moves on to the next handler in the list.
  const factory FallbackHandler.predicate(
    bool Function(DioException) predicate,
    FallbackHandler handler,
  ) = PredicateFallbackHandler;
}

/// "Return a canned response" — see [FallbackHandler.response].
final class ResponseFallbackHandler extends FallbackHandler {
  /// Builds the response to substitute for the failed request.
  final Response<dynamic> Function(DioException, RequestOptions) builder;

  const ResponseFallbackHandler(this.builder);
}

/// "Re-fire to an alternate URL" — see [FallbackHandler.endpoint].
final class EndpointFallbackHandler extends FallbackHandler {
  /// The alternate URL to send the request to.
  final String url;

  /// Optional HTTP method override; if null, the original method is preserved.
  final String? method;

  const EndpointFallbackHandler(this.url, {this.method});
}

/// "Conditional handler" — see [FallbackHandler.predicate].
final class PredicateFallbackHandler extends FallbackHandler {
  /// Condition that must hold for the inner [handler] to be attempted.
  final bool Function(DioException) predicate;

  /// The inner handler to delegate to when [predicate] is `true`.
  final FallbackHandler handler;

  const PredicateFallbackHandler(this.predicate, this.handler);
}

/// Per-request override for the fallback strategy.
sealed class FallbackOverride {
  const FallbackOverride();

  /// Disable fallback for this request.
  static const FallbackOverride disabled = FallbackDisabled();

  /// Substitute a canned response built from the failing [DioException].
  ///
  /// The [builder] receives the exception and must return the response to
  /// resolve the request with.
  factory FallbackOverride.response(
    Response<dynamic> Function(DioException) builder,
  ) = FallbackResponse;

  /// Replace the pipeline-level handler list for this request.
  factory FallbackOverride.handlers(List<FallbackHandler> handlers) =
      FallbackHandlers;
}

/// "Disable fallback for this request" — see [FallbackOverride.disabled].
final class FallbackDisabled extends FallbackOverride {
  const FallbackDisabled();
}

/// "Return a canned response" — see [FallbackOverride.response].
final class FallbackResponse extends FallbackOverride {
  /// Builds the substitute response from the failing exception.
  final Response<dynamic> Function(DioException) builder;

  const FallbackResponse(this.builder);
}

/// "Use these handlers instead of the pipeline default" —
/// see [FallbackOverride.handlers].
final class FallbackHandlers extends FallbackOverride {
  /// Custom handler list for this request.
  final List<FallbackHandler> handlers;

  const FallbackHandlers(this.handlers);
}
