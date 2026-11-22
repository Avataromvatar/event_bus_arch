import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_nats/event_bus_arch_nats.dart';
import 'package:test/test.dart';

import 'fakes/fake_nats_connection.dart';

class Order {
  Order(this.id);
  final String id;
}

EventCodec _orderCodec() => EventCodec(
      encode: (dto) =>
          (null, Uint8List.fromList(utf8.encode((dto.data as Order).id))),
      decode: (data, address, {arguments}) => EventDTO<Order>.withKey(
        EventKey<Order>(address.value),
        Order(utf8.decode(data)),
      ),
    );

void main() {
  test('EventBusNats.keys publishes by address', () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats.keys(
      Uri.parse('nats://localhost:4222'),
      codecs: EventCodecRegistry(
          exact: {EventAddress('orders.placed'): _orderCodec()}),
      connection: connection,
    );
    addTearDown(bus.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(
      bus.fireKey(EventKey<Order>('orders.placed'), Order('A-1')),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);

    expect(connection.publishes, hasLength(1));
    expect(connection.publishes.single.subject, 'orders.placed');
    expect(utf8.decode(connection.publishes.single.data), 'A-1');
  });

  test('EventBusNats.keys maps the local address to a prefixed subject',
      () async {
    final connection = FakeNatsConnection();
    final bus = EventBusNats.keys(
      Uri.parse('nats://localhost:4222'),
      subjectPrefix: 'acme',
      codecs: EventCodecRegistry(
          exact: {EventAddress('orders'): _orderCodec()}),
      connection: connection,
    );
    addTearDown(bus.dispose);
    await Future<void>.delayed(Duration.zero);

    bus.fireKey(EventKey<Order>('orders'), Order('A-1'));
    await Future<void>.delayed(Duration.zero);

    expect(connection.publishes.single.subject, 'acme.orders');
  });
}
