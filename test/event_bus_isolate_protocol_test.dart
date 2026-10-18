import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

// --- functions that run IN THE WORKER (top-level only) ---

void silentWorker(EventBus bus, Object? initialData) {}

void doublingWorker(EventBus bus, Object? initialData) {
  bus.handlers.setHandler<int>(handler: (dto, lastData) async {
    return dto.data * 2;
  });
}

///Asynchronous initialization: handlers do not appear immediately.
Future<void> slowInitWorker(EventBus bus, Object? initialData) async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
  bus.handlers.setHandler<String>(handler: (dto, lastData) async {
    return 'ready: ${dto.data}';
  });
}

///Responses arrive in a different order than the requests.
void slowByValueWorker(EventBus bus, Object? initialData) {
  bus.handlers.setHandler<int>(handler: (dto, lastData) async {
    await Future<void>.delayed(
        Duration(milliseconds: dto.data == 1 ? 200 : 10));
    return dto.data;
  });
}

void throwingWorker(EventBus bus, Object? initialData) {
  bus.handlers.setHandler<int>(handler: (dto, lastData) async {
    throw StateError('worker boom');
  });
}

///An event from the worker to main.
void echoWorker(EventBus bus, Object? initialData) {
  bus.subscribe<String>(onData: (e) => bus.fire<String>('echo: $e'));
}

Future<void> failingInitWorker(EventBus bus, Object? initialData) async {
  throw StateError('init failed');
}

///Answers with the arguments of the call, so a lost arguments map is visible.
void argumentWorker(EventBus bus, Object? initialData) {
  bus.handlers.setHandler<String>(handler: (dto, lastData) async {
    return 'multiplier=${dto.arguments?['multiplier']}';
  });
}

///A handler addressed by paths, not by the type alone.
void pathWorker(EventBus bus, Object? initialData) {
  bus.handlers.setHandler<int>(
      paths: ['counter'],
      handler: (dto, lastData) async {
        return dto.data * 2;
      });
}

///A request responder registered on a wildcard path.
void patternHandlerWorker(EventBus bus, Object? initialData) {
  bus.handlers.setHandler<int>(
      paths: ['sensor', '*'], handler: (dto, lastData) async => dto.data * 2);
}

///A pattern listener that echoes events back to main.
void patternEchoWorker(EventBus bus, Object? initialData) {
  bus.subscribe<String>(
      paths: ['*'], onData: (e) => bus.fire<String>('echo: $e'));
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
  layer.top!.subscribe<LayerPing>(
      onData: (e) => layer.bottom!.fire(LayerPing(e.count + 1)));
  layer.bottom!.subscribe<LayerPing>(
      onData: (e) => layer.top!.fire(LayerPing(e.count + 1)));
}

Future<void> initBottomLayer(Layer layer, Object? _) async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
  layer.top!.subscribe<LayerPing>(
      onData: (e) => layer.top!.fire(LayerPing(e.count + 1)));
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

      await expectLater(iso.request<String>('x'), throwsStateError);

      await iso.waitInit;
      await iso.dispose();
    });

    test('an event right after waitInit reaches the handler (async onInit)',
        () async {
      final iso = EventBusIsolate(onInit: slowInitWorker);
      await iso.waitInit;

      expect(await iso.request<String>('ping'), 'ready: ping');
      await iso.dispose();
    });

    test('an onInit error in the worker surfaces as a waitInit error',
        () async {
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
    test('concurrent requests of the same type get their own responses',
        () async {
      final iso = EventBusIsolate(onInit: slowByValueWorker);
      await iso.waitInit;

      final first = iso.request<int>(1); // responds later
      final second = iso.request<int>(2); // responds earlier

      expect(await second, 2);
      expect(await first, 1);
      await iso.dispose();
    });

    test('an event without a node in the worker does not hang the sender',
        () async {
      final iso = EventBusIsolate(onInit: silentWorker);
      await iso.waitInit;

      await expectLater(
        iso.request<String>('nobody').timeout(const Duration(seconds: 5)),
        throwsA(isA<NoHandlerException>()),
      );
      await iso.dispose();
    });

    test('a handler error in the worker reaches the sender', () async {
      final iso = EventBusIsolate(onInit: throwingWorker);
      await iso.waitInit;

      await expectLater(iso.request<int>(1), throwsStateError);
      await iso.dispose();
    });

    test('events from the worker reach main', () async {
      final iso = EventBusIsolate(onInit: echoWorker);
      await iso.waitInit;
      final received = <String>[];
      final sub = iso.subscribe<String>(onData: received.add);

      iso.fire<String>('hi');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(received, ['echo: hi']);
      await sub.cancel();
      await iso.dispose();
    });

    test('dispose completes pending requests with an error', () async {
      final iso = EventBusIsolate(onInit: slowByValueWorker);
      await iso.waitInit;
      final pending = iso.request<int>(1); // the handler responds after 200 ms
      // the error expectation is attached in advance: the error arrives at dispose time
      final expectation =
          expectLater(pending, throwsA(isA<EventBusException>()));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await iso.dispose();

      await expectation;
    });

    test('send after dispose throws StateError', () async {
      final iso = EventBusIsolate(onInit: doublingWorker);
      await iso.waitInit;
      await iso.dispose();

      await expectLater(iso.request<int>(1), throwsStateError);
    });

    test('a repeated dispose is safe', () async {
      final iso = EventBusIsolate(onInit: doublingWorker);
      await iso.waitInit;

      await iso.dispose();
      await iso.dispose();

      expect(iso.isDisposed, isTrue);
    });
  });

  group('EventBusIsolate: addressing', () {
    test('the arguments of a call reach the worker handler', () async {
      final iso = EventBusIsolate(onInit: argumentWorker);
      await iso.waitInit;

      expect(await iso.request<String>('x', arguments: {'multiplier': '10'}),
          'multiplier=10');
      await iso.dispose();
    });

    test('a worker handler is addressed by paths', () async {
      final iso = EventBusIsolate(onInit: pathWorker);
      await iso.waitInit;

      expect(await iso.request<int>(21, paths: ['counter']), 42);
      // another path is another topic: the worker has no node for it
      await expectLater(
        iso.request<int>(21,
            paths: ['other']).timeout(const Duration(seconds: 5)),
        throwsA(isA<NoHandlerException>()),
      );
      await iso.dispose();
    });
  });

  group('EventBusIsolate: wildcards', () {
    test('a request is answered by a pattern handler in the worker', () async {
      final iso = EventBusIsolate(onInit: patternHandlerWorker);
      await iso.waitInit;

      expect(await iso.request<int>(21, paths: ['sensor', 'temp']), 42);
      await iso.dispose();
    });

    test('a fire event reaches a pattern listener in the worker', () async {
      final iso = EventBusIsolate(onInit: patternEchoWorker);
      await iso.waitInit;
      final received = <String>[];
      final sub = iso.subscribe<String>(onData: received.add);

      iso.fire<String>('hi', paths: ['x']);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(received, ['echo: hi']);
      await sub.cancel();
      await iso.dispose();
    });
  });

  group('Layers', () {
    test('createLayers returns when the whole chain is initialized', () async {
      final layer = await Layers.createLayers([
        (initMiddleLayer, null, true),
        (initBottomLayer, null, true),
      ]);

      final answerFuture = layer.bottom!.listen<LayerPing>().first;
      layer.bottom!.fire(LayerPing(0));
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
      expect(() => current.fire<String>('x'), throwsStateError);
    });
  });
}
