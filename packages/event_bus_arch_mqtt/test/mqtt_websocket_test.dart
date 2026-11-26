import 'dart:async';
import 'dart:io';

import 'package:event_bus_arch_mqtt/event_bus_arch_mqtt.dart';
import 'package:test/test.dart';

void main() {
  test(
    'ws:// reaches a WebSocket upgrade instead of a TCP-only path',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upgraded = Completer<void>();
      server.listen((request) async {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = 400;
          await request.response.close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        if (!upgraded.isCompleted) upgraded.complete();
        await socket.close();
      });

      final connection = MqttServerConnection(
        Uri.parse('ws://127.0.0.1:${server.port}'),
        options: const MqttConnectionOptions(
          connectTimeout: Duration(milliseconds: 300),
        ),
      );
      try {
        unawaited(connection.start());
        await upgraded.future.timeout(const Duration(seconds: 2));
      } finally {
        await connection.close();
        await server.close(force: true);
      }
    },
  );
}
