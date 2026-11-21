import 'dart:async';
import 'dart:isolate';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

// --- worker (top-level only) ---

///Reports every onInit to the SendPort and registers a listener, a slow
///handler and a fast handler.
void lifecycleWorker(EventBus bus, Object? initialData) {
  final port = initialData as SendPort;
  port.send('init');
  bus.subscribe<String>(
      paths: ['echo'],
      onData: (e) => bus.fire<String>('echo: $e', paths: ['echo']));
  bus.subscribeEvents<int>(
      paths: ['slow'], handler: (dto, lastData) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return dto.data;
  });
  bus.subscribeEvents<int>(handler: (dto, lastData) async => dto.data * 2);
}

void main() {
  test('restart keeps local listeners and re-handshakes interest', () async {
    final port = ReceivePort();
    final inits = <String>[];
    port.listen((message) => inits.add(message as String));

    final iso =
        EventBusIsolate(onInit: lifecycleWorker, initialData: port.sendPort);
    await iso.waitInit;
    expect(inits, ['init']);

    final received = <String>[];
    final sub = iso.subscribe<String>(paths: ['echo'], onData: received.add);
    expect(iso.fire<String>('one', paths: ['echo']), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, ['echo: one']);

    expect(await iso.restart(), isTrue);
    expect(inits, ['init', 'init']);
    expect(iso.isInit, isTrue);

    // the same main-side subscription is still alive
    expect(iso.fire<String>('two', paths: ['echo']), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, ['echo: one', 'echo: two']);
    // the new worker's handler interest was re-synchronised
    expect(await iso.request<int>(21), 42);

    await sub.cancel();
    await iso.dispose();
    port.close();
  });

  test('restart fails pending requests', () async {
    final port = ReceivePort();
    port.listen((_) {});
    final iso =
        EventBusIsolate(onInit: lifecycleWorker, initialData: port.sendPort);
    await iso.waitInit;

    final pending = iso.request<int>(1, paths: ['slow']);
    final failed = expectLater(pending, throwsA(isA<EventBusException>()));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(await iso.restart(), isTrue);
    await failed;

    await iso.dispose();
    port.close();
  });

  test('restart after dispose throws StateError', () async {
    final port = ReceivePort();
    port.listen((_) {});
    final iso =
        EventBusIsolate(onInit: lifecycleWorker, initialData: port.sendPort);
    await iso.waitInit;
    await iso.dispose();

    await expectLater(iso.restart(), throwsStateError);
    port.close();
  });
}
