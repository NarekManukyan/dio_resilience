import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../options_extension.dart';
import '../overrides.dart';
import '../pipeline_context.dart';
import '../strategy.dart';

// ---------------------------------------------------------------------------
// Circuit state machine
// ---------------------------------------------------------------------------

/// Context key holding the circuit whose half-open probe slot a request
/// took, until the probe has a result.
const String _kProbeKey = '_circuit_key';

/// The current state of a single circuit keyed by host (or custom key).
enum CircuitPhase { closed, open, halfOpen }

/// Mutable runtime state for one circuit key.
final class _CircuitState {
  CircuitPhase phase = CircuitPhase.closed;

  /// Timestamps (from [DateTime.now]) of failures inside the rolling window.
  final List<DateTime> _failureTimestamps = [];

  /// When the circuit was tripped to open. Null while closed.
  DateTime? openedAt;

  /// Number of half-open probes that have been dispatched and are still
  /// in-flight or have already succeeded / failed this half-open window.
  int probesDispatched = 0;

  /// Number of consecutive successes in half-open state.
  int halfOpenSuccesses = 0;

  // ----- Helpers -----------------------------------------------------------

  /// Prune failures outside [window] from the rolling window.
  void pruneWindow(Duration window, DateTime now) {
    final cutoff = now.subtract(window);
    _failureTimestamps.removeWhere((t) => t.isBefore(cutoff));
  }

  /// Record a failure timestamp.
  void recordFailure(DateTime now) => _failureTimestamps.add(now);

  /// Number of failures still inside the rolling window.
  int failureCount(Duration window, DateTime now) {
    pruneWindow(window, now);
    return _failureTimestamps.length;
  }

  /// Transition to open state.
  void trip(DateTime now) {
    phase = CircuitPhase.open;
    openedAt = now;
    probesDispatched = 0;
    halfOpenSuccesses = 0;
  }

  /// Transition to half-open state.
  void enterHalfOpen() {
    phase = CircuitPhase.halfOpen;
    probesDispatched = 0;
    halfOpenSuccesses = 0;
  }

  /// Transition to closed state and reset all counters.
  void close() {
    phase = CircuitPhase.closed;
    openedAt = null;
    probesDispatched = 0;
    halfOpenSuccesses = 0;
    _failureTimestamps.clear();
  }
}

// ---------------------------------------------------------------------------
// CircuitBreakerStrategy
// ---------------------------------------------------------------------------

/// Circuit breaker strategy implementing the closed / open / half-open state
/// machine with a rolling failure window.
///
/// ### State transitions
///
/// ```
/// CLOSED ──(≥ failureThreshold failures in window)──► OPEN
/// OPEN   ──(cooldown elapsed)──────────────────────► HALF-OPEN
/// HALF-OPEN ──(halfOpenProbes successes)────────────► CLOSED
/// HALF-OPEN ──(any failure)─────────────────────────► OPEN
/// ```
///
/// ### Integration
///
/// Add via the builder:
/// ```dart
/// ResiliencePipeline.builder()
///   .circuitBreaker(failureThreshold: 5, cooldown: Duration(seconds: 30))
///   .retry(maxAttempts: 3)
///   .build()
///   .attachTo(dio);
/// ```
///
/// The circuit breaker sits *before* the retry strategy in the pipeline, so
/// a short-circuit `FailDecision` terminates the error chain before retry
/// gets a chance to replay the request.
final class CircuitBreakerStrategy extends ResilienceStrategy {
  @override
  String get name => 'circuit_breaker';

  /// Number of failures inside [windowDuration] that trip the circuit to open.
  final int failureThreshold;

  /// Duration of the rolling failure counting window.
  final Duration windowDuration;

  /// How long to stay in the open state before allowing a probe.
  final Duration cooldown;

  /// Number of consecutive successful probes required to close the circuit
  /// from half-open.
  final int halfOpenProbes;

  /// Custom key extractor. By default the circuit is keyed per-host.
  final String Function(RequestOptions)? keyExtractor;

  /// Injectable clock. Defaults to [DateTime.now]. Override in tests to
  /// simulate time without sleeping.
  final DateTime Function() now;

  /// Called when a circuit changes phase.
  final void Function(String key, CircuitPhase from, CircuitPhase to)?
      onStateChange;

