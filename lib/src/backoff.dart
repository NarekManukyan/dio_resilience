import 'dart:math';

/// Backoff policy controlling the delay between retry attempts.
///
/// All variants are `const`-constructible so they can live in compile-time
/// configuration and be inspected for serialization.
sealed class Backoff {
  const Backoff();

  /// Delay before the [attempt]-th retry (1-indexed: attempt=1 means the
  /// delay before the first retry, after the initial request failed).
  Duration delayFor(int attempt);

  /// No delay between retries.
  static const Backoff none = _ConstantBackoff(Duration.zero);

  /// Constant delay between retries.
  const factory Backoff.constant(Duration delay) = _ConstantBackoff;

  /// Linearly increasing delay: `initial + (attempt - 1) * increment`.
  const factory Backoff.linear({
    required Duration initial,
    required Duration increment,
    Duration? maxDelay,
  }) = _LinearBackoff;

  /// Exponentially increasing delay: `initial * multiplier^(attempt-1)`,
  /// clamped at [maxDelay].
  const factory Backoff.exponential({
    required Duration initial,
    double multiplier,
    Duration? maxDelay,
  }) = _ExponentialBackoff;

  /// Exponential backoff with full jitter (recommended default).
  ///
  /// Each delay is chosen uniformly between 0 and the exponential ceiling.
  /// Prevents synchronized retry storms across many clients hitting the
  /// same outage.
  const factory Backoff.exponentialJitter({
    required Duration initial,
    double multiplier,
    Duration? maxDelay,
  }) = _JitterBackoff;
}

final class _ConstantBackoff extends Backoff {
  final Duration delay;
  const _ConstantBackoff(this.delay);
  @override
  Duration delayFor(int attempt) => delay;
}

final class _LinearBackoff extends Backoff {
  final Duration initial;
  final Duration increment;
  final Duration? maxDelay;
  const _LinearBackoff({
    required this.initial,
    required this.increment,
    this.maxDelay,
  });
  @override
  Duration delayFor(int attempt) {
    final raw = initial + increment * (attempt - 1);
    if (maxDelay != null && raw > maxDelay!) return maxDelay!;
    return raw;
  }
}

final class _ExponentialBackoff extends Backoff {
  final Duration initial;
  final double multiplier;
  final Duration? maxDelay;
  const _ExponentialBackoff({
    required this.initial,
    this.multiplier = 2.0,
    this.maxDelay,
  });
  @override
  Duration delayFor(int attempt) {
    final factor = pow(multiplier, attempt - 1).toDouble();
    final ms = (initial.inMilliseconds * factor).round();
    final raw = Duration(milliseconds: ms);
    if (maxDelay != null && raw > maxDelay!) return maxDelay!;
    return raw;
  }
}

final class _JitterBackoff extends Backoff {
  final Duration initial;
  final double multiplier;
  final Duration? maxDelay;
  const _JitterBackoff({
    required this.initial,
    this.multiplier = 2.0,
    this.maxDelay,
  });
  @override
  Duration delayFor(int attempt) {
    final factor = pow(multiplier, attempt - 1).toDouble();
    final ceilingMs = (initial.inMilliseconds * factor).round();
    final clampedMs =
        maxDelay != null ? min(ceilingMs, maxDelay!.inMilliseconds) : ceilingMs;
    if (clampedMs <= 0) return Duration.zero;
    final jitteredMs = Random().nextInt(clampedMs + 1);
    return Duration(milliseconds: jitteredMs);
  }
}
