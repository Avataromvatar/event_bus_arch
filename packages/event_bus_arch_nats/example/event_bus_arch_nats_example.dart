import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_nats/event_bus_arch_nats.dart';

EventCodec intCodec() => EventCodec(
      encode: (dto) =>
          (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
      decode: (data, address, {arguments}) => EventDTO.withKey(
        EventKey<int>(address.value),
        int.parse(utf8.decode(data)),
        arguments: arguments,
      ),
    );

///Publishes an event from one bus and receives it on another.
///
///Requires a running NATS server on localhost:4222.
Future<void> main() async {
  final sensorTemp = EventAddress('sensor.temp');
  final sensorAny = EventPattern('sensor.*');

  final publisher = EventBusNats.keys(
    Uri.parse('nats://localhost:4222'),
    codecs: EventCodecRegistry(exact: {sensorTemp: intCodec()}),
  );

  final subscriber = EventBusNats.keys(
    Uri.parse('nats://localhost:4222'),
    codecs: EventCodecRegistry(patterns: {sensorAny: intCodec()}),
  );

  await Future.wait([
    publisher.waitConnected(timeout: const Duration(seconds: 5)),
    subscriber.waitConnected(timeout: const Duration(seconds: 5)),
  ]);

  final received = Completer<int>();
  final subscription = subscriber.subscribe(
    EventPatternKey<int>('sensor.*'),
    onEvent: (value) {
      print('received: $value');
      received.complete(value);
    },
  );

  publisher.fire(EventKey<int>('sensor.temp'), 21);

  await received.future.timeout(const Duration(seconds: 5));

  await subscription.cancel();
  await publisher.dispose();
  await subscriber.dispose();
}
