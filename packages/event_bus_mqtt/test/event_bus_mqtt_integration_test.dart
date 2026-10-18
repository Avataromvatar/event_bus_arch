@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_mqtt/event_bus_mqtt.dart';
import 'package:test/test.dart';

EventDTO<int> _decode(
  Uint8List data,
  String topic, {
  Map<String, String>? arguments,
}) {
  return EventDTO<int>(
    int.parse(utf8.decode(data)),
    topic: Topic.parse(topic),
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
      final serializers = {
        'int': (EventDTO dto) =>
            (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
      };
      final deserializers = {'int': _decode};

      busA = EventBusMqtt(
        Uri.parse(url!),
        serializers: serializers,
        deserializers: deserializers,
      );
      busB = EventBusMqtt(
        Uri.parse(url),
        serializers: serializers,
        deserializers: deserializers,
      );
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
          .listen<int>(paths: ['sensor', 'temp'])
          .listen((value) => received.complete(value));

      busA.fire<int>(42, paths: ['sensor', 'temp']);

      expect(await received.future.timeout(const Duration(seconds: 5)), 42);
    });

    test('the publisher does not receive its own echo', () async {
      final received = <int>[];
      busA.listen<int>(paths: ['sensor', 'temp']).listen(received.add);

      busA.fire<int>(1, paths: ['sensor', 'temp']);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(received, [1]);
    });

    test('a wildcard listener receives a concrete topic', () async {
      final received = Completer<int>();
      busB.listen<int>(paths: ['sensor', '*']).listen((value) {
        received.complete(value);
      });

      busA.fire<int>(7, paths: ['sensor', 'humidity']);

      expect(await received.future.timeout(const Duration(seconds: 5)), 7);
    });

    test('a request is answered and reaches listeners once', () async {
      final values = <int>[];
      final subscription = busB
          .listen<int>(paths: ['sensor', '*'])
          .listen(values.add);
      addTearDown(subscription.cancel);
      busB.setHandler<int>(
        paths: ['sensor', 'double'],
        handler: (dto, lastData) async => dto.data * 2,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final result = await busA.request<int>(
        21,
        paths: ['sensor', 'double'],
        timeout: const Duration(seconds: 5),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(result, 42);
      expect(values, [21]);
    });

    test('overlapping subscriptions deliver a fire once per node', () async {
      final values = <int>[];
      final subscription = busB
          .listen<int>(paths: ['sensor', '*'])
          .listen(values.add);
      addTearDown(subscription.cancel);
      // An exact node next to the pattern node: both filters match, but a
      // listener on the pattern node must see the event once.
      busB.setHandler<int>(
        paths: ['sensor', 'temp'],
        handler: (dto, lastData) async => dto.data,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      busA.fire<int>(5, paths: ['sensor', 'temp']);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(values, [5]);
    });

    test('a remote request times out when nobody answers', () async {
      await expectLater(
        busA.request<int>(
          1,
          paths: ['sensor', 'nobody'],
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('arguments travel with the event', () async {
      final received = Completer<Map<String, String>?>();
      final busC = EventBusMqtt(
        Uri.parse(url!),
        deserializers: {
          'int': (data, topic, {arguments}) {
            received.complete(arguments);
            return EventDTO<int>(0, topic: Topic.parse(topic));
          },
        },
      );
      addTearDown(busC.dispose);
      await busC.waitConnected(timeout: const Duration(seconds: 5));
      busC.listen<int>(paths: ['args']).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 200));

      busA.fire<int>(1, paths: ['args'], arguments: {'tenant': 'acme'});

      expect(await received.future.timeout(const Duration(seconds: 5)), {
        'tenant': 'acme',
      });
    });
  }, skip: skip);
}