  /// In-memory per-key circuit state.
  final Map<String, _CircuitState> _states = {};

  /// Creates a [CircuitBreakerStrategy].
  ///
  /// - [failureThreshold]: how many failures in [windowDuration] trip the
  ///   circuit (default 5).
  /// - [windowDuration]: the rolling window for failure counting
  ///   (default 60 s).
  /// - [cooldown]: how long the circuit stays open before a probe is allowed
  ///   (default 30 s).
  /// - [halfOpenProbes]: consecutive successes needed to re-close the circuit
  ///   (default 1).
  /// - [keyExtractor]: if provided, called on every request to produce the
  ///   circuit key. By default the key is the request's host (and port, if
  ///   non-standard).
  /// - [now]: injectable clock used for all time checks. Pass a custom
  ///   function in tests to control time without sleeping.
  /// - [onStateChange]: called on every phase change.
  CircuitBreakerStrategy({
    this.failureThreshold = 5,
    this.windowDuration = const Duration(seconds: 60),
    this.cooldown = const Duration(seconds: 30),
    this.halfOpenProbes = 1,
    this.keyExtractor,
    this.onStateChange,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  // ----- ResilienceStrategy hooks ------------------------------------------

  @override
  Future<void> onRequest(PipelineContext ctx) async {
    // Per-request override: if disabled, skip all circuit logic.
    if (_isDisabledFor(ctx.request)) return;

    final key = _keyFor(ctx.request);
    final state = _stateFor(key);
    final timestamp = now();

    switch (state.phase) {
      case CircuitPhase.closed:
        // Happy path — let the request through.
        return;

      case CircuitPhase.open:
        final elapsed = timestamp.difference(state.openedAt!);
        if (elapsed >= _cooldownFor(ctx.request)) {
          // Cooldown has passed: allow one probe batch by entering half-open.
          _move(key, state, state.enterHalfOpen);
          state.probesDispatched++;
          // Store the key on the context so onResponse/onError can look it up
          // without re-computing.
          ctx.meta[_kProbeKey] = key;
          return;
        }
        // Still open — short-circuit.
        throw CircuitOpenException(
          requestOptions: ctx.request,
          circuitName: key,
          stackTrace: StackTrace.current,
        );

      case CircuitPhase.halfOpen:
        // A replay of a probe (a retry, a refreshed token, a solved
        // challenge) is still that probe, not a new one.
        if (ctx.meta[_kProbeKey] == key) return;
        if (state.probesDispatched < halfOpenProbes) {
          state.probesDispatched++;
          ctx.meta[_kProbeKey] = key;
          return;
        }
        // Probe budget exhausted — reject until we close or re-open.
        throw CircuitOpenException(
          requestOptions: ctx.request,
          circuitName: key,
          stackTrace: StackTrace.current,
        );
    }
  }

  @override
  Future<void> onResponse(
    PipelineContext ctx,
    Response<dynamic> response,
  ) async {
    if (_isDisabledFor(ctx.request)) return;
    // A challenge-shaped response is no sign of health either.
    if (ctx.isChallengeError) return;

    final key = _keyFor(ctx.request);
    final state = _stateFor(key);
    // This request's probe (if it was one) has its result.
    ctx.meta.remove(_kProbeKey);

    switch (state.phase) {
      case CircuitPhase.halfOpen:
        state.halfOpenSuccesses++;
        if (state.halfOpenSuccesses >= halfOpenProbes) {
          _move(key, state, state.close);
        }
      case CircuitPhase.closed:
        // Reset the rolling window on success so transient spikes don't
        // accumulate infinitely.
        state._failureTimestamps.clear();
      case CircuitPhase.open:
        // Shouldn't normally receive a response in open state, but be safe.
        break;
    }
  }

  @override
  Future<StrategyDecision?> onError(
    PipelineContext ctx,
    DioException error,
  ) async {
    // Don't make decisions — just record the failure and let retry handle
    // replay logic. Return null so the pipeline continues to the next strategy.
    if (_isDisabledFor(ctx.request)) return null;

    // A cancelled request says nothing about the backend, and neither do
    // the pipeline's own decisions (circuit open, rate limit, exhausted
    // retries): the attempts behind them were counted as they failed, or
    // never reached the backend. An attempt the deadline cut short did
    // reach it, and it didn't answer in time: that one counts. A half-open
    // probe that ends without a result gives its slot back in [onEnd].
    final cutByDeadline =
        error is PipelineTimeoutException && error.cutAttempt;
    if (!cutByDeadline &&
        (error.type == DioExceptionType.cancel ||
            error is DioResilienceException ||
            error.error is DioResilienceException)) {
      return null;
    }

    // Do not count challenge-shaped responses as failures. The server is
    // instructing the client to solve a proof (CAPTCHA / MFA / attestation)
    // and replay; this is not backend unavailability.
    if (ctx.isChallengeError) return null;

    final key = _keyFor(ctx.request);
    final state = _stateFor(key);
    final timestamp = now();
    // This request's probe (if it was one) has its result.
    ctx.meta.remove(_kProbeKey);

    switch (state.phase) {
      case CircuitPhase.closed:
        state.recordFailure(timestamp);
        final count = state.failureCount(windowDuration, timestamp);
        if (count >= _thresholdFor(ctx.request)) {
          _move(key, state, () => state.trip(timestamp));
        }
      case CircuitPhase.halfOpen:
        // Any failure in half-open → reopen.
        _move(key, state, () => state.trip(timestamp));
      case CircuitPhase.open:
        // Should not normally reach here (request rejected in onRequest),
        // but record anyway.
        state.recordFailure(timestamp);
    }

    return null;
  }

  /// A half-open probe that ended without a result (cancelled, a failed
  /// challenge, a pipeline decision) gives its slot back, or the circuit
  /// would wait for that result forever.
  @override
  void onEnd(PipelineContext ctx) => _releaseProbe(ctx);

  // ----- Internal helpers --------------------------------------------------

  /// Retrieve (or lazily create) the state object for [key].
  _CircuitState _stateFor(String key) =>
      _states.putIfAbsent(key, _CircuitState.new);

  /// [failureThreshold], or this request's `CircuitOverride.threshold`.
  int _thresholdFor(RequestOptions request) =>
      switch (overridesFor(request)?.circuit) {
        CircuitThreshold(:final count) => count,
        _ => failureThreshold,
      };

  /// [cooldown], or this request's `CircuitOverride.cooldown`.
  Duration _cooldownFor(RequestOptions request) =>
      switch (overridesFor(request)?.circuit) {
        CircuitCooldown(:final duration) => duration,
        _ => cooldown,
      };

  /// Gives back the half-open probe slot [ctx] took, if it took one.
  void _releaseProbe(PipelineContext ctx) {
    final key = ctx.meta.remove(_kProbeKey);
    if (key is! String) return;
    final state = _states[key];
    if (state != null &&
        state.phase == CircuitPhase.halfOpen &&
        state.probesDispatched > 0) {
      state.probesDispatched--;
    }
  }

  /// Runs [transition] on [state] and reports the phase change, if any.
  void _move(String key, _CircuitState state, void Function() transition) {
    final from = state.phase;
    transition();
    if (state.phase != from) onStateChange?.call(key, from, state.phase);
  }

  /// Compute the circuit key for a request: the per-request `circuitKey`,
  /// then [keyExtractor], then host[:port].
  String _keyFor(RequestOptions request) {
    final perRequest = request.extra[kCircuitKeyOverride];
    if (perRequest is String && perRequest.isNotEmpty) return perRequest;

    if (keyExtractor != null) return keyExtractor!(request);

    // Default: host[:port] — keeps circuits isolated per back-end service.
    final uri = Uri.tryParse(request.uri.toString());
    if (uri == null) return request.path;
    final host = uri.host;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '$host$port';
  }

  /// Returns true if the circuit strategy is disabled for this request via
  /// a [CircuitOverride.disabled] per-request override.
  bool _isDisabledFor(RequestOptions request) {
    final override = overridesFor(request)?.circuit;
    return override is CircuitDisabled;
  }

  /// Returns the current phase for [key] — exposed for testing convenience.
  CircuitPhase phaseFor(String key) =>
      _states[key]?.phase ?? CircuitPhase.closed;

  /// Resets all circuit state — useful in tests.
  void resetAll() => _states.clear();
}
