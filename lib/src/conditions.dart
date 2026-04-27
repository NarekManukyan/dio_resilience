import 'package:dio/dio.dart';

/// Snapshot of a failed attempt, passed to [RetryCondition.matches].
class RetryEvaluation {
  final DioException error;
  final int attemptNumber;
  final Duration elapsed;

  const RetryEvaluation({
    required this.error,
    required this.attemptNumber,
    required this.elapsed,
  });

  int? get statusCode => error.response?.statusCode;
  String? get dioMessage => error.message;
  Object? get responseBody => error.response?.data;

  bool get isNetworkError =>
      error.type == DioExceptionType.connectionError ||
      error.type == DioExceptionType.unknown && error.error != null;

  bool get isTimeout =>
      error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout;
}

/// A condition that classifies a failed attempt — used by retry, circuit
/// breaker, and (later) fallback strategies. All variants are
/// `const`-constructible.
sealed class RetryCondition {
  const RetryCondition();

  bool matches(RetryEvaluation event);

  // ----- Common conditions -----

  const factory RetryCondition.status(int code) = _StatusCode;
  const factory RetryCondition.statusIn(Set<int> codes) = _StatusCodes;
  const factory RetryCondition.statusBetween(int min, int max) = _StatusRange;
  const factory RetryCondition.networkError() = _NetworkError;
  const factory RetryCondition.timeout() = _TimeoutCondition;

  /// Substring match against [DioException.message].
  const factory RetryCondition.dioMessageContains(
    String text, {
    bool caseSensitive,
  }) = _DioMessage;

  /// Substring match against the stringified response body.
  const factory RetryCondition.responseBodyContains(String text) =
      _BodyContains;

  /// Reads a dotted path from a JSON response body and tests equality.
  ///
  /// Example: `RetryCondition.responseField('error.code', equals: 'DUPE')`.
  /// Returns false if the path doesn't resolve.
  const factory RetryCondition.responseField(
    String path, {
    Object? equals,
  }) = _ResponseField;

  /// Final escape hatch — full predicate access.
  const factory RetryCondition.predicate(
    bool Function(RetryEvaluation) test,
  ) = _Predicate;

  // ----- Combinators -----

  RetryCondition or(RetryCondition other) => _Or(this, other);
  RetryCondition and(RetryCondition other) => _And(this, other);
  RetryCondition negated() => _Not(this);

  /// Convenience: any of the conditions match (OR-fold).
  static RetryCondition any(List<RetryCondition> conditions) {
    if (conditions.isEmpty) return const _Never();
    return conditions.reduce((a, b) => a.or(b));
  }

  /// Convenience: all of the conditions match (AND-fold).
  static RetryCondition all(List<RetryCondition> conditions) {
    if (conditions.isEmpty) return const _Always();
    return conditions.reduce((a, b) => a.and(b));
  }
}

// -------------------- Implementations --------------------

final class _StatusCode extends RetryCondition {
  final int code;
  const _StatusCode(this.code);
  @override
  bool matches(RetryEvaluation event) => event.statusCode == code;
}

final class _StatusCodes extends RetryCondition {
  final Set<int> codes;
  const _StatusCodes(this.codes);
  @override
  bool matches(RetryEvaluation event) {
    final s = event.statusCode;
    return s != null && codes.contains(s);
  }
}

final class _StatusRange extends RetryCondition {
  final int min;
  final int max;
  const _StatusRange(this.min, this.max);
  @override
  bool matches(RetryEvaluation event) {
    final s = event.statusCode;
    return s != null && s >= min && s <= max;
  }
}

final class _NetworkError extends RetryCondition {
  const _NetworkError();
  @override
  bool matches(RetryEvaluation event) => event.isNetworkError;
}

final class _TimeoutCondition extends RetryCondition {
  const _TimeoutCondition();
  @override
  bool matches(RetryEvaluation event) => event.isTimeout;
}

final class _DioMessage extends RetryCondition {
  final String text;
  final bool caseSensitive;
  const _DioMessage(this.text, {this.caseSensitive = false});
  @override
  bool matches(RetryEvaluation event) {
    final msg = event.dioMessage;
    if (msg == null) return false;
    if (caseSensitive) return msg.contains(text);
    return msg.toLowerCase().contains(text.toLowerCase());
  }
}

final class _BodyContains extends RetryCondition {
  final String text;
  const _BodyContains(this.text);
  @override
  bool matches(RetryEvaluation event) {
    final body = event.responseBody;
    if (body == null) return false;
    return body.toString().contains(text);
  }
}

final class _ResponseField extends RetryCondition {
  final String path;
  final Object? equals;
  const _ResponseField(this.path, {this.equals});
  @override
  bool matches(RetryEvaluation event) {
    final body = event.responseBody;
    if (body is! Map) return false;
    final segments = path.split('.');
    Object? current = body;
    for (final seg in segments) {
      if (current is Map && current.containsKey(seg)) {
        current = current[seg];
      } else {
        return false;
      }
    }
    return current == equals;
  }
}

final class _Predicate extends RetryCondition {
  final bool Function(RetryEvaluation) test;
  const _Predicate(this.test);
  @override
  bool matches(RetryEvaluation event) => test(event);
}

final class _Or extends RetryCondition {
  final RetryCondition a;
  final RetryCondition b;
  const _Or(this.a, this.b);
  @override
  bool matches(RetryEvaluation event) => a.matches(event) || b.matches(event);
}

final class _And extends RetryCondition {
  final RetryCondition a;
  final RetryCondition b;
  const _And(this.a, this.b);
  @override
  bool matches(RetryEvaluation event) => a.matches(event) && b.matches(event);
}

final class _Not extends RetryCondition {
  final RetryCondition inner;
  const _Not(this.inner);
  @override
  bool matches(RetryEvaluation event) => !inner.matches(event);
}

final class _Never extends RetryCondition {
  const _Never();
  @override
  bool matches(RetryEvaluation event) => false;
}

final class _Always extends RetryCondition {
  const _Always();
  @override
  bool matches(RetryEvaluation event) => true;
}
