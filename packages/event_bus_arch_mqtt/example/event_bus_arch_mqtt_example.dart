import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_mqtt/event_bus_arch_mqtt.dart';

EventCodec intCodec() => EventCodec(
      encode: (dto) =>
          (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
      decode: (data, address, {arguments}) => EventDTO.withKey(
        EventKey<int>(address.value),
        int.parse(utf8.decode(data)),
        arguments: arguments,
      ),
    );

///A two-bus MQTT 5 demo. Start a broker first, for example:
///
///```text
///mosquitto -p 1883
///```
///
///Then run:
///
///```text
///dart run example/event_bus_arch_mqtt_example.dart
///```
Future<void> main() async {
  final broker = Uri.parse('mqtt://localhost:1883');
  final sensorTemp = EventAddress('sensor.temp');
  final sensorDouble = EventAddress('sensor.double');
  final sensorAny = EventPattern('sensor.*');

  final publisher = EventBusMqtt.keys(
    broker,
    codecs: EventCodecRegistry(exact: {
      sensorTemp: intCodec(),
      // A remote request needs a decoder for the response.
      sensorDouble: intCodec(),
    }),
  );

  final subscriber = EventBusMqtt.keys(
    broker,
    codecs: EventCodecRegistry(
      exact: {sensorDouble: intCodec()},
      patterns: {sensorAny: intCodec()},
    ),
  );

  await Future.wait([
    publisher.waitConnected(timeout: const Duration(seconds: 5)),
    subscriber.waitConnected(timeout: const Duration(seconds: 5)),
  ]);

  subscriber.subscribe(
    EventKey<int>('sensor.double'),
    handler: (dto, lastData) async => dto.data * 2,
  );

  final received = <int>[];
  final subscription = subscriber
      .listen(EventPatternKey<int>('sensor.*'))
      .listen(received.add);

  publisher.fire(EventKey<int>('sensor.temp'), 21);
  await Future<void>.delayed(const Duration(milliseconds: 500));

  final doubled = await publisher.request(
    EventKey<int>('sensor.double'),
    21,
    timeout: const Duration(seconds: 5),
  );

  print('events received: $received');
  print('request response: $doubled');

  await subscription.cancel();
  await publisher.dispose();
  await subscriber.dispose();
}
