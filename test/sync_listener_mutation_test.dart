import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() {
  group('synchronous listener reentrancy', () {
    test('subscribing on the same address during fire does not crash',
        () async {
      final bus = EventBus();
      final key = EventKey<int>('same.address');
      final other = EventKey<String>('same.address');
      EventSubscription<String>? added;

      final sub = bus.subscribe(
        key,
        deliveryMode: DeliveryMode.sync,
        onEvent: (_) {
          added = bus.subscribe(other, onEvent: (_) {});
        },
      );

      expect(bus.fire(key, 1), isTrue);

      await added!.cancel();
      await sub.cancel();
      await bus.dispose();
    });

    test('removing another node during fire skips the disposed node', () async {
      final bus = EventBus();
      final key = EventKey<int>('same.address');
      final other = EventKey<String>('same.address');
      final received = <String>[];

      final first = bus.subscribe(
        key,
        deliveryMode: DeliveryMode.sync,
        onEvent: (_) => bus.remove(other),
      );
      final victim = bus.subscribe(other, onEvent: received.add);

      expect(bus.fire(key, 1), isTrue);
      expect(received, isEmpty);

      await first.cancel();
      await victim.cancel();
      await bus.dispose();
    });
  });
}
