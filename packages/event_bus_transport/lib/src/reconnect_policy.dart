import 'dart:math';

///Exponential backoff for reconnection attempts.
class ReconnectPolicy {
  const ReconnectPolicy({
    this.initial = const Duration(seconds: 1),
    this.max = const Duration(seconds: 30),
    this.multiplier = 2.0,
    this.maxAttempts,
  })  : assert(multiplier >= 1.0),
        assert(maxAttempts == null || maxAttempts > 0);

  ///Delay before the first reconnect attempt.
  final Duration initial;

  ///Upper bound of a single delay.
  final Duration max;

  final double multiplier;

  ///How many reconnect attempts to make after a failure. Null means forever.
  final int? maxAttempts;

  ///Whether [attempt] (zero-based) has reached [maxAttempts].
  bool exhausted(int attempt) => maxAttempts != null && attempt >= maxAttempts!;

  ///The delay before the reconnect attempt number [attempt] (zero-based).
  Duration delayFor(int attempt) {
    if (attempt <= 0) return initial;
    final milliseconds = initial.inMilliseconds * pow(multiplier, attempt);
    if (milliseconds >= max.inMilliseconds) return max;
    return Duration(milliseconds: milliseconds.round());
  }
}
