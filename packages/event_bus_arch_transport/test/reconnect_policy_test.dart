import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';
import 'package:test/test.dart';

void main() {
  group('ReconnectPolicy', () {
    test('the first delay is the initial duration', () {
      const policy = ReconnectPolicy(initial: Duration(seconds: 2));

      expect(policy.delayFor(0), const Duration(seconds: 2));
    });

    test('each attempt multiplies the delay', () {
      const policy = ReconnectPolicy(
        initial: Duration(seconds: 1),
        multiplier: 2,
      );

      expect(policy.delayFor(1), const Duration(seconds: 2));
      expect(policy.delayFor(2), const Duration(seconds: 4));
      expect(policy.delayFor(3), const Duration(seconds: 8));
    });

    test('the delay never exceeds max', () {
      const policy = ReconnectPolicy(
        initial: Duration(seconds: 1),
        max: Duration(seconds: 3),
        multiplier: 2,
      );

      expect(policy.delayFor(10), const Duration(seconds: 3));
    });

    test('attempts are exhausted at maxAttempts', () {
      const policy = ReconnectPolicy(maxAttempts: 2);

      expect(policy.exhausted(0), isFalse);
      expect(policy.exhausted(1), isFalse);
      expect(policy.exhausted(2), isTrue);
    });

    test('without maxAttempts the policy never exhausts', () {
      const policy = ReconnectPolicy();

      expect(policy.exhausted(1000), isFalse);
    });
  });
}
