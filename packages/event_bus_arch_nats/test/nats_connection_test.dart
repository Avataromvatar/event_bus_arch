import 'dart:typed_data';

import 'package:event_bus_arch_nats/event_bus_arch_nats.dart';
import 'package:test/test.dart';

void main() {
  test('publish without a connection throws instead of buffering', () async {
    final connection = DartNatsConnection(
      Uri.parse('nats://127.0.0.1:1'),
      connectTimeout: const Duration(seconds: 1),
      reconnect: const NatsReconnectPolicy(maxAttempts: 1),
    );
    addTearDown(connection.close);

    await connection.start();

    expect(connection.isConnected, isFalse);
    expect(
      () => connection.publish('test.event', Uint8List.fromList([1])),
      throwsA(isA<NatsServerUnavailableException>()),
    );
  });
}
