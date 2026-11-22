import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_mqtt/event_bus_arch_mqtt.dart';
import 'package:test/test.dart';

import 'fakes/fake_mqtt_connection.dart';

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
  test('EventBusMqtt.keys publishes by address and maps the separator',
      () async {
    final connection = FakeMqttConnection();
    final bus = EventBusMqtt.keys(
      Uri.parse('mqtt://localhost:1883'),
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
    expect(connection.publishes.single.subject, 'orders/placed');
    expect(utf8.decode(connection.publishes.single.data), 'A-1');
  });
}
