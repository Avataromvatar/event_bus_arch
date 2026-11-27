@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_mqtt/event_bus_arch_mqtt.dart';
import 'package:test/test.dart';

EventDTO<int> _decode(
  Uint8List data,
  String topic, {
  Map<String, String>? arguments,
}) {
  return EventDTO.withKey(
    EventKey<int>(topic),
    int.parse(utf8.decode(data)),
    arguments: arguments,
  );
}

void main() {
  final url = Platform.environment['MQTT_URL'];
  final skip = url == null
      ? 'Set MQTT_URL to run the integration tests'
      : false;

  group('EventBusMqtt (integration)', () {
    late EventBusMqtt busA;
    late EventBusMqtt busB;

    setUp(() async {
      final codec = EventCodec(
        encode: (dto) => (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
        decode: (data, address, {arguments}) =>
            _decode(data, address.value, arguments: arguments),
      );
      final codecs = EventCodecRegistry(
        exact: {EventAddress('int'): codec},
        patterns: {EventPattern('int.>'): codec},
      );

      busA = EventBusMqtt.keys(Uri.parse(url!), codecs: codecs);
      busB = EventBusMqtt.keys(Uri.parse(url), codecs: codecs);
      await Future.wait([
        busA.waitConnected(timeout: const Duration(seconds: 5)),
        busB.waitConnected(timeout: const Duration(seconds: 5)),
      ]);
      // Give the broker a moment to install the subscriptions.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    tearDown(() async {
      await busA.dispose();
      await busB.dispose();
    });

    test('a message published by one bus reaches the other', () async {
      final received = Completer<int>();
      busB
          .listen(EventKey<int>('int.sensor.temp'))
          .listen((value) => received.complete(value));

      busA.fire(EventKey<int>('int.sensor.temp'), 42);

      expect(await received.future.timeout(const Duration(seconds: 5)), 42);
    });

    test('the publisher does not receive its own echo', () async {
      final received = <int>[];
      busA.listen(EventKey<int>('int.sensor.temp')).listen(received.add);

      busA.fire(EventKey<int>('int.sensor.temp'), 1);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(received, [1]);
    });

    test('a wildcard listener receives a concrete topic', () async {
      final received = Completer<int>();
      busB.listen(EventPatternKey<int>('int.sensor.*')).listen((value) {
        received.complete(value);
      });

      busA.fire(EventKey<int>('int.sensor.humidity'), 7);

      expect(await received.future.timeout(const Duration(seconds: 5)), 7);
    });

    test('a request is answered and reaches listeners once', () async {
      final values = <int>[];
      final subscription = busB
          .listen(EventPatternKey<int>('int.sensor.*'))
          .listen(values.add);
      addTearDown(subscription.cancel);
      busB.subscribe(
        EventKey<int>('int.sensor.double'),
        handler: (dto, lastData) async => dto.data * 2,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final result = await busA.request(
        EventKey<int>('int.sensor.double'),
        21,
        timeout: const Duration(seconds: 5),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(result, 42);
      expect(values, [21]);
    });

    test('overlapping subscriptions deliver a fire once per node', () async {
      final values = <int>[];
      final subscription = busB
          .listen(EventPatternKey<int>('int.sensor.*'))
          .listen(values.add);
      addTearDown(subscription.cancel);
      // An exact node next to the pattern node: both filters match, but a
      // listener on the pattern node must see the event once.
      busB.subscribe(
        EventKey<int>('int.sensor.temp'),
        handler: (dto, lastData) async => dto.data,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      busA.fire(EventKey<int>('int.sensor.temp'), 5);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(values, [5]);
    });

    test('a remote request times out when nobody answers', () async {
      await expectLater(
        busA.request(
          EventKey<int>('int.sensor.nobody'),
          1,
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('arguments travel with the event', () async {
      final received = Completer<Map<String, String>?>();
      final busC = EventBusMqtt.keys(
        Uri.parse(url!),
        codecs: EventCodecRegistry(
          exact: {
            EventAddress('int'): EventCodec(
              decode: (data, address, {arguments}) =>
                  ((data, topic, {arguments}) {
                    received.complete(arguments);
                    return EventDTO.withKey(EventKey<int>(topic), 0);
                  })(data, address.value, arguments: arguments),
            ),
          },
          patterns: {
            EventPattern('int.>'): EventCodec(
              decode: (data, address, {arguments}) =>
                  ((data, topic, {arguments}) {
                    received.complete(arguments);
                    return EventDTO.withKey(EventKey<int>(topic), 0);
                  })(data, address.value, arguments: arguments),
            ),
          },
        ),
      );
      addTearDown(busC.dispose);
      await busC.waitConnected(timeout: const Duration(seconds: 5));
      busC.listen(EventKey<int>('int.args')).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 200));

      busA.fire(EventKey<int>('int.args'), 1, arguments: {'tenant': 'acme'});

      expect(await received.future.timeout(const Duration(seconds: 5)), {
        'tenant': 'acme',
      });
    });
  }, skip: skip);
}
