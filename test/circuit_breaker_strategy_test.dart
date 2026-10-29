import 'package:dio/dio.dart';
import 'package:dio_resilience/src/exceptions.dart';
import 'package:dio_resilience/src/options_extension.dart';
import 'package:dio_resilience/src/overrides.dart';
import 'package:dio_resilience/src/pipeline_context.dart';
import 'package:dio_resilience/src/strategy.dart';
import 'package:dio_resilience/src/strategies/circuit_breaker_strategy.dart';
import 'package:dio_resilience/src/strategies/retry_strategy.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a [RequestOptions] for the given URL (default: api.example.com).
RequestOptions _req([String url = 'https://api.example.com/data']) =>
    RequestOptions(path: url);

/// Builds a network-error [DioException].
DioException _networkError(RequestOptions req) => DioException(
      requestOptions: req,
      type: DioExceptionType.connectionError,
      message: 'Network error',
    );

/// Drive [n] failures through [strategy] for [req], recording onError results.
Future<List<StrategyDecision?>> _driveFailures(
  CircuitBreakerStrategy strategy,
  RequestOptions req,
  int n, {
  DioException Function(RequestOptions)? makeError,
}) async {
  makeError ??= _networkError;
  final decisions = <StrategyDecision?>[];
  for (var i = 0; i < n; i++) {
    final ctx = PipelineContext(req);
    // Simulate onRequest passing (circuit may be closed at this point).
    try {
      await strategy.onRequest(ctx);
    } on CircuitOpenException {
      // Already open — stop recording individual failures.
      break;
    }
    final decision = await strategy.onError(ctx, makeError(req));
    decisions.add(decision);
  }
  return decisions;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('CircuitBreakerStrategy', () {
    // Mutable clock for deterministic time control without sleeping.
    late DateTime now;
    late CircuitBreakerStrategy strategy;
    late RequestOptions req;

    setUp(() {
      now = DateTime(2024, 1, 1);
      strategy = CircuitBreakerStrategy(
        failureThreshold: 3,
        windowDuration: const Duration(seconds: 60),
        cooldown: const Duration(seconds: 30),
        halfOpenProbes: 1,
        now: () => now,
      );
      req = _req();
    });

    // ------------------------------------------------------------------
    // 1. Trips after N failures
    // ------------------------------------------------------------------
    test('remains closed below the failure threshold', () async {
      await _driveFailures(strategy, req, 2);
      expect(strategy.phaseFor('api.example.com'), CircuitPhase.closed);
    });

    test('trips to open after reaching failureThreshold failures', () async {
      await _driveFailures(strategy, req, 3);
      expect(strategy.phaseFor('api.example.com'), CircuitPhase.open);
    });

    // ------------------------------------------------------------------
    // 2. Short-circuits while open
    // ------------------------------------------------------------------
    test('throws CircuitOpenException on onRequest while open', () async {
      await _driveFailures(strategy, req, 3); // trip it
      expect(strategy.phaseFor('api.example.com'), CircuitPhase.open);

      final ctx = PipelineContext(req);
      expect(
        () => strategy.onRequest(ctx),
        throwsA(isA<CircuitOpenException>()),
      );
    });

    test('CircuitOpenException carries the correct circuitName', () async {
      await _driveFailures(strategy, req, 3);

      final ctx = PipelineContext(req);
      try {
        await strategy.onRequest(ctx);
        fail('Expected CircuitOpenException');
      } on CircuitOpenException catch (e) {
        expect(e.circuitName, equals('api.example.com'));
      }
    });

    // ------------------------------------------------------------------
    // 3. Transitions to half-open after cooldown
    // ------------------------------------------------------------------
    test('moves to half-open when cooldown has elapsed', () async {
      await _driveFailures(strategy, req, 3); // trip to open
      expect(strategy.phaseFor('api.example.com'), CircuitPhase.open);

      // Advance clock past cooldown.
      now = now.add(const Duration(seconds: 31));

      final ctx = PipelineContext(req);
      // Should NOT throw — allows the probe.
      await expectLater(strategy.onRequest(ctx), completes);
      expect(strategy.phaseFor('api.example.com'), CircuitPhase.halfOpen);
    });

    test('stays open when cooldown has not elapsed', () async {
      await _driveFailures(strategy, req, 3);

      // Advance only 10 s — less than the 30 s cooldown.
      now = now.add(const Duration(seconds: 10));

      final ctx = PipelineContext(req);
      expect(
        () => strategy.onRequest(ctx),
        throwsA(isA<CircuitOpenException>()),
      );
    });

    // ------------------------------------------------------------------
    // 4. Closes on probe success
    // ------------------------------------------------------------------
    test('closes the circuit on a successful probe in half-open', () async {
      await _driveFailures(strategy, req, 3);
      now = now.add(const Duration(seconds: 31));

      final ctx = PipelineContext(req);
      await strategy.onRequest(ctx); // enters half-open, dispatches probe

      final response = Response<dynamic>(statusCode: 200, requestOptions: req);
      await strategy.onResponse(ctx, response);

      expect(strategy.phaseFor('api.example.com'), CircuitPhase.closed);
    });

    // ------------------------------------------------------------------
    // 5. Reopens on probe failure
    // ------------------------------------------------------------------
    test('reopens the circuit on a failed probe in half-open', () async {
      await _driveFailures(strategy, req, 3);
      now = now.add(const Duration(seconds: 31));

      final ctx = PipelineContext(req);
      await strategy.onRequest(ctx); // enters half-open

      await strategy.onError(ctx, _networkError(req));

      expect(strategy.phaseFor('api.example.com'), CircuitPhase.open);
    });

    // ------------------------------------------------------------------
    // 6. Per-host isolation
    // ------------------------------------------------------------------
    test('circuits are isolated per host', () async {
      final reqA = _req('https://service-a.example.com/ping');
      final reqB = _req('https://service-b.example.com/ping');

      // Trip service-a.
      await _driveFailures(strategy, reqA, 3);
      expect(strategy.phaseFor('service-a.example.com'), CircuitPhase.open);

      // service-b should still be closed.
      expect(strategy.phaseFor('service-b.example.com'), CircuitPhase.closed);

      // service-b should accept requests normally.
      final ctx = PipelineContext(reqB);
      await expectLater(strategy.onRequest(ctx), completes);
    });

    // ------------------------------------------------------------------
    // 7. Custom keyExtractor
    // ------------------------------------------------------------------
    test('custom keyExtractor keys circuits by the returned value', () async {
      final customStrategy = CircuitBreakerStrategy(
        failureThreshold: 2,
        windowDuration: const Duration(seconds: 60),
        cooldown: const Duration(seconds: 30),
        halfOpenProbes: 1,
        keyExtractor: (opts) =>
            opts.path.contains('/payments') ? 'payments' : 'default',
        now: () => now,
      );

      final paymentsReq = _req('https://api.example.com/payments/charge');
      final otherReq = _req('https://api.example.com/users/list');

      // Trip the payments circuit.
      await _driveFailures(customStrategy, paymentsReq, 2);
      expect(customStrategy.phaseFor('payments'), CircuitPhase.open);

      // The 'default' circuit should still be closed.
      expect(customStrategy.phaseFor('default'), CircuitPhase.closed);
      final ctx = PipelineContext(otherReq);
      await expectLater(customStrategy.onRequest(ctx), completes);
    });

    // ------------------------------------------------------------------
    // 8. Options.circuitKey() per-request key override
    // ------------------------------------------------------------------
    test('Options.circuitKey() overrides the per-request circuit key',
        () async {
      final overriddenReq = RequestOptions(
        path: 'https://api.example.com/data',
        extra: {kCircuitKeyOverride: 'my-custom-key'},
      );

      await _driveFailures(strategy, overriddenReq, 3);
      // The default host key should be untouched.
      expect(strategy.phaseFor('api.example.com'), CircuitPhase.closed);
      // The custom key should be open.
      expect(strategy.phaseFor('my-custom-key'), CircuitPhase.open);
    });

    // ------------------------------------------------------------------
    // 9. CircuitOverride.disabled skips all circuit logic
    // ------------------------------------------------------------------
    test('CircuitOverride.disabled bypasses the circuit entirely', () async {
      // Trip the circuit.
      await _driveFailures(strategy, req, 3);
      expect(strategy.phaseFor('api.example.com'), CircuitPhase.open);

      // A request with the disabled override should pass through.
      final disabledReq = req.copyWith(
        extra: {
          '__dio_resilience_overrides__': const ResilienceOverrides(
            circuit: CircuitOverride.disabled,
          ),
        },
      );
      final ctx = PipelineContext(disabledReq);
      // Must NOT throw even though the circuit is open.
      await expectLater(strategy.onRequest(ctx), completes);
    });

    test('CircuitOverride.disabled allows onError without recording failure',
        () async {
      final disabledReq = req.copyWith(
        extra: {
          '__dio_resilience_overrides__': const ResilienceOverrides(
            circuit: CircuitOverride.disabled,
          ),
        },
      );

      // Drive failures through the disabled circuit — it must not trip.
      for (var i = 0; i < 5; i++) {
        final ctx = PipelineContext(disabledReq);
        await strategy.onRequest(ctx); // no throw
        await strategy.onError(ctx, _networkError(disabledReq));
      }

      expect(strategy.phaseFor('api.example.com'), CircuitPhase.closed);
    });

    // ------------------------------------------------------------------
    // 10. Integration with retry strategy: retry must NOT fire when circuit
    //     short-circuits (the error reaches retry as a CircuitOpenException,
    //     which is not in the default retry conditions).
    // ------------------------------------------------------------------
    test('retry does not fire when circuit open exception is thrown', () async {
      // Trip the circuit.
      await _driveFailures(strategy, req, 3);

      // Now simulate the pipeline: onRequest throws CircuitOpenException,
      // which the pipeline converts into a DioException. RetryStrategy should
      // return null for it (it won't match any default retry condition).
      final retryStrategy = RetryStrategy();
      final ctx = PipelineContext(req);

      final circuitErr = CircuitOpenException(
        requestOptions: req,
        circuitName: 'api.example.com',
        stackTrace: StackTrace.current,
      );
      final wrappedErr = DioException(
        requestOptions: req,
        error: circuitErr,
        type: DioExceptionType.unknown,
      );

      final decision = await retryStrategy.onError(ctx, wrappedErr);
      // RetryStrategy should not replay — unknown error type with no matching
      // condition should return null.
      expect(decision, isNull);
    });

    // ------------------------------------------------------------------
    // 11. Probe budget exhausted in half-open while probesDispatched >= halfOpenProbes
    // ------------------------------------------------------------------
    test('rejects extra requests in half-open when probe budget exhausted',
        () async {
      final multiProbeStrategy = CircuitBreakerStrategy(
        failureThreshold: 2,
        windowDuration: const Duration(seconds: 60),
        cooldown: const Duration(seconds: 30),
        halfOpenProbes: 1, // only 1 probe allowed at a time
        now: () => now,
      );

      await _driveFailures(multiProbeStrategy, req, 2);
      now = now.add(const Duration(seconds: 31));

      // First probe — allowed, transitions to half-open.
      final probeCtx = PipelineContext(req);
      await multiProbeStrategy.onRequest(probeCtx);
      expect(
        multiProbeStrategy.phaseFor('api.example.com'),
        CircuitPhase.halfOpen,
      );

      // Second request before the probe resolves — should be rejected.
      final secondCtx = PipelineContext(req);
      expect(
        () => multiProbeStrategy.onRequest(secondCtx),
        throwsA(isA<CircuitOpenException>()),
      );
    });

    // ------------------------------------------------------------------
    // 12. Rolling window: old failures outside the window don't count
    // ------------------------------------------------------------------
    test('failures outside the rolling window are not counted', () async {
      // Record 2 failures right at t=0.
      await _driveFailures(strategy, req, 2);
      expect(strategy.phaseFor('api.example.com'), CircuitPhase.closed);

      // Advance clock past the 60 s window so those failures expire.
      now = now.add(const Duration(seconds: 61));

      // One more failure — should not trip (window was reset).
      final ctx = PipelineContext(req);
      await strategy.onRequest(ctx);
      await strategy.onError(ctx, _networkError(req));

      expect(strategy.phaseFor('api.example.com'), CircuitPhase.closed);
    });

    // ------------------------------------------------------------------
    // 13. Success in closed state resets the failure counter
    // ------------------------------------------------------------------
    test('successful response in closed state clears the failure window',
        () async {
      // 2 failures (threshold is 3).
      await _driveFailures(strategy, req, 2);
      expect(strategy.phaseFor('api.example.com'), CircuitPhase.closed);

      // One success — should clear the window.
      final ctx = PipelineContext(req);
      final response = Response<dynamic>(statusCode: 200, requestOptions: req);
      await strategy.onResponse(ctx, response);

      // Now 3 more failures should be needed to trip.
      await _driveFailures(strategy, req, 2);
      expect(strategy.phaseFor('api.example.com'), CircuitPhase.closed);

      await _driveFailures(strategy, req, 1);
      expect(strategy.phaseFor('api.example.com'), CircuitPhase.open);
    });

    // ------------------------------------------------------------------
    // 14. CircuitOverride.threshold / CircuitOverride.cooldown factories
    // ------------------------------------------------------------------
    test(
        'CircuitOverride.threshold and cooldown factories exist and hold values',
        () {
      const t = CircuitOverride.threshold(10);
      const c = CircuitOverride.cooldown(Duration(seconds: 45));
      expect(t, isA<CircuitThreshold>());
      expect((t as CircuitThreshold).count, equals(10));
      expect(c, isA<CircuitCooldown>());
      expect(
        (c as CircuitCooldown).duration,
        equals(const Duration(seconds: 45)),
      );
    });

    // ------------------------------------------------------------------
    // 15. resetAll clears all state
    // ------------------------------------------------------------------
    test('resetAll clears all circuit state', () async {
      await _driveFailures(strategy, req, 3);
      expect(strategy.phaseFor('api.example.com'), CircuitPhase.open);

      strategy.resetAll();
      expect(strategy.phaseFor('api.example.com'), CircuitPhase.closed);
    });

    test('CircuitOverride.threshold trips at the request threshold', () async {
      final req = RequestOptions(
        path: 'https://api.example.com/data',
        extra: {
          kResilienceOverridesKey: const ResilienceOverrides(
            circuit: CircuitOverride.threshold(1),
          ),
        },
      );
      await _driveFailures(strategy, req, 1);
      expect(strategy.phaseFor('api.example.com'), CircuitPhase.open);
    });
  });
}
