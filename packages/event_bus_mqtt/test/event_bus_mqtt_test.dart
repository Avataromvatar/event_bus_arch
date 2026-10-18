import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_mqtt/event_bus_mqtt.dart';
import 'package:test/test.dart';

import 'fakes/fake_mqtt_connection.dart';

void main() {
  test('the public types are exported', () {
    expect(EventBusMqtt, isNotNull);
    expect(MqttServerConnection, isNotNull);
    expect(MqttSubjectMapper, isNotNull);
  });

  test('the bus exposes the connection state', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt(
      Uri.parse('mqtt://localhost:1883'),
      connection: connection,
    );
    addTearDown(bus.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(bus.isConnected, isTrue);
    expect(bus.status, MqttConnectionStatus.connected);
  });

  test('dispose closes the connection and can be repeated', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt(
      Uri.parse('mqtt://localhost:1883'),
      connection: connection,
    );
    await Future<void>.delayed(Duration.zero);

    await bus.dispose();
    await bus.dispose();

    expect(bus.isConnected, isFalse);
    expect(connection.closed, isTrue);
  });

  test('fire creates a node for a registered topic and publishes it', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt(
      Uri.parse('mqtt://localhost:1883'),
      serializers: {
        'int.sensor': (dto) =>
            (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
      },
      connection: connection,
    );
    addTearDown(bus.dispose);

    expect(
      bus.fire<int>(21, paths: ['sensor'], arguments: {'tenant': 'acme'}),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);

    expect(connection.publishes, hasLength(1));
    final published = connection.publishes.single;
    expect(published.subject, 'int/sensor');
    expect(utf8.decode(published.data), '21');
    expect(published.arguments, {'tenant': 'acme'});
    expect(published.originId, bus.originId);
    expect(bus.currentData<int>(paths: ['sensor']), 21);
  });

  test('fire throws when the connection is down', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt(
      Uri.parse('mqtt://localhost:1883'),
      serializers: {'int.sensor': (dto) => (null, Uint8List(0))},
      connection: connection,
    );
    addTearDown(bus.dispose);
    connection.setStatus(MqttConnectionStatus.disconnected);

    expect(
      () => bus.fire<int>(21, paths: ['sensor']),
      throwsA(isA<MqttServerUnavailableException>()),
    );

    expect(connection.publishes, isEmpty);
    expect(bus.currentData<int>(paths: ['sensor']), isNull);
  });

  test('fire without a registration keeps the local semantics', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt(
      Uri.parse('mqtt://localhost:1883'),
      connection: connection,
    );
    addTearDown(bus.dispose);

    expect(bus.fire<String>('v', paths: ['x']), isFalse);
    expect(bus.currentData<String>(paths: ['x']), isNull);
  });

  test('delivers incoming messages to a listener', () async {
    final connection = FakeMqttConnection();
    String? seenTopic;
    Map<String, String>? seenArguments;
    final bus = EventBusMqtt(
      Uri.parse('mqtt://localhost:1883'),
      deserializers: {
        'int.sensor.temp': (data, topic, {arguments}) {
          seenTopic = topic;
          seenArguments = arguments;
          return EventDTO<int>(
            int.parse(utf8.decode(data)),
            topic: Topic.parse(topic),
          );
        },
      },
      connection: connection,
    );
    addTearDown(bus.dispose);

    final received = Completer<int>();
    final subscription = bus
        .listen<int>(paths: ['sensor', 'temp'])
        .listen((value) => received.complete(value));
    addTearDown(subscription.cancel);

    expect(connection.subscribedSubjects, ['int/sensor/temp']);

    connection.deliver(
      MqttMessage(
        subject: 'int/sensor/temp',
        data: Uint8List.fromList(utf8.encode('42')),
        arguments: {'tenant': 'acme'},
      ),
    );

    expect(await received.future.timeout(const Duration(seconds: 1)), 42);
    expect(seenTopic, 'int.sensor.temp');
    expect(seenArguments, {'tenant': 'acme'});
    expect(bus.currentData<int>(paths: ['sensor', 'temp']), 42);
  });

  test(
    'delivers incoming messages matched by a wildcard subscription',
    () async {
      final connection = FakeMqttConnection();
      final bus = EventBusMqtt(
        Uri.parse('mqtt://localhost:1883'),
        deserializers: {
          'int.sensor.*': (data, topic, {arguments}) => EventDTO<int>(
            int.parse(utf8.decode(data)),
            topic: Topic.parse(topic),
          ),
        },
        connection: connection,
      );
      addTearDown(bus.dispose);

      final received = Completer<int>();
      final subscription = bus
          .listen<int>(paths: ['sensor', '*'])
          .listen((value) => received.complete(value));
      addTearDown(subscription.cancel);

      expect(connection.subscribedSubjects, ['int/sensor/+']);

      connection.deliver(
        MqttMessage(
          subject: 'int/sensor/temp',
          data: Uint8List.fromList(utf8.encode('7')),
        ),
      );

      expect(await received.future.timeout(const Duration(seconds: 1)), 7);
    },
  );

  test('drops a tail-wildcard match with zero levels', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt(
      Uri.parse('mqtt://localhost:1883'),
      deserializers: {
        'int.>': (data, topic, {arguments}) => EventDTO<int>(
          int.parse(utf8.decode(data)),
          topic: Topic.parse(topic),
        ),
      },
      connection: connection,
    );
    addTearDown(bus.dispose);

    final received = <int>[];
    final subscription = bus.listen<int>(paths: ['>']).listen(received.add);
    addTearDown(subscription.cancel);

    expect(connection.subscribedSubjects, ['int/#']);

    // MQTT `#` also matches the parent itself; the core `>` does not.
    connection.deliver(
      MqttMessage(subject: 'int', data: Uint8List.fromList(utf8.encode('1'))),
    );
    connection.deliver(
      MqttMessage(
        subject: 'int/sensor',
        data: Uint8List.fromList(utf8.encode('2')),
      ),
    );

    await Future<void>.delayed(Duration.zero);
    expect(received, [2]);
    expect(bus.currentData<int>(paths: ['>']), 2);
  });

  test('uses the serializer subject override', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt(
      Uri.parse('mqtt://localhost:1883'),
      serializers: {
        'int.sensor': (dto) => ('custom/subject', Uint8List.fromList([1])),
      },
      connection: connection,
    );
    addTearDown(bus.dispose);

    expect(bus.fire<int>(1, paths: ['sensor']), isTrue);

    expect(connection.publishes.single.subject, 'custom/subject');
  });

  test('dispose cancels node subscriptions', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt(
      Uri.parse('mqtt://localhost:1883'),
      deserializers: {
        'int.sensor.temp': (data, topic, {arguments}) =>
            EventDTO<int>(0, topic: Topic.parse(topic)),
      },
      connection: connection,
    );
    final subscription = bus
        .listen<int>(paths: ['sensor', 'temp'])
        .listen((_) {});
    expect(connection.subscribedSubjects, ['int/sensor/temp']);

    await subscription.cancel();
    // The node is pinned by the transport, so the subscription stays.
    expect(connection.subscribedSubjects, ['int/sensor/temp']);

    await bus.dispose();
    expect(connection.subscribedSubjects, isEmpty);
    expect(connection.closed, isTrue);
  });

  test('reports a serializer failure to the sender', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt(
      Uri.parse('mqtt://localhost:1883'),
      serializers: {'int.sensor': (dto) => throw StateError('boom')},
      connection: connection,
    );
    addTearDown(bus.dispose);

    expect(
      () => bus.fire<int>(1, paths: ['sensor']),
      throwsA(isA<MqttSerializationException>()),
    );
  });

  test(
    'reports a deserializer type mismatch without breaking the node',
    () async {
      final connection = FakeMqttConnection();
      final errors = <Object>[];
      final bus = EventBusMqtt(
        Uri.parse('mqtt://localhost:1883'),
        deserializers: {
          'int.sensor': (data, topic, {arguments}) =>
              EventDTO<String>('wrong', topic: Topic.parse(topic)),
        },
        connection: connection,
      );
      addTearDown(bus.dispose);
      final errorSubscription = bus.errors.listen(errors.add);
      addTearDown(errorSubscription.cancel);
      final subscription = bus.listen<int>(paths: ['sensor']).listen((_) {});
      addTearDown(subscription.cancel);

      connection.deliver(
        MqttMessage(subject: 'int/sensor', data: Uint8List(0)),
      );
      await Future<void>.delayed(Duration.zero);

      expect(errors.single, isA<MqttDeserializationException>());
      expect(bus.currentData<int>(paths: ['sensor']), isNull);
    },
  );

  test(
    'resolves a deserializer by pattern and maps prefixed subjects',
    () async {
      final connection = FakeMqttConnection();
      final bus = EventBusMqtt(
        Uri.parse('mqtt://localhost:1883'),
        subjectPrefix: 'acme',
        deserializers: {
          'int.sensor.*': (data, topic, {arguments}) =>
              EventDTO<int>(0, topic: Topic.parse(topic)),
        },
        connection: connection,
      );
      addTearDown(bus.dispose);

      expect(
        bus.subjects.toSubject(
          Topic.create<int>(paths: ['sensor', 'temp']),
          subscription: true,
        ),
        'acme/int/sensor/temp',
      );
      expect(
        bus.shouldCreateNodeOnSend(
          Topic.create<int>(paths: ['sensor', 'temp']),
        ),
        isTrue,
      );
    },
  );

  test('an outgoing request is answered through the connection', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt(
      Uri.parse('mqtt://localhost:1883'),
      serializers: {
        'int.sensor': (dto) =>
            (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
      },
      deserializers: {
        'int.sensor': (data, topic, {arguments}) => EventDTO<int>(
          int.parse(utf8.decode(data)),
          topic: Topic.parse(topic),
          arguments: arguments,
        ),
      },
      connection: connection,
    );
    addTearDown(bus.dispose);

    final pending = bus.request<int>(
      21,
      paths: ['sensor'],
      timeout: const Duration(seconds: 1),
    );

    final request = connection.requests.single;
    expect(request.subject, 'int/sensor');
    expect(request.originId, bus.originId);

    connection.deliver(
      MqttMessage(
        subject: request.replyTo,
        data: Uint8List.fromList(utf8.encode('42')),
      ),
    );

    expect(await pending, 42);
  });

  test('an incoming request is answered by the local handler', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt(
      Uri.parse('mqtt://localhost:1883'),
      serializers: {
        'int.sensor': (dto) =>
            (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
      },
      deserializers: {
        'int.sensor': (data, topic, {arguments}) => EventDTO<int>(
          int.parse(utf8.decode(data)),
          topic: Topic.parse(topic),
          arguments: arguments,
        ),
      },
      connection: connection,
    );
    addTearDown(bus.dispose);
    bus.setHandler<int>(
      paths: ['sensor'],
      handler: (dto, lastData) async => dto.data * 2,
    );

    connection.deliver(
      MqttMessage(
        subject: 'int/sensor',
        data: Uint8List.fromList(utf8.encode('21')),
        replyTo: '_INBOX/1',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(connection.publishes.single.subject, '_INBOX/1');
    expect(utf8.decode(connection.publishes.single.data), '42');
  });

  test('a request without a local handler or transport route throws', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt(
      Uri.parse('mqtt://localhost:1883'),
      connection: connection,
    );
    addTearDown(bus.dispose);

    expect(
      () => bus.request<int>(1, paths: ['sensor']),
      throwsA(isA<NoHandlerException>()),
    );
  });

  test('a request with a wildcard path is rejected', () {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt(
      Uri.parse('mqtt://localhost:1883'),
      connection: connection,
    );
    addTearDown(bus.dispose);

    expect(
      () => bus.request<int>(1, paths: ['sensor', '*']),
      throwsA(isA<EventBusException>()),
    );
  });

  test('rejects an invalid registry key at construction', () {
    expect(
      () => EventBusMqtt(
        Uri.parse('mqtt://localhost:1883'),
        serializers: {'int.*': (dto) => (null, Uint8List(0))},
        connection: FakeMqttConnection(),
      ),
      throwsA(isA<MqttSubjectException>()),
    );
  });
}
