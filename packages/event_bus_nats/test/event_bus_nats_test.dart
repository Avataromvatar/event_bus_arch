import 'dart:typed_data';

import 'package:event_bus_nats/event_bus_nats.dart';
import 'package:test/test.dart';

import 'fakes/fake_nats_connection.dart';

void main() {
  test('the public types are exported', () {
    expect(EventBusNats, isNotNull);
    expect(EventNodeNatsImpl, isNotNull);
    expect(DartNatsConnection, isNotNull);
  });

  test('the bus exposes the connection state', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats(
      Uri.parse('nats://localhost:4222'),
      connection: connection,
    );
    addTearDown(bus.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(bus.isConnected, isTrue);
    expect(bus.status, NatsConnectionStatus.connected);
  });

  test('dispose closes the connection and can be repeated', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats(
      Uri.parse('nats://localhost:4222'),
      connection: connection,
    );
    await Future<void>.delayed(Duration.zero);

    await bus.dispose();
    await bus.dispose();

    expect(bus.isConnected, isFalse);
    expect(connection.closed, isTrue);
  });

  test('send creates a node for a registered topic', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats(
      Uri.parse('nats://localhost:4222'),
      serializers: {'String.x': (dto) => (null, Uint8List(0))},
      connection: connection,
    );
    addTearDown(bus.dispose);

    final result = await bus.send<String>('v', paths: ['x']);

    expect(result, isNull);
    expect(bus.currentData<String>(paths: ['x']), 'v');
  });

  test('send without a registration keeps the local semantics', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats(
      Uri.parse('nats://localhost:4222'),
      connection: connection,
    );
    addTearDown(bus.dispose);

    final result = await bus.send<String>('v', paths: ['x']);

    expect(result, isNull);
    expect(bus.currentData<String>(paths: ['x']), isNull);
  });
}
