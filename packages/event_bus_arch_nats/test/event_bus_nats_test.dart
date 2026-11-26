import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_nats/event_bus_arch_nats.dart';
import 'package:test/test.dart';

import 'fakes/fake_nats_connection.dart';

void main() {
  test('the public types are exported', () {
    expect(EventBusNats, isNotNull);
    expect(NatsAddressMapper, isNotNull);
    expect(DartNatsConnection, isNotNull);
  });

  test('the bus exposes the connection state', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
        codecs: EventCodecRegistry(), connection: connection);
    addTearDown(bus.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(bus.isConnected, isTrue);
    expect(bus.status, NatsConnectionStatus.connected);
  });

  test('dispose closes the connection and can be repeated', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
        codecs: EventCodecRegistry(), connection: connection);
    await Future<void>.delayed(Duration.zero);

    await bus.dispose();
    await bus.dispose();

    expect(bus.isConnected, isFalse);
    expect(connection.closed, isTrue);
  });

  test('fire creates a node for a registered topic and publishes it', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
        codecs: EventCodecRegistry(exact: {
          EventAddress('int.sensor'): EventCodec(
              encode: (dto) =>
                  (null, Uint8List.fromList(utf8.encode('${dto.data}'))))
        }, patterns: {
          EventPattern('int.sensor.>'): EventCodec(
              encode: (dto) =>
                  (null, Uint8List.fromList(utf8.encode('${dto.data}'))))
        }),
        connection: connection);
    addTearDown(bus.dispose);

    expect(
      bus.fire(EventKey<int>('int.sensor'), 21, arguments: {'tenant': 'acme'}),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);

    expect(connection.publishes, hasLength(1));
    final published = connection.publishes.single;
    expect(published.subject, 'int.sensor');
    expect(utf8.decode(published.data), '21');
    expect(published.arguments, {'tenant': 'acme'});
    expect(published.originId, bus.originId);
    // A fire-only node is detached after publication, so it keeps no value.
    expect(bus.currentData(EventKey<int>('int.sensor')), isNull);
  });

  test('fire throws when the connection is down', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
        codecs: EventCodecRegistry(exact: {
          EventAddress('int.sensor'):
              EventCodec(encode: (dto) => (null, Uint8List(0)))
        }, patterns: {
          EventPattern('int.sensor.>'):
              EventCodec(encode: (dto) => (null, Uint8List(0)))
        }),
        connection: connection);
    addTearDown(bus.dispose);
    connection.setStatus(NatsConnectionStatus.disconnected);

    expect(
      () => bus.fire(EventKey<int>('int.sensor'), 21),
      throwsA(isA<NatsServerUnavailableException>()),
    );

    expect(connection.publishes, isEmpty);
    expect(bus.currentData(EventKey<int>('int.sensor')), isNull);
  });

  test('fire without a registration keeps the local semantics', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
        codecs: EventCodecRegistry(), connection: connection);
    addTearDown(bus.dispose);

    expect(bus.fire(EventKey<String>('String.x'), 'v'), isFalse);
    expect(bus.currentData(EventKey<String>('String.x')), isNull);
  });

  test('delivers incoming messages to a listener', () async {
    final connection = FakeNatsConnection();
    String? seenTopic;
    Map<String, String>? seenArguments;
    final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
        codecs: EventCodecRegistry(exact: {
          EventAddress('int.sensor.temp'): EventCodec(
              decode: (data, address, {arguments}) =>
                  ((data, topic, {arguments}) {
                    seenTopic = topic;
                    seenArguments = arguments;
                    return EventDTO.withKey(
                        EventKey<int>(topic), int.parse(utf8.decode(data)));
                  })(data, address.value, arguments: arguments))
        }, patterns: {
          EventPattern('int.sensor.temp.>'): EventCodec(
              decode: (data, address, {arguments}) =>
                  ((data, topic, {arguments}) {
                    seenTopic = topic;
                    seenArguments = arguments;
                    return EventDTO.withKey(
                        EventKey<int>(topic), int.parse(utf8.decode(data)));
                  })(data, address.value, arguments: arguments))
        }),
        connection: connection);
    addTearDown(bus.dispose);

    final received = Completer<int>();
    final subscription = bus
        .listen(EventKey<int>('int.sensor.temp'))
        .listen((value) => received.complete(value));
    addTearDown(subscription.cancel);

    expect(connection.subscribedSubjects, ['int.sensor.temp']);

    connection.deliver(
      NatsMessage(
        subject: 'int.sensor.temp',
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
      final connection = FakeNatsConnection();
      String? seenTopic;
      final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
          codecs: EventCodecRegistry(patterns: {
            EventPattern('int.sensor.*'): EventCodec(
                decode: (data, address, {arguments}) =>
                    ((data, topic, {arguments}) {
                      seenTopic = topic;
                      return EventDTO.withKey(
                          EventKey<int>(topic), int.parse(utf8.decode(data)));
                    })(data, address.value, arguments: arguments))
          }),
          connection: connection);
      addTearDown(bus.dispose);

      final received = Completer<int>();
      final subscription = bus
          .listen(EventPatternKey<int>('int.sensor.*'))
          .listen((value) => received.complete(value));
      addTearDown(subscription.cancel);

      expect(connection.subscribedSubjects, ['int.sensor.*']);

      connection.deliver(
        NatsMessage(
          subject: 'int.sensor.temp',
          data: Uint8List.fromList(utf8.encode('7')),
        ),
      );

      expect(await received.future.timeout(const Duration(seconds: 1)), 7);
      expect(seenTopic, 'int.sensor.temp');
    },
  );

  test('uses the serializer subject override', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
        codecs: EventCodecRegistry(exact: {
          EventAddress('int.sensor'): EventCodec(
              encode: (dto) => ('custom.subject', Uint8List.fromList([1])))
        }, patterns: {
          EventPattern('int.sensor.>'): EventCodec(
              encode: (dto) => ('custom.subject', Uint8List.fromList([1])))
        }),
        connection: connection);
    addTearDown(bus.dispose);

    expect(bus.fire(EventKey<int>('int.sensor'), 1), isTrue);

    expect(connection.publishes.single.subject, 'custom.subject');
  });

  test('dispose cancels node subscriptions', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
        codecs: EventCodecRegistry(exact: {
          EventAddress('int.sensor.temp'): EventCodec(
              decode: (data, address, {arguments}) => ((data, topic,
                          {arguments}) =>
                      EventDTO.withKey(EventKey<int>(topic), 0))(
                  data, address.value,
                  arguments: arguments))
        }, patterns: {
          EventPattern('int.sensor.temp.>'): EventCodec(
              decode: (data, address, {arguments}) => ((data, topic,
                          {arguments}) =>
                      EventDTO.withKey(EventKey<int>(topic), 0))(
                  data, address.value,
                  arguments: arguments))
        }),
        connection: connection);
    final subscription =
        bus.listen(EventKey<int>('int.sensor.temp')).listen((_) {});
    expect(connection.subscribedSubjects, ['int.sensor.temp']);

    await subscription.cancel();
    // The last listener detaches the node and cancels its broker subscription.
    expect(connection.subscribedSubjects, isEmpty);

    await bus.dispose();
    expect(connection.subscribedSubjects, isEmpty);
    expect(connection.closed, isTrue);
  });

  test('reports a serializer failure to the sender', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
        codecs: EventCodecRegistry(exact: {
          EventAddress('int.sensor'):
              EventCodec(encode: (dto) => throw StateError('boom'))
        }, patterns: {
          EventPattern('int.sensor.>'):
              EventCodec(encode: (dto) => throw StateError('boom'))
        }),
        connection: connection);
    addTearDown(bus.dispose);

    expect(
      () => bus.fire(EventKey<int>('int.sensor'), 1),
      throwsA(isA<NatsSerializationException>()),
    );
  });

  test(
    'reports a deserializer type mismatch without breaking the node',
    () async {
      final connection = FakeNatsConnection();
      final errors = <Object>[];
      final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
          codecs: EventCodecRegistry(exact: {
            EventAddress('int.sensor'): EventCodec(
                decode: (data, address, {arguments}) => ((data, topic,
                            {arguments}) =>
                        EventDTO.withKey(EventKey<String>(topic), 'wrong'))(
                    data, address.value,
                    arguments: arguments))
          }, patterns: {
            EventPattern('int.sensor.>'): EventCodec(
                decode: (data, address, {arguments}) => ((data, topic,
                            {arguments}) =>
                        EventDTO.withKey(EventKey<String>(topic), 'wrong'))(
                    data, address.value,
                    arguments: arguments))
          }),
          connection: connection);
      addTearDown(bus.dispose);
      final errorSubscription = bus.errors.listen(errors.add);
      addTearDown(errorSubscription.cancel);
      final subscription =
          bus.listen(EventKey<int>('int.sensor')).listen((_) {});
      addTearDown(subscription.cancel);

      connection.deliver(
        NatsMessage(subject: 'int.sensor', data: Uint8List(0)),
      );
      await Future<void>.delayed(Duration.zero);

      final reported = errors.single as EventBusError;
      expect(reported.error, isA<NatsDeserializationException>());
      expect(bus.currentData(EventKey<int>('int.sensor')), isNull);
    },
  );

  test('an outgoing request is answered through the connection', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
        codecs: EventCodecRegistry(exact: {
          EventAddress('int.sensor'): EventCodec(
              encode: (dto) =>
                  (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
              decode: (data, address, {arguments}) =>
                  ((data, topic, {arguments}) => EventDTO.withKey(
                          EventKey<int>(topic), int.parse(utf8.decode(data)),
                          arguments: arguments))(data, address.value,
                      arguments: arguments))
        }, patterns: {
          EventPattern('int.sensor.>'): EventCodec(
              encode: (dto) =>
                  (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
              decode: (data, address, {arguments}) =>
                  ((data, topic, {arguments}) => EventDTO.withKey(
                          EventKey<int>(topic), int.parse(utf8.decode(data)),
                          arguments: arguments))(data, address.value,
                      arguments: arguments))
        }),
        connection: connection);
    addTearDown(bus.dispose);

    final pending = bus.request(EventKey<int>('int.sensor'), 21,
        timeout: const Duration(seconds: 1));

    final request = connection.requests.single;
    expect(request.subject, 'int.sensor');
    expect(request.originId, bus.originId);

    connection.deliver(
      NatsMessage(
        subject: request.replyTo,
        data: Uint8List.fromList(utf8.encode('42')),
      ),
    );

    expect(await pending, 42);
  });

  test('an incoming request is answered by the local handler', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
        codecs: EventCodecRegistry(exact: {
          EventAddress('int.sensor'): EventCodec(
              encode: (dto) =>
                  (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
              decode: (data, address, {arguments}) =>
                  ((data, topic, {arguments}) => EventDTO.withKey(
                          EventKey<int>(topic), int.parse(utf8.decode(data)),
                          arguments: arguments))(data, address.value,
                      arguments: arguments))
        }, patterns: {
          EventPattern('int.sensor.>'): EventCodec(
              encode: (dto) =>
                  (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
              decode: (data, address, {arguments}) =>
                  ((data, topic, {arguments}) => EventDTO.withKey(
                          EventKey<int>(topic), int.parse(utf8.decode(data)),
                          arguments: arguments))(data, address.value,
                      arguments: arguments))
        }),
        connection: connection);
    addTearDown(bus.dispose);
    bus.subscribe(EventKey<int>('int.sensor'),
        handler: (dto, lastData) async => dto.data * 2);

    connection.deliver(
      NatsMessage(
        subject: 'int.sensor',
        data: Uint8List.fromList(utf8.encode('21')),
        replyTo: '_INBOX.1',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(connection.publishes.single.subject, '_INBOX.1');
    expect(utf8.decode(connection.publishes.single.data), '42');
  });

  test('a request without a local handler or transport route throws', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
        codecs: EventCodecRegistry(), connection: connection);
    addTearDown(bus.dispose);

    expect(
      () => bus.request(EventKey<int>('int.sensor'), 1),
      throwsA(isA<NoHandlerException>()),
    );
  });

  test('a request with a wildcard path is rejected', () {
    final connection = FakeNatsConnection();
    final bus = EventBusNats.keys(Uri.parse('nats://localhost:4222'),
        codecs: EventCodecRegistry(), connection: connection);
    addTearDown(bus.dispose);

    expect(
      () => bus.request(EventKey<int>('int.sensor.*'), 1),
      throwsA(isA<EventBusException>()),
    );
  });
}
