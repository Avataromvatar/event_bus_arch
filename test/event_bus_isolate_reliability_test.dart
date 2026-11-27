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

void noopOnInit(EventBus bus, Object? initialData) {}

class CountingRemoveIsolate extends EventBusIsolate {
  CountingRemoveIsolate() : super(onInit: noopOnInit);

  int removeAddressCalls = 0;

  @override
  bool removeAddress(EventAddress address) {
    removeAddressCalls++;
    return super.removeAddress(address);
  }
}

Future<void> hungOnInit(EventBus bus, Object? initialData) async {
  await Completer<void>().future;
}

Future<void> slowOnInit(EventBus bus, Object? initialData) async {
  await Future<void>.delayed(const Duration(milliseconds: 300));
}

///Reports its reply port to [initialData] and waits for the main side to send
///the initialization delay. The first worker is never answered, so it hangs.
Future<void> controllableOnInit(EventBus bus, Object? initialData) async {
  final control = initialData as SendPort;
  final replies = ReceivePort();
  control.send(replies.sendPort);
  final delay = await replies.first as int;
  replies.close();
  if (delay > 0) {
    await Future<void>.delayed(Duration(milliseconds: delay));
  }
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

    test('initTimeout fails a hung waitInit and aborts the bridge', () async {
      final iso = EventBusIsolate(
        onInit: hungOnInit,
        initTimeout: const Duration(milliseconds: 50),
      );
      final errors = <EventBusError>[];
      final errorSub = iso.errors.listen(errors.add);

      await expectLater(iso.waitInit, throwsA(isA<EventBusException>()));
      await Future<void>.delayed(Duration.zero);

      expect(iso.isInit, isFalse);
      expect(await iso.ping(), isFalse);
      expect(() => iso.fire(echoKey, 1), throwsStateError);
      await expectLater(iso.request(echoKey, 1), throwsStateError);
      expect(
          errors.where((error) => error.kind == EventBusErrorKind.isolateInit),
          hasLength(1));
      expect(
          errors.where((error) => error.kind == EventBusErrorKind.isolateDeath),
          isEmpty);

      await errorSub.cancel();
      await iso.dispose();
    });

    test('a late ready cannot revive a timed-out bridge', () async {
      final iso = EventBusIsolate(
        onInit: slowOnInit,
        initTimeout: const Duration(milliseconds: 50),
      );

      await expectLater(iso.waitInit, throwsA(isA<EventBusException>()));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(iso.isInit, isFalse);
      expect(await iso.ping(), isFalse);
      expect(() => iso.fire(echoKey, 1), throwsStateError);
      await expectLater(iso.request(echoKey, 1), throwsStateError);

      await iso.dispose();
    });

    test('restart after a timeout reaches a fresh worker', () async {
      final control = ReceivePort();
      var attempts = 0;
      control.listen((message) {
        if (message is! SendPort) return;
        attempts++;
        if (attempts > 1) message.send(0);
      });
      final iso = EventBusIsolate(
        onInit: controllableOnInit,
        initialData: control.sendPort,
        initTimeout: const Duration(milliseconds: 100),
      );

      await expectLater(iso.waitInit, throwsA(isA<EventBusException>()));
      expect(iso.isInit, isFalse);

      expect(await iso.restart(), isTrue);
      expect(iso.isInit, isTrue);
      expect(await iso.ping(), isTrue);

      await iso.dispose();
      control.close();
    });

    test('a blocked main isolate does not make the watchdog kill the worker',
        () async {
      final iso = EventBusIsolate(onInit: noopOnInit);
      await iso.waitInit;

      final end = DateTime.now().add(const Duration(milliseconds: 1800));
      while (DateTime.now().isBefore(end)) {
        // Emulate a long synchronous operation on the main isolate.
      }

      expect(iso.isInit, isTrue);
      expect(await iso.ping(timeout: const Duration(seconds: 2)), isTrue);

      await iso.dispose();
    });

    test('removeAddress is directional and does not echo between isolates',
        () async {
      final iso = CountingRemoveIsolate();
      await iso.waitInit;

      iso.removeAddress(EventAddress('loop.check'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(iso.removeAddressCalls, 1);

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
