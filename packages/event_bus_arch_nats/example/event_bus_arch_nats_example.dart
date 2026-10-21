import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_nats/event_bus_arch_nats.dart';

///Publishes an event from one bus and receives it on another.
///
///Requires a running NATS server on localhost:4222.
Future<void> main() async {
  final publisher = EventBusNats(
    Uri.parse('nats://localhost:4222'),
    serializers: {
      'int.sensor.temp': (dto) =>
          (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
    },
  );

  final subscriber = EventBusNats(
    Uri.parse('nats://localhost:4222'),
    deserializers: {
      'int.sensor.*': (data, topic, {arguments}) => EventDTO<int>(
        int.parse(utf8.decode(data)),
        topic: Topic.parse(topic),
      ),
    },
  );

  await Future.wait([
    publisher.waitConnected(timeout: const Duration(seconds: 5)),
    subscriber.waitConnected(timeout: const Duration(seconds: 5)),
  ]);

  final received = Completer<int>();
  final subscription = subscriber.subscribe<int>(
    paths: ['sensor', '*'],
    onData: (value) {
      print('received: $value');
      received.complete(value);
    },
  );

  publisher.fire<int>(21, paths: ['sensor', 'temp']);

  await received.future.timeout(const Duration(seconds: 5));

  await subscription.cancel();
  await publisher.dispose();
  await subscriber.dispose();
}
