import 'package:dio/dio.dart';
import 'package:dio_resilience/src/conditions.dart';
import 'package:dio_resilience/src/options_extension.dart';
import 'package:dio_resilience/src/overrides.dart';
import 'package:dio_resilience/src/token.dart';
import 'package:test/test.dart';

void main() {
  group('ResilienceOverrides via Options extension', () {
    group('resilience() base method', () {
      test('round-trips ResilienceOverrides through options', () {
        const overrides = ResilienceOverrides(
          retry: RetryOverride.disabled,
        );
        final opts = Options().resilience(overrides);
        final retrieved = overridesFor(opts);
        expect(retrieved?.retry, isA<RetryOverride>());
        expect(_retryKind(retrieved!.retry), equals('disabled'));
      });

      test('preserves existing extra fields', () {
        final opts = Options(extra: {'foo': 'bar'}).resilience(
          const ResilienceOverrides(retry: RetryOverride.disabled),
        );
        expect(opts.extra?['foo'], equals('bar'));
      });
    });

    group('noRetry() shortcut', () {
      test('sets retry to disabled', () {
        final opts = Options().noRetry();
        final overrides = overridesFor(opts);
        expect(_retryKind(overrides!.retry), equals('disabled'));
      });

      test('preserves other overrides when chained', () {
        final opts = Options().noAuth().noRetry();
        final overrides = overridesFor(opts);
        expect(_retryKind(overrides!.retry), equals('disabled'));
        expect(_authKind(overrides.auth), equals('disabled'));
      });
    });

    group('noAuth() shortcut', () {
      test('sets auth to disabled', () {
        final opts = Options().noAuth();
        final overrides = overridesFor(opts);
        expect(_authKind(overrides!.auth), equals('disabled'));
      });

      test('preserves other overrides when chained', () {
        final opts = Options().noAuth().noRetry();
        final overrides = overridesFor(opts);
        expect(_authKind(overrides!.auth), equals('disabled'));
        expect(_retryKind(overrides.retry), equals('disabled'));
      });
    });

    group('withTimeout() shortcut', () {
      test('sets timeout to total duration', () {
        final opts = Options().withTimeout(const Duration(seconds: 5));
        final overrides = overridesFor(opts);
        expect(_timeoutKind(overrides!.timeout), equals('total'));
        expect(
          (overrides.timeout as TimeoutTotal?)?.duration,
          equals(const Duration(seconds: 5)),
        );
      });
    });

    group('withAccount() shortcut', () {
      test('sets auth to account with AccountId', () {
        const accountId = AccountId('alice');
        final opts = Options().withAccount(accountId);
        final overrides = overridesFor(opts);
        expect(_authKind(overrides!.auth), equals('account'));
        expect(
          (overrides.auth as AuthAccount?)?.account.value,
          equals('alice'),
        );
      });
    });

    group('retryAttempts() shortcut', () {
      test('sets retry to attempts override', () {
        final opts = Options().retryAttempts(5);
        final overrides = overridesFor(opts);
        expect(_retryKind(overrides!.retry), equals('attempts'));
        expect(
          (overrides.retry as RetryAttempts?)?.attempts,
          equals(5),
        );
      });
    });

    group('dontRetryOn() shortcut', () {
      test('sets retry to exceptWhen with statusIn conditions', () {
        final opts = Options().dontRetryOn({409, 422});
        final overrides = overridesFor(opts);
        expect(_retryKind(overrides!.retry), equals('exceptWhen'));
        expect(
          (overrides.retry as RetryExceptWhen?)?.conditions.length,
          equals(1),
        );
      });
    });

    group('dontRetryWhen() shortcut', () {
      test('sets retry to exceptWhen with custom conditions', () {
        const cond = RetryCondition.dioMessageContains('foo');
        final opts = Options().dontRetryWhen([cond]);
        final overrides = overridesFor(opts);
        expect(_retryKind(overrides!.retry), equals('exceptWhen'));
        expect(
          (overrides.retry as RetryExceptWhen?)?.conditions.length,
          equals(1),
        );
      });
    });

    group('retryOnlyWhen() shortcut', () {
      test('sets retry to onlyWhen with custom conditions', () {
        const cond = RetryCondition.networkError();
        final opts = Options().retryOnlyWhen([cond]);
        final overrides = overridesFor(opts);
        expect(_retryKind(overrides!.retry), equals('onlyWhen'));
        expect(
          (overrides.retry as RetryOnlyWhen?)?.conditions.length,
          equals(1),
        );
      });
    });

    group('chaining merges correctly', () {
      test('noRetry().noAuth() sets both retry and auth to disabled', () {
        final opts = Options().noRetry().noAuth();
        final overrides = overridesFor(opts);
        expect(_retryKind(overrides!.retry), equals('disabled'));
        expect(_authKind(overrides.auth), equals('disabled'));
      });

      test('multiple timeout calls use latest', () {
        final opts = Options()
            .withTimeout(const Duration(seconds: 5))
            .withTimeout(const Duration(seconds: 10));
        final overrides = overridesFor(opts);
        expect(
          (overrides!.timeout as TimeoutTotal?)?.duration,
          equals(const Duration(seconds: 10)),
        );
      });

      test('retryAttempts().dontRetryWhen() merges correctly', () {
        final opts = Options()
            .retryAttempts(3)
            .dontRetryWhen([const RetryCondition.status(429)]);
        final overrides = overridesFor(opts);
        // Last call wins: dontRetryWhen replaces retryAttempts
        expect(_retryKind(overrides!.retry), equals('exceptWhen'));
      });

      test('noAuth().withAccount() replaces correctly', () {
        final opts = Options().noAuth().withAccount(const AccountId('bob'));
        final overrides = overridesFor(opts);
        expect(_authKind(overrides!.auth), equals('account'));
        expect(
          (overrides.auth as AuthAccount?)?.account.value,
          equals('bob'),
        );
      });

      test('all shortcuts together preserve all overrides', () {
        final opts = Options()
            .noRetry()
            .noAuth()
            .withTimeout(const Duration(seconds: 5));
        final overrides = overridesFor(opts);
        expect(_retryKind(overrides!.retry), equals('disabled'));
        expect(_authKind(overrides.auth), equals('disabled'));
        expect(_timeoutKind(overrides.timeout), equals('total'));
      });
    });

    group('resilience() overwrites previous overrides', () {
      test('passing full ResilienceOverrides replaces merged state', () {
        final opts = Options().noRetry().noAuth().resilience(
              const ResilienceOverrides(
                retry: RetryOverride.attempts(7),
              ),
            );
        final overrides = overridesFor(opts);
        // resilience() replaces the entire bag
        expect(_retryKind(overrides!.retry), equals('attempts'));
        expect(overrides.auth, isNull);
      });
    });
  });
}

// -------- Helper functions to match RetryOverride variants --------

String _retryKind(RetryOverride? override) {
  if (override == null) return 'null';
  if (identical(override, RetryOverride.disabled)) return 'disabled';
  if (override is RetryExceptWhen) return 'exceptWhen';
  if (override is RetryOnlyWhen) return 'onlyWhen';
  if (override is RetryAttempts) return 'attempts';
  if (override is RetryPolicy) return 'policy';
  return 'unknown';
}

String _authKind(AuthOverride? override) {
  if (override == null) return 'null';
  if (identical(override, AuthOverride.disabled)) return 'disabled';
  if (override is AuthAccount) return 'account';
  return 'unknown';
}

String _timeoutKind(TimeoutOverride? override) {
  if (override == null) return 'null';
  if (identical(override, TimeoutOverride.disabled)) return 'disabled';
  if (override is TimeoutTotal) return 'total';
  if (override is TimeoutPerAttempt) return 'perAttempt';
  return 'unknown';
}
