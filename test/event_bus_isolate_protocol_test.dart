import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

// --- functions that run IN THE WORKER (top-level only) ---

void silentWorker(EventBus bus, Object? initialData) {}

void doublingWorker(EventBus bus, Object? initialData) {
  bus.handlers.setHandler<int>(handler: (dto, lastData) async {
    dto.completer?.complete(dto.data * 2);
  });
}

///Asynchronous initialization: handlers do not appear immediately.
Future<void> slowInitWorker(EventBus bus, Object? initialData) async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
  bus.handlers.setHandler<String>(handler: (dto, lastData) async {
    dto.completer?.complete('ready: ${dto.data}');
  });
}

///Responses arrive in a different order than the requests.
void slowByValueWorker(EventBus bus, Object? initialData) {
  bus.handlers.setHandler<int>(handler: (dto, lastData) async {
    await Future<void>.delayed(Duration(milliseconds: dto.data == 1 ? 200 : 10));
    dto.completer?.complete(dto.data);
  });
}

void throwingWorker(EventBus bus, Object? initialData) {
  bus.handlers.setHandler<int>(handler: (dto, lastData) async {
    throw StateError('worker boom');
  });
}

///An event from the worker to main.
void echoWorker(EventBus bus, Object? initialData) {
  bus.subscribe<String>(onData: (e) => bus.send<String>('echo: $e'));
}

Future<void> failingInitWorker(EventBus bus, Object? initialData) async {
  throw StateError('init failed');
}

Future<void> failingLayerInit(Layer layer, Object? initialData) async {
  throw StateError('layer init failed');
}

// --- layers ---

class LayerPing {
  final int count;
  LayerPing(this.count);
}

Future<void> initMiddleLayer(Layer layer, Object? _) async {
  // if createLayers does not wait for initialization, the first event is lost
  await Future<void>.delayed(const Duration(milliseconds: 20));
  layer.top!.subscribe<LayerPing>(onData: (e) => layer.bottom!.send(LayerPing(e.count + 1)));
  layer.bottom!.subscribe<LayerPing>(onData: (e) => layer.top!.send(LayerPing(e.count + 1)));
}

Future<void> initBottomLayer(Layer layer, Object? _) async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
  layer.top!.subscribe<LayerPing>(onData: (e) => layer.top!.send(LayerPing(e.count + 1)));
}

void main() {
  group('EventBusIsolate: readiness', () {
    test('isInit becomes true only after waitInit', () async {
      final iso = EventBusIsolate(onInit: silentWorker);

      expect(iso.isInit, isFalse);
      await iso.waitInit;
      expect(iso.isInit, isTrue);
      await iso.dispose();
    });

    test('send before waitInit throws StateError', () async {
      final iso = EventBusIsolate(onInit: slowInitWorker);

      await expectLater(iso.send<String>('x'), throwsStateError);

      await iso.waitInit;
      await iso.dispose();
    });

    test('an event right after waitInit reaches the handler (async onInit)', () async {
      final iso = EventBusIsolate(onInit: slowInitWorker);
      await iso.waitInit;

      expect(await iso.send<String>('ping'), 'ready: ping');
      await iso.dispose();
    });

    test('an onInit error in the worker surfaces as a waitInit error', () async {
      final iso = EventBusIsolate(onInit: failingInitWorker);

      await expectLater(iso.waitInit, throwsA(isA<EventBusException>()));
      await iso.dispose();
    });

    test('ping confirms the worker is alive', () async {
      final iso = EventBusIsolate(onInit: silentWorker);
      await iso.waitInit;

      expect(await iso.ping(), isTrue);

      await iso.dispose();
      expect(await iso.ping(), isFalse);
    });
  });

  group('EventBusIsolate: response matching', () {
    test('concurrent requests of the same type get their own responses', () async {
      final iso = EventBusIsolate(onInit: slowByValueWorker);
      await iso.waitInit;

      final first = iso.send<int>(1); // responds later
      final second = iso.send<int>(2); // responds earlier

      expect(await second, 2);
      expect(await first, 1);
      await iso.dispose();
    });

    test('an event without a node in the worker does not hang the sender', () async {
      final iso = EventBusIsolate(onInit: silentWorker);
      await iso.waitInit;

      expect(await iso.send<String>('nobody').timeout(const Duration(seconds: 5)), null);
      await iso.dispose();
    });

    test('a handler error in the worker reaches the sender', () async {
      final iso = EventBusIsolate(onInit: throwingWorker);
      await iso.waitInit;

      await expectLater(iso.send<int>(1), throwsStateError);
      await iso.dispose();
    });

    test('events from the worker reach main', () async {
      final iso = EventBusIsolate(onInit: echoWorker);
      await iso.waitInit;
      final received = <String>[];
      final sub = iso.subscribe<String>(onData: received.add);

      await iso.send<String>('hi');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(received, ['echo: hi']);
      await sub.cancel();
      await iso.dispose();
    });

    test('dispose completes pending requests with an error', () async {
      final iso = EventBusIsolate(onInit: slowByValueWorker);
      await iso.waitInit;
      final pending = iso.send<int>(1); // the handler responds after 200 ms
      // the error expectation is attached in advance: the error arrives at dispose time
      final expectation = expectLater(pending, throwsA(isA<EventBusException>()));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await iso.dispose();

      await expectation;
    });

    test('send after dispose throws StateError', () async {
      final iso = EventBusIsolate(onInit: doublingWorker);
      await iso.waitInit;
      await iso.dispose();

      await expectLater(iso.send<int>(1), throwsStateError);
    });

    test('a repeated dispose is safe', () async {
      final iso = EventBusIsolate(onInit: doublingWorker);
      await iso.waitInit;

      await iso.dispose();
      await iso.dispose();

      expect(iso.isDisposed, isTrue);
    });
  });

  group('Layers', () {
    test('createLayers returns when the whole chain is initialized', () async {
      final layer = await Layers.createLayers([
        (initMiddleLayer, null, true),
        (initBottomLayer, null, true),
      ]);

      final answerFuture = layer.bottom!.listen<LayerPing>().first;
      layer.bottom!.send(LayerPing(0));
      final answer = await answerFuture;

      expect(answer.count, 3);
      await layer.close();
    });

    test('createLayers with an empty list throws EventBusException', () async {
      await expectLater(
          Layers.createLayers([]), throwsA(isA<EventBusException>()));
    });

    test('a layer initialization error reaches createLayers', () async {
      await expectLater(
        Layers.createLayers([(failingLayerInit, null, true)]),
        throwsA(isA<EventBusException>()),
      );
    });

    test('close closes the layer buses and can be repeated', () async {
      final layer = await Layers.createLayers([(initBottomLayer, null, true)]);
      final current = layer.current;

      await layer.close();
      await layer.close();

      expect(layer.top, isNull);
      expect(layer.bottom, isNull);
      expect(current.isDisposed, isTrue);
      await expectLater(current.send<String>('x'), throwsStateError);
    });
  });
}
