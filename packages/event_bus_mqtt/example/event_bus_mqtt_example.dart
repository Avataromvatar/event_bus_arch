import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_mqtt/event_bus_mqtt.dart';

///A two-bus MQTT 5 demo. Start a broker first, for example:
///
///```text
///mosquitto -p 1883
///```
///
///Then run:
///
///```text
///dart run example/event_bus_mqtt_example.dart
///```
Future<void> main() async {
  final broker = Uri.parse('mqtt://localhost:1883');

  final publisher = EventBusMqtt(
    broker,
    serializers: {
      'int.sensor.temp': (dto) =>
          (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
      'int.sensor.double': (dto) =>
          (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
    },
    deserializers: {
      // A remote request needs a deserializer for the response.
      'int.sensor.double': (data, topic, {arguments}) => EventDTO<int>(
        int.parse(utf8.decode(data)),
        topic: Topic.parse(topic),
        arguments: arguments,
      ),
    },
  );

  final subscriber = EventBusMqtt(
    broker,
    serializers: {
      'int.sensor.double': (dto) =>
          (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
    },
    deserializers: {
      'int.sensor.*': (data, topic, {arguments}) => EventDTO<int>(
        int.parse(utf8.decode(data)),
        topic: Topic.parse(topic),
        arguments: arguments,
      ),
    },
  );

  await Future.wait([
    publisher.waitConnected(timeout: const Duration(seconds: 5)),
    subscriber.waitConnected(timeout: const Duration(seconds: 5)),
  ]);

  subscriber.setHandler<int>(
    paths: ['sensor', 'double'],
    handler: (dto, lastData) async => dto.data * 2,
  );

  final received = <int>[];
  final subscription = subscriber
      .listen<int>(paths: ['sensor', '*'])
      .listen(received.add);

  publisher.fire<int>(21, paths: ['sensor', 'temp']);
  await Future<void>.delayed(const Duration(milliseconds: 500));

  final doubled = await publisher.request<int>(
    21,
    paths: ['sensor', 'double'],
    timeout: const Duration(seconds: 5),
  );

  print('events received: $received');
  print('request response: $doubled');

  await subscription.cancel();
  await publisher.dispose();
  await subscriber.dispose();
}
