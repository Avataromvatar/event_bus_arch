import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

///A bus that records the address passed to [createNode] and can opt into
///creating a node on send for every address.
class HookedBus extends EventBusImpl {
  HookedBus({this.createOnSend = false}) : super(false);

  final bool createOnSend;
  final List<String> createdAddresses = [];

  @override
  EventNode<T> createNode<T>({
    required String address,
    T? currentData,
  }) {
    createdAddresses.add(address);
    return super.createNode<T>(address: address, currentData: currentData);
  }

  @override
  bool shouldCreateNodeOnSend(String address) => createOnSend;
}

void main() {
  group('EventBus: node creation hooks', () {
    test('listen passes the topic to createNode', () async {
      final bus = HookedBus();
      final subscription =
          bus.listen(EventKey<String>('String.a.b')).listen((_) {});
      addTearDown(bus.dispose);

      expect(bus.createdAddresses.single, 'String.a.b');
      await subscription.cancel();
    });

    test('subscribe(handler:) passes the topic to createNode', () async {
      final bus = HookedBus();
      addTearDown(bus.dispose);

      bus.subscribe(EventKey<int>('int.x'), handler: (dto, last) async {});

      expect(bus.createdAddresses.single, 'int.x');
    });

    test('fire creates a node when shouldCreateNodeOnSend allows it', () async {
      final bus = HookedBus(createOnSend: true);
      addTearDown(bus.dispose);

      // The node is created and stores the value, but no listener accepted it,
      // so fire reports false on a common bus (D14).
      expect(bus.fire(EventKey<String>('String.x'), 'v'), isFalse);
      await Future<void>.delayed(Duration.zero);

      expect(bus.createdAddresses.single, 'String.x');
      expect(bus.currentData(EventKey<String>('String.x')), 'v');
    });

    test('fire does not create a node by default', () {
      final bus = HookedBus();
      addTearDown(bus.dispose);

      expect(bus.fire(EventKey<String>('String.x'), 'v'), isFalse);
      expect(bus.createdAddresses, isEmpty);
      expect(bus.currentData(EventKey<String>('String.x')), isNull);
    });
  });
}
