@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_nats/event_bus_nats.dart';
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
  final url = Platform.environment['NATS_URL'];
  final skip = url == null
      ? 'Set NATS_URL to run the integration tests'
      : false;

  group('EventBusNats (integration)', () {
    late EventBusNats busA;
    late EventBusNats busB;

    setUp(() async {
      final serializers = {
        'int': (EventDTO dto) =>
            (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
      };
      final deserializers = {'int': _decode};

      busA = EventBusNats(
        Uri.parse(url!),
        serializers: serializers,
        deserializers: deserializers,
      );
      busB = EventBusNats(
        Uri.parse(url),
        serializers: serializers,
        deserializers: deserializers,
      );
      await Future.wait([
        busA.waitConnected(timeout: const Duration(seconds: 5)),
        busB.waitConnected(timeout: const Duration(seconds: 5)),
      ]);
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

      await busA.send<int>(42, paths: ['sensor', 'temp']);

      expect(await received.future.timeout(const Duration(seconds: 5)), 42);
    });

    test('the publisher does not receive its own echo', () async {
      final received = <int>[];
      busA.listen<int>(paths: ['sensor', 'temp']).listen(received.add);

      await busA.send<int>(1, paths: ['sensor', 'temp']);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(received, [1]);
    });

    test('a wildcard listener receives a concrete subject', () async {
      final received = Completer<int>();
      busB.listen<int>(paths: ['sensor', '*']).listen((value) {
        received.complete(value);
      });

      await busA.send<int>(7, paths: ['sensor', 'humidity']);

      expect(await received.future.timeout(const Duration(seconds: 5)), 7);
    });

    test('arguments travel with the event', () async {
      final received = Completer<Map<String, String>?>();
      final busC = EventBusNats(
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

      await busA.send<int>(1, paths: ['args'], arguments: {'tenant': 'acme'});

      expect(await received.future.timeout(const Duration(seconds: 5)), {
        'tenant': 'acme',
      });
    });
  }, skip: skip);
}
