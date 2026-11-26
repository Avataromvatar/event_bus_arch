import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_mqtt/event_bus_arch_mqtt.dart';
import 'package:test/test.dart';

import 'fakes/fake_mqtt_connection.dart';

void main() {
  test('the public types are exported', () {
    expect(EventBusMqtt, isNotNull);
    expect(MqttServerConnection, isNotNull);
    expect(MqttAddressMapper, isNotNull);
  });

  test('the bus exposes the connection state', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
      codecs: EventCodecRegistry(),
      connection: connection,
    );
    addTearDown(bus.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(bus.isConnected, isTrue);
    expect(bus.status, MqttConnectionStatus.connected);
  });

  test('dispose closes the connection and can be repeated', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
      codecs: EventCodecRegistry(),
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
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
      codecs: EventCodecRegistry(
        exact: {
          EventAddress('int.sensor'): EventCodec(
            encode: (dto) =>
                (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
          ),
        },
        patterns: {
          EventPattern('int.sensor.>'): EventCodec(
            encode: (dto) =>
                (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
          ),
        },
      ),
      connection: connection,
    );
    addTearDown(bus.dispose);

    expect(
      bus.fire(EventKey<int>('int.sensor'), 21, arguments: {'tenant': 'acme'}),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);

    expect(connection.publishes, hasLength(1));
    final published = connection.publishes.single;
    expect(published.subject, 'int/sensor');
    expect(utf8.decode(published.data), '21');
    expect(published.arguments, {'tenant': 'acme'});
    expect(published.originId, bus.originId);
    // A fire-only node is detached after publication, so it keeps no value.
    expect(bus.currentData(EventKey<int>('int.sensor')), isNull);
  });

  test('fire throws when the connection is down', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
      codecs: EventCodecRegistry(
        exact: {
          EventAddress('int.sensor'): EventCodec(
            encode: (dto) => (null, Uint8List(0)),
          ),
        },
        patterns: {
          EventPattern('int.sensor.>'): EventCodec(
            encode: (dto) => (null, Uint8List(0)),
          ),
        },
      ),
      connection: connection,
    );
    addTearDown(bus.dispose);
    connection.setStatus(MqttConnectionStatus.disconnected);

    expect(
      () => bus.fire(EventKey<int>('int.sensor'), 21),
      throwsA(isA<MqttServerUnavailableException>()),
    );

    expect(connection.publishes, isEmpty);
    expect(bus.currentData(EventKey<int>('int.sensor')), isNull);
  });

  test('fire without a registration keeps the local semantics', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
      codecs: EventCodecRegistry(),
      connection: connection,
    );
    addTearDown(bus.dispose);

    expect(bus.fire(EventKey<String>('String.x'), 'v'), isFalse);
    expect(bus.currentData(EventKey<String>('String.x')), isNull);
  });

  test('delivers incoming messages to a listener', () async {
    final connection = FakeMqttConnection();
    String? seenTopic;
    Map<String, String>? seenArguments;
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
      codecs: EventCodecRegistry(
        exact: {
          EventAddress('int.sensor.temp'): EventCodec(
            decode: (data, address, {arguments}) =>
                ((data, topic, {arguments}) {
                  seenTopic = topic;
                  seenArguments = arguments;
                  return EventDTO.withKey(
                    EventKey<int>(topic),
                    int.parse(utf8.decode(data)),
                  );
                })(data, address.value, arguments: arguments),
          ),
        },
        patterns: {
          EventPattern('int.sensor.temp.>'): EventCodec(
            decode: (data, address, {arguments}) =>
                ((data, topic, {arguments}) {
                  seenTopic = topic;
                  seenArguments = arguments;
                  return EventDTO.withKey(
                    EventKey<int>(topic),
                    int.parse(utf8.decode(data)),
                  );
                })(data, address.value, arguments: arguments),
          ),
        },
      ),
      connection: connection,
    );
    addTearDown(bus.dispose);

    final received = Completer<int>();
    final subscription = bus
        .listen(EventKey<int>('int.sensor.temp'))
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
    expect(bus.currentData(EventKey<int>('int.sensor.temp')), 42);
  });

  test(
    'delivers incoming messages matched by a wildcard subscription',
    () async {
      final connection = FakeMqttConnection();
      final bus = EventBusMqtt.keys(
        Uri.parse('mqtt://localhost:1883'),
        codecs: EventCodecRegistry(
          patterns: {
            EventPattern('int.sensor.*'): EventCodec(
              decode: (data, address, {arguments}) =>
                  ((data, topic, {arguments}) => EventDTO.withKey(
                    EventKey<int>(topic),
                    int.parse(utf8.decode(data)),
                  ))(data, address.value, arguments: arguments),
            ),
          },
        ),
        connection: connection,
      );
      addTearDown(bus.dispose);

      final received = Completer<int>();
      final subscription = bus
          .listen(EventPatternKey<int>('int.sensor.*'))
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
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
      codecs: EventCodecRegistry(
        patterns: {
          EventPattern('int.>'): EventCodec(
            decode: (data, address, {arguments}) =>
                ((data, topic, {arguments}) => EventDTO.withKey(
                  EventKey<int>(topic),
                  int.parse(utf8.decode(data)),
                ))(data, address.value, arguments: arguments),
          ),
        },
      ),
      connection: connection,
    );
    addTearDown(bus.dispose);

    final received = <int>[];
    final subscription = bus
        .listen(EventPatternKey<int>('int.>'))
        .listen(received.add);
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
    expect(bus.currentData(EventPatternKey<int>('int.>')), 2);
  });

  test('uses the serializer subject override', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
      codecs: EventCodecRegistry(
        exact: {
          EventAddress('int.sensor'): EventCodec(
            encode: (dto) => ('custom/subject', Uint8List.fromList([1])),
          ),
        },
        patterns: {
          EventPattern('int.sensor.>'): EventCodec(
            encode: (dto) => ('custom/subject', Uint8List.fromList([1])),
          ),
        },
      ),
      connection: connection,
    );
    addTearDown(bus.dispose);

    expect(bus.fire(EventKey<int>('int.sensor'), 1), isTrue);

    expect(connection.publishes.single.subject, 'custom/subject');
  });

  test('dispose cancels node subscriptions', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
      codecs: EventCodecRegistry(
        exact: {
          EventAddress('int.sensor.temp'): EventCodec(
            decode: (data, address, {arguments}) =>
                ((data, topic, {arguments}) => EventDTO.withKey(
                  EventKey<int>(topic),
                  0,
                ))(data, address.value, arguments: arguments),
          ),
        },
        patterns: {
          EventPattern('int.sensor.temp.>'): EventCodec(
            decode: (data, address, {arguments}) =>
                ((data, topic, {arguments}) => EventDTO.withKey(
                  EventKey<int>(topic),
                  0,
                ))(data, address.value, arguments: arguments),
          ),
        },
      ),
      connection: connection,
    );
    final subscription = bus
        .listen(EventKey<int>('int.sensor.temp'))
        .listen((_) {});
    expect(connection.subscribedSubjects, ['int/sensor/temp']);

    await subscription.cancel();
    // The last listener detaches the node and cancels its broker subscription.
    expect(connection.subscribedSubjects, isEmpty);

    await bus.dispose();
    expect(connection.subscribedSubjects, isEmpty);
    expect(connection.closed, isTrue);
  });

  test('reports a serializer failure to the sender', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
      codecs: EventCodecRegistry(
        exact: {
          EventAddress('int.sensor'): EventCodec(
            encode: (dto) => throw StateError('boom'),
          ),
        },
        patterns: {
          EventPattern('int.sensor.>'): EventCodec(
            encode: (dto) => throw StateError('boom'),
          ),
        },
      ),
      connection: connection,
    );
    addTearDown(bus.dispose);

    expect(
      () => bus.fire(EventKey<int>('int.sensor'), 1),
      throwsA(isA<MqttSerializationException>()),
    );
  });

  test(
    'reports a deserializer type mismatch without breaking the node',
    () async {
      final connection = FakeMqttConnection();
      final errors = <Object>[];
      final bus = EventBusMqtt.keys(
        Uri.parse('mqtt://localhost:1883'),
        codecs: EventCodecRegistry(
          exact: {
            EventAddress('int.sensor'): EventCodec(
              decode: (data, address, {arguments}) =>
                  ((data, topic, {arguments}) => EventDTO.withKey(
                    EventKey<String>(topic),
                    'wrong',
                  ))(data, address.value, arguments: arguments),
            ),
          },
          patterns: {
            EventPattern('int.sensor.>'): EventCodec(
              decode: (data, address, {arguments}) =>
                  ((data, topic, {arguments}) => EventDTO.withKey(
                    EventKey<String>(topic),
                    'wrong',
                  ))(data, address.value, arguments: arguments),
            ),
          },
        ),
        connection: connection,
      );
      addTearDown(bus.dispose);
      final errorSubscription = bus.errors.listen(errors.add);
      addTearDown(errorSubscription.cancel);
      final subscription = bus
          .listen(EventKey<int>('int.sensor'))
          .listen((_) {});
      addTearDown(subscription.cancel);

      connection.deliver(
        MqttMessage(subject: 'int/sensor', data: Uint8List(0)),
      );
      await Future<void>.delayed(Duration.zero);

      final reported = errors.single as EventBusError;
      expect(reported.error, isA<MqttDeserializationException>());
      expect(bus.currentData(EventKey<int>('int.sensor')), isNull);
    },
  );

  test('an outgoing request is answered through the connection', () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
      codecs: EventCodecRegistry(
        exact: {
          EventAddress('int.sensor'): EventCodec(
            encode: (dto) =>
                (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
            decode: (data, address, {arguments}) =>
                ((data, topic, {arguments}) => EventDTO.withKey(
                  EventKey<int>(topic),
                  int.parse(utf8.decode(data)),
                  arguments: arguments,
                ))(data, address.value, arguments: arguments),
          ),
        },
        patterns: {
          EventPattern('int.sensor.>'): EventCodec(
            encode: (dto) =>
                (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
            decode: (data, address, {arguments}) =>
                ((data, topic, {arguments}) => EventDTO.withKey(
                  EventKey<int>(topic),
                  int.parse(utf8.decode(data)),
                  arguments: arguments,
                ))(data, address.value, arguments: arguments),
          ),
        },
      ),
      connection: connection,
    );
    addTearDown(bus.dispose);

    final pending = bus.request(
      EventKey<int>('int.sensor'),
      21,
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
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
      codecs: EventCodecRegistry(
        exact: {
          EventAddress('int.sensor'): EventCodec(
            encode: (dto) =>
                (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
            decode: (data, address, {arguments}) =>
                ((data, topic, {arguments}) => EventDTO.withKey(
                  EventKey<int>(topic),
                  int.parse(utf8.decode(data)),
                  arguments: arguments,
                ))(data, address.value, arguments: arguments),
          ),
        },
        patterns: {
          EventPattern('int.sensor.>'): EventCodec(
            encode: (dto) =>
                (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
            decode: (data, address, {arguments}) =>
                ((data, topic, {arguments}) => EventDTO.withKey(
                  EventKey<int>(topic),
                  int.parse(utf8.decode(data)),
                  arguments: arguments,
                ))(data, address.value, arguments: arguments),
          ),
        },
      ),
      connection: connection,
    );
    addTearDown(bus.dispose);
    bus.subscribe(
      EventKey<int>('int.sensor'),
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
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
      codecs: EventCodecRegistry(),
      connection: connection,
    );
    addTearDown(bus.dispose);

    expect(
      () => bus.request(EventKey<int>('int.sensor'), 1),
      throwsA(isA<NoHandlerException>()),
    );
  });

  test(
    'a remote request without a deserializer reports the missing half',
    () async {
      final connection = FakeMqttConnection();
      final bus = EventBusMqtt.keys(
        Uri.parse('mqtt://localhost:1883'),
        codecs: EventCodecRegistry(
          exact: {
            EventAddress('int.sensor'): EventCodec(
              encode: (dto) => (null, Uint8List(0)),
            ),
          },
          patterns: {
            EventPattern('int.sensor.>'): EventCodec(
              encode: (dto) => (null, Uint8List(0)),
            ),
          },
        ),
        connection: connection,
      );
      addTearDown(bus.dispose);

      expect(
        () => bus.request(EventKey<int>('int.sensor'), 1),
        throwsA(isA<EventBusTransportException>()),
      );
    },
  );

  test('a request with a wildcard path is rejected', () {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
      codecs: EventCodecRegistry(),
      connection: connection,
    );
    addTearDown(bus.dispose);

    expect(
      () => bus.request(EventKey<int>('int.sensor.*'), 1),
      throwsA(isA<EventBusException>()),
    );
  });
}
