import 'dart:async';
import 'dart:isolate';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

// --- workers (top-level only: they run in separate isolates) ---

final echoKey = EventKey<int>('echo');
final slowKey = EventKey<int>('slow');

void echoWorker(EventBus bus, Object? initialData) {
  bus.subscribe(echoKey, handler: (dto, last) async => dto.data * 2);
}

void slowWorker(EventBus bus, Object? initialData) {
  bus.subscribe(slowKey, handler: (dto, last) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return dto.data;
  });
}

void exitOnInit(EventBus bus, Object? initialData) {
  Isolate.current.kill(priority: Isolate.immediate);
}

Future<void> hungOnInit(EventBus bus, Object? initialData) async {
  await Completer<void>().future;
}

void main() {
  group('EventBusIsolate: initialization', () {
    test('a worker that exits during onInit fails waitInit', () async {
      final iso = EventBusIsolate(
        onInit: exitOnInit,
        initTimeout: const Duration(seconds: 5),
      );

      await expectLater(iso.waitInit, throwsA(isA<EventBusException>()));
      await iso.dispose();
    });

    test('initTimeout fails a hung waitInit', () async {
      final iso = EventBusIsolate(
        onInit: hungOnInit,
        initTimeout: const Duration(milliseconds: 50),
      );

      await expectLater(iso.waitInit, throwsA(isA<EventBusException>()));
      await iso.dispose();
    });

    test('initTimeout: null disables the timeout', () async {
      final iso = EventBusIsolate(onInit: hungOnInit, initTimeout: null);

      await expectLater(
        iso.waitInit.timeout(const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()),
      );
      await iso.dispose();
    });
  });

  group('EventBusIsolate: request cancellation', () {
    test('a long-lived CancelToken does not retain listeners', () async {
      final iso = EventBusIsolate(onInit: echoWorker);
      await iso.waitInit;
      final token = CancelToken();

      for (var i = 1; i <= 50; i++) {
        expect(await iso.request(echoKey, i, cancelToken: token), i * 2);
      }
      expect(token.listenerCount, 0);

      await iso.dispose();
    });

    test('cancellation fails the pending request and removes its listener',
        () async {
      final iso = EventBusIsolate(onInit: slowWorker);
      await iso.waitInit;
      final token = CancelToken();

      final pending = iso.request(slowKey, 7, cancelToken: token);
      await Future<void>.delayed(Duration.zero);
      token.cancel();

      await expectLater(pending, throwsA(isA<RequestCanceledException>()));
      expect(token.listenerCount, 0);

      // The worker finishes the handler later; its response is ignored.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await iso.dispose();
    });
  });
}
