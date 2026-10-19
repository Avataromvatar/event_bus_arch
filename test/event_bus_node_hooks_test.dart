import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

///A bus that records the topic passed to [createNode] and can opt into
///creating a node on send for every topic.
class HookedBus extends EventBusImpl {
  HookedBus({this.createOnSend = false}) : super(false);

  final bool createOnSend;
  final List<Topic> createdTopics = [];

  @override
  EventNode<T> createNode<T>({
    required Topic topic,
    T? currentData,
  }) {
    createdTopics.add(topic);
    return super.createNode<T>(topic: topic, currentData: currentData);
  }

  @override
  bool shouldCreateNodeOnSend(Topic topic) => createOnSend;
}

void main() {
  group('EventBus: node creation hooks', () {
    test('listen passes the topic to createNode', () async {
      final bus = HookedBus();
      final subscription = bus.listen<String>(paths: ['a', 'b']).listen((_) {});
      addTearDown(bus.dispose);

      expect(bus.createdTopics.single.topic, 'String.a.b');
      await subscription.cancel();
    });

    test('setHandler passes the topic to createNode', () async {
      final bus = HookedBus();
      addTearDown(bus.dispose);

      bus.handlers.setHandler<int>(paths: ['x'], handler: (dto, last) async {});

      expect(bus.createdTopics.single.topic, 'int.x');
    });

    test('fire creates a node when shouldCreateNodeOnSend allows it', () async {
      final bus = HookedBus(createOnSend: true);
      addTearDown(bus.dispose);

      expect(bus.fire<String>('v', paths: ['x']), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(bus.createdTopics.single.topic, 'String.x');
      expect(bus.currentData<String>(paths: ['x']), 'v');
    });

    test('fire does not create a node by default', () {
      final bus = HookedBus();
      addTearDown(bus.dispose);

      expect(bus.fire<String>('v', paths: ['x']), isFalse);
      expect(bus.createdTopics, isEmpty);
      expect(bus.currentData<String>(paths: ['x']), isNull);
    });
  });
}
