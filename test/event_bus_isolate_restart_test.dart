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
  bus
      .listen(EventKey<String>('String.echo'))
      .listen((e) => bus.fire(EventKey<String>('String.echo'), 'echo: $e'));
  bus.subscribe(EventKey<int>('int.slow'), handler: (dto, lastData) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return dto.data;
  });
  bus.subscribe(EventKey<int>('int'),
      handler: (dto, lastData) async => dto.data * 2);
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
    final sub =
        iso.listen(EventKey<String>('String.echo')).listen(received.add);
    expect(iso.fire(EventKey<String>('String.echo'), 'one'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, ['echo: one']);

    expect(await iso.restart(), isTrue);
    expect(inits, ['init', 'init']);
    expect(iso.isInit, isTrue);

    // the same main-side subscription is still alive
    expect(iso.fire(EventKey<String>('String.echo'), 'two'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, ['echo: one', 'echo: two']);
    // the new worker's handler interest was re-synchronised
    expect(await iso.request(EventKey<int>('int'), 21), 42);

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

    final pending = iso.request(EventKey<int>('int.slow'), 1);
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
