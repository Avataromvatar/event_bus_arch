import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_nats/event_bus_nats.dart';

Future<void> main() async {
  final bus = EventBusNats(
    Uri.parse('nats://localhost:4222'),
    serializers: {
      'int.sensor.temp': (dto) =>
          (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
    },
    deserializers: {
      'int.sensor.temp': (data, topic, {arguments}) => EventDTO<int>(
        int.parse(utf8.decode(data)),
        topic: Topic.parse(topic),
      ),
    },
  );

  await bus.waitConnected(timeout: const Duration(seconds: 5));

  final subscription = bus.subscribe<int>(
    paths: ['sensor', 'temp'],
    onData: print,
  );

  await bus.send<int>(21, paths: ['sensor', 'temp']);

  await subscription.cancel();
  await bus.dispose();
}
