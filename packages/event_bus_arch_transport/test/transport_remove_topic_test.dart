import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';
import 'package:event_bus_arch_transport/testing.dart';
import 'package:test/test.dart';

class _TestGrammar extends SubjectGrammar {
  const _TestGrammar();

  @override
  String get separator => '.';

  @override
  String get singleWildcard => '*';

  @override
  String get tailWildcard => '>';

  @override
  void validatePublishToken(String token, {required bool isFirst}) {}

  @override
  void validateSubscriptionToken(String token,
      {required bool isFirst, required bool isLast}) {}
}

(String?, Uint8List) _encode(EventDTO dto) => (null, Uint8List(0));

EventDTO _decode(Uint8List data, String topic,
        {Map<String, String>? arguments}) =>
    EventDTO<int>(1, topic: Topic.parse(topic));

void main() {
  group('TransportEventBus.removeTopic', () {
    late FakeTransportConnection connection;
    late TransportEventBus bus;

    setUp(() {
      connection = FakeTransportConnection();
      bus = TransportEventBus(
        connection: connection,
        subjects: TopicSubjectMapper(grammar: const _TestGrammar()),
        serializers: {'int.state': _encode},
        deserializers: {'int.state': _decode},
        originId: 'test-origin',
      );
    });

    tearDown(() async {
      await bus.dispose();
    });

    test('removes a pinned transport node and cancels its subscription',
        () async {
      // The node is created by listen and subscribes to the broker.
      final sub = bus.subscribe<int>(paths: ['state'], onData: (_) {});
      expect(connection.subscribedSubjects, contains('int.state'));
      expect(bus.currentData<int>(paths: ['state']), isNull);

      expect(bus.removeTopic<int>(paths: ['state']), isTrue);

      expect(connection.subscribedSubjects, isNot(contains('int.state')));
      expect(bus.haveListener<int>(paths: ['state']), isFalse);

      // A model-like send recreates the node and its subscription.
      expect(bus.fire<int>(2, paths: ['state']), isTrue);
      expect(connection.subscribedSubjects, contains('int.state'));

      await sub.cancel();
    });

    test('returns false for a topic without a node', () async {
      expect(bus.removeTopic<int>(paths: ['missing']), isFalse);
    });
  });
}
