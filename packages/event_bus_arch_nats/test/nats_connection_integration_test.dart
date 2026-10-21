@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:event_bus_arch_nats/event_bus_arch_nats.dart';
import 'package:test/test.dart';

void main() {
  final url = Platform.environment['NATS_URL'];
  final skip = url == null
      ? 'Set NATS_URL to run the integration tests'
      : false;

  group('DartNatsConnection (integration)', () {
    test('publishes and receives a message', () async {
      final connection = DartNatsConnection(
        Uri.parse(url!),
        reconnect: const NatsReconnectPolicy(maxAttempts: 1),
      );
      addTearDown(connection.close);
      await connection.start();
      expect(connection.isConnected, isTrue);

      final received = Completer<NatsMessage>();
      final subscription = connection.subscribe(
        'eventbus.test',
        received.complete,
      );
      addTearDown(subscription.cancel);

      connection.publish('eventbus.test', Uint8List.fromList([1, 2, 3]));

      final message = await received.future.timeout(const Duration(seconds: 5));
      expect(message.data, [1, 2, 3]);
    }, skip: skip);

    test('does not deliver the connection own echo', () async {
      const origin = 'integration-origin';
      final connection = DartNatsConnection(
        Uri.parse(url!),
        originId: origin,
        reconnect: const NatsReconnectPolicy(maxAttempts: 1),
      );
      addTearDown(connection.close);
      await connection.start();

      final received = <NatsMessage>[];
      final subscription = connection.subscribe('eventbus.echo', received.add);
      addTearDown(subscription.cancel);

      connection.publish(
        'eventbus.echo',
        Uint8List.fromList([1]),
        originId: origin,
      );
      await Future<void>.delayed(const Duration(seconds: 1));

      expect(received, isEmpty);
    }, skip: skip);

    test('delivers arguments through headers', () async {
      final connection = DartNatsConnection(
        Uri.parse(url!),
        reconnect: const NatsReconnectPolicy(maxAttempts: 1),
      );
      addTearDown(connection.close);
      await connection.start();

      final received = Completer<NatsMessage>();
      final subscription = connection.subscribe(
        'eventbus.args',
        received.complete,
      );
      addTearDown(subscription.cancel);

      connection.publish(
        'eventbus.args',
        Uint8List(0),
        arguments: {'tenant': 'acme'},
      );

      final message = await received.future.timeout(const Duration(seconds: 5));
      expect(message.arguments, {'tenant': 'acme'});
    }, skip: skip);
  });
}
