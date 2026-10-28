import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_resilience/src/conditions.dart';
import 'package:test/test.dart';

void main() {
  group('RetryCondition', () {
    group('status', () {
      test('matches exact status code', () {
        const condition = RetryCondition.status(503);
        final eval = _mkEval(statusCode: 503);
        expect(condition.matches(eval), isTrue);
      });

      test('does not match different status code', () {
        const condition = RetryCondition.status(503);
        final eval = _mkEval(statusCode: 500);
        expect(condition.matches(eval), isFalse);
      });

      test('returns false when response is null', () {
        const condition = RetryCondition.status(503);
        final eval = _mkEval(statusCode: null);
        expect(condition.matches(eval), isFalse);
      });
    });

    group('statusIn', () {
      test('matches any status in the set', () {
        const condition = RetryCondition.statusIn({400, 401, 403});
        expect(condition.matches(_mkEval(statusCode: 400)), isTrue);
        expect(condition.matches(_mkEval(statusCode: 401)), isTrue);
        expect(condition.matches(_mkEval(statusCode: 403)), isTrue);
      });

      test('does not match status outside the set', () {
        const condition = RetryCondition.statusIn({400, 401, 403});
        expect(condition.matches(_mkEval(statusCode: 500)), isFalse);
      });

      test('returns false when response is null', () {
        const condition = RetryCondition.statusIn({400, 401, 403});
        expect(condition.matches(_mkEval(statusCode: null)), isFalse);
      });
    });

    group('statusBetween', () {
      test('matches status codes in range inclusive', () {
        const condition = RetryCondition.statusBetween(500, 599);
        expect(condition.matches(_mkEval(statusCode: 500)), isTrue);
        expect(condition.matches(_mkEval(statusCode: 503)), isTrue);
        expect(condition.matches(_mkEval(statusCode: 599)), isTrue);
      });

      test('does not match status codes outside range', () {
        const condition = RetryCondition.statusBetween(500, 599);
        expect(condition.matches(_mkEval(statusCode: 400)), isFalse);
        expect(condition.matches(_mkEval(statusCode: 600)), isFalse);
      });

      test('returns false when response is null', () {
        const condition = RetryCondition.statusBetween(500, 599);
        expect(condition.matches(_mkEval(statusCode: null)), isFalse);
      });
    });

    group('networkError', () {
      test('matches DioExceptionType.connectionError', () {
        const condition = RetryCondition.networkError();
        final exception = DioException(
          requestOptions: _mkRequestOptions(),
          type: DioExceptionType.connectionError,
        );
        final eval = RetryEvaluation(
          error: exception,
          attemptNumber: 1,
          elapsed: Duration.zero,
        );
        expect(condition.matches(eval), isTrue);
      });

      test('does not match clean response (status 500)', () {
        const condition = RetryCondition.networkError();
        final eval = _mkEval(statusCode: 500);
        expect(condition.matches(eval), isFalse);
      });

      test('matches DioExceptionType.unknown caused by a dropped connection',
          () {
        const condition = RetryCondition.networkError();
        for (final cause in <Object>[
          const SocketException('Connection reset by peer'),
          const HttpException(
            'Connection closed before full header was received',
          ),
          const HandshakeException('Connection terminated during handshake'),
        ]) {
          final exception = DioException(
            requestOptions: _mkRequestOptions(),
            type: DioExceptionType.unknown,
            error: cause,
          );
          final eval = RetryEvaluation(
            error: exception,
            attemptNumber: 1,
            elapsed: Duration.zero,
          );
          expect(condition.matches(eval), isTrue, reason: '$cause');
        }
      });

      test('does not match an unknown error that would fail again', () {
        const condition = RetryCondition.networkError();
        for (final cause in <Object>[
          const FormatException('Unexpected character'),
          Exception('Network issue'),
          const HttpException('Redirect loop detected'),
          const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        ]) {
          final exception = DioException(
            requestOptions: _mkRequestOptions(),
            type: DioExceptionType.unknown,
            error: cause,
          );
          final eval = RetryEvaluation(
            error: exception,
            attemptNumber: 1,
            elapsed: Duration.zero,
          );
          expect(condition.matches(eval), isFalse, reason: '$cause');
        }
      });

      test('does not match DioExceptionType.unknown without error', () {
        const condition = RetryCondition.networkError();
        final exception = DioException(
          requestOptions: _mkRequestOptions(),
          type: DioExceptionType.unknown,
        );
        final eval = RetryEvaluation(
          error: exception,
          attemptNumber: 1,
          elapsed: Duration.zero,
        );
        expect(condition.matches(eval), isFalse);
      });
    });

    group('timeout', () {
      test('matches connectionTimeout', () {
        const condition = RetryCondition.timeout();
        final exception = DioException(
          requestOptions: _mkRequestOptions(),
          type: DioExceptionType.connectionTimeout,
        );
        final eval = RetryEvaluation(
          error: exception,
          attemptNumber: 1,
          elapsed: Duration.zero,
        );
        expect(condition.matches(eval), isTrue);
      });

      test('matches sendTimeout', () {
        const condition = RetryCondition.timeout();
        final exception = DioException(
          requestOptions: _mkRequestOptions(),
          type: DioExceptionType.sendTimeout,
        );
        final eval = RetryEvaluation(
          error: exception,
          attemptNumber: 1,
          elapsed: Duration.zero,
        );
        expect(condition.matches(eval), isTrue);
      });

      test('matches receiveTimeout', () {
        const condition = RetryCondition.timeout();
        final exception = DioException(
          requestOptions: _mkRequestOptions(),
          type: DioExceptionType.receiveTimeout,
        );
        final eval = RetryEvaluation(
          error: exception,
          attemptNumber: 1,
          elapsed: Duration.zero,
        );
        expect(condition.matches(eval), isTrue);
      });

      test('does not match status code response', () {
        const condition = RetryCondition.timeout();
        final eval = _mkEval(statusCode: 500);
        expect(condition.matches(eval), isFalse);
      });
    });

    group('dioMessageContains', () {
      test('matches substring in message case-insensitive by default', () {
        const condition = RetryCondition.dioMessageContains(
          'insufficient_funds',
          caseSensitive: false,
        );
        final exception = DioException(
          requestOptions: _mkRequestOptions(),
          message: 'Error: INSUFFICIENT_FUNDS encountered',
        );
        final eval = RetryEvaluation(
          error: exception,
          attemptNumber: 1,
          elapsed: Duration.zero,
        );
        expect(condition.matches(eval), isTrue);
      });

      test('respects case-sensitive matching', () {
        const condition = RetryCondition.dioMessageContains(
          'insufficient_funds',
          caseSensitive: true,
        );
        final exception = DioException(
          requestOptions: _mkRequestOptions(),
          message: 'Error: INSUFFICIENT_FUNDS encountered',
        );
        final eval = RetryEvaluation(
          error: exception,
          attemptNumber: 1,
          elapsed: Duration.zero,
        );
        expect(condition.matches(eval), isFalse);
      });

      test('matches case-sensitive when cases match', () {
        const condition = RetryCondition.dioMessageContains(
          'insufficient_funds',
          caseSensitive: true,
        );
        final exception = DioException(
          requestOptions: _mkRequestOptions(),
          message: 'Error: insufficient_funds encountered',
        );
        final eval = RetryEvaluation(
          error: exception,
          attemptNumber: 1,
          elapsed: Duration.zero,
        );
        expect(condition.matches(eval), isTrue);
      });

      test('returns false when message is null', () {
        const condition = RetryCondition.dioMessageContains('foo');
        final exception = DioException(
          requestOptions: _mkRequestOptions(),
        );
        final eval = RetryEvaluation(
          error: exception,
          attemptNumber: 1,
          elapsed: Duration.zero,
        );
        expect(condition.matches(eval), isFalse);
      });
    });

    group('responseBodyContains', () {
      test('matches substring in stringified body', () {
        const condition = RetryCondition.responseBodyContains('foo');
        final eval = _mkEval(responseBody: 'error: foo bar');
        expect(condition.matches(eval), isTrue);
      });

      test('does not match missing substring', () {
        const condition = RetryCondition.responseBodyContains('foo');
        final eval = _mkEval(responseBody: 'error: bar baz');
        expect(condition.matches(eval), isFalse);
      });

      test('returns false when response body is null', () {
        const condition = RetryCondition.responseBodyContains('foo');
        final eval = _mkEval(responseBody: null);
        expect(condition.matches(eval), isFalse);
      });

      test('converts body to string before matching', () {
        const condition = RetryCondition.responseBodyContains('code');
        final eval = _mkEval(responseBody: {'error': 'code_mismatch'});
        expect(condition.matches(eval), isTrue);
      });
    });

    group('responseField', () {
      test('matches nested path with correct value', () {
        const condition =
            RetryCondition.responseField('error.code', equals: 'DUPE');
        final eval = _mkEval(
          responseBody: {
            'error': {'code': 'DUPE'},
          },
        );
        expect(condition.matches(eval), isTrue);
      });

      test('returns false when path does not resolve', () {
        const condition =
            RetryCondition.responseField('error.code', equals: 'DUPE');
        final eval = _mkEval(
          responseBody: {
            'other': {'code': 'DUPE'},
          },
        );
        expect(condition.matches(eval), isFalse);
      });

      test('returns false when nested key missing', () {
        const condition =
            RetryCondition.responseField('error.code', equals: 'DUPE');
        final eval = _mkEval(
          responseBody: {
            'error': {'message': 'DUPE'},
          },
        );
        expect(condition.matches(eval), isFalse);
      });

      test('returns false when value differs', () {
        const condition =
            RetryCondition.responseField('error.code', equals: 'DUPE');
        final eval = _mkEval(
          responseBody: {
            'error': {'code': 'OTHER'},
          },
        );
        expect(condition.matches(eval), isFalse);
      });

      test('returns false when response body is not a map', () {
        const condition =
            RetryCondition.responseField('error.code', equals: 'DUPE');
        final eval = _mkEval(responseBody: 'not a map');
        expect(condition.matches(eval), isFalse);
      });

      test('matches deep nested paths', () {
        const condition =
            RetryCondition.responseField('a.b.c.d', equals: 'deep');
        final eval = _mkEval(
          responseBody: {
            'a': {
              'b': {
                'c': {'d': 'deep'},
              },
            },
          },
        );
        expect(condition.matches(eval), isTrue);
      });
    });

    group('predicate', () {
      test('executes custom predicate', () {
        final condition = RetryCondition.predicate((e) => e.attemptNumber > 1);
        expect(condition.matches(_mkEval(attemptNumber: 2)), isTrue);
        expect(condition.matches(_mkEval(attemptNumber: 1)), isFalse);
      });

      test('can access full RetryEvaluation', () {
        final condition = RetryCondition.predicate(
          (e) => e.statusCode == 503 && e.attemptNumber <= 3,
        );
        expect(
          condition.matches(_mkEval(statusCode: 503, attemptNumber: 2)),
          isTrue,
        );
        expect(
          condition.matches(_mkEval(statusCode: 503, attemptNumber: 4)),
          isFalse,
        );
      });
    });

    group('or combinator', () {
      test('returns true when either condition matches', () {
        final condition = const RetryCondition.status(503)
            .or(const RetryCondition.status(502));
        expect(condition.matches(_mkEval(statusCode: 503)), isTrue);
        expect(condition.matches(_mkEval(statusCode: 502)), isTrue);
      });

      test('returns false when neither matches', () {
        final condition = const RetryCondition.status(503)
            .or(const RetryCondition.status(502));
        expect(condition.matches(_mkEval(statusCode: 500)), isFalse);
      });
    });

    group('and combinator', () {
      test('returns true when both conditions match', () {
        final condition = const RetryCondition.statusBetween(500, 599).and(
          RetryCondition.predicate((e) => e.attemptNumber < 3),
        );
        expect(
          condition.matches(_mkEval(statusCode: 503, attemptNumber: 2)),
          isTrue,
        );
      });

      test('returns false when one condition fails', () {
        final condition = const RetryCondition.statusBetween(500, 599).and(
          RetryCondition.predicate((e) => e.attemptNumber < 3),
        );
        expect(
          condition.matches(_mkEval(statusCode: 503, attemptNumber: 4)),
          isFalse,
        );
      });
    });

    group('negated combinator', () {
      test('inverts the condition', () {
        final condition = const RetryCondition.status(503).negated();
        expect(condition.matches(_mkEval(statusCode: 503)), isFalse);
        expect(condition.matches(_mkEval(statusCode: 500)), isTrue);
      });
    });

    group('any helper', () {
      test('creates OR chain of conditions', () {
        final condition = RetryCondition.any([
          const RetryCondition.status(503),
          const RetryCondition.status(502),
          const RetryCondition.status(429),
        ]);
        expect(condition.matches(_mkEval(statusCode: 503)), isTrue);
        expect(condition.matches(_mkEval(statusCode: 429)), isTrue);
        expect(condition.matches(_mkEval(statusCode: 500)), isFalse);
      });

      test('empty list never matches', () {
        final condition = RetryCondition.any([]);
        expect(condition.matches(_mkEval(statusCode: 503)), isFalse);
      });
    });

    group('all helper', () {
      test('creates AND chain of conditions', () {
        final condition = RetryCondition.all([
          const RetryCondition.statusBetween(500, 599),
          RetryCondition.predicate((e) => e.attemptNumber <= 2),
        ]);
        expect(
          condition.matches(_mkEval(statusCode: 503, attemptNumber: 2)),
          isTrue,
        );
        expect(
          condition.matches(_mkEval(statusCode: 503, attemptNumber: 3)),
          isFalse,
        );
      });

      test('empty list always matches', () {
        final condition = RetryCondition.all([]);
        expect(condition.matches(_mkEval(statusCode: 503)), isTrue);
        expect(condition.matches(_mkEval(statusCode: 200)), isTrue);
      });
    });
  });
}

// -------- Helpers --------

RequestOptions _mkRequestOptions() => RequestOptions(path: '');

RetryEvaluation _mkEval({
  int? statusCode,
  String? dioMessage,
  Object? responseBody,
  int attemptNumber = 1,
  Duration elapsed = Duration.zero,
}) {
  final response = (statusCode != null || responseBody != null)
      ? Response<Object?>(
          requestOptions: _mkRequestOptions(),
          statusCode: statusCode,
          data: responseBody,
        )
      : null;

  final exception = DioException(
    requestOptions: _mkRequestOptions(),
    response: response,
    message: dioMessage,
  );

  return RetryEvaluation(
    error: exception,
    attemptNumber: attemptNumber,
    elapsed: elapsed,
  );
}
