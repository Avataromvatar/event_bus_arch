import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('EventSubscription: delivery', () {
    test('delivers fire events to onEvent', () async {
      final bus = EventBus();
      final received = <int>[];
      final sub = bus.subscribeEvents<int>(
          paths: ['x'], onEvent: received.add);

      expect(bus.fire<int>(1, paths: ['x']), isTrue);
      await pump();
      expect(received, [1]);

      await sub.cancel();
      await bus.dispose();
    });

    test('async mode delivers outside fire', () async {
      final bus = EventBus();
      final order = <String>[];
      final sub = bus.subscribeEvents<int>(
          paths: ['x'], onEvent: (_) => order.add('event'));

      order.add('before');
      bus.fire<int>(1, paths: ['x']);
      order.add('after');
      expect(order, ['before', 'after']);

      await pump();
      expect(order, ['before', 'after', 'event']);

      await sub.cancel();
      await bus.dispose();
    });

    test('sync mode delivers inside fire', () async {
      final bus = EventBus();
      final order = <String>[];
      final sub = bus.subscribeEvents<int>(
          paths: ['x'],
          deliveryMode: DeliveryMode.sync,
          onEvent: (_) => order.add('event'));

      order.add('before');
      bus.fire<int>(1, paths: ['x']);
      order.add('after');
      expect(order, ['before', 'event', 'after']);

      await sub.cancel();
      await bus.dispose();
    });

    test('an async listener buffers events until its future completes',
        () async {
      final bus = EventBus(isModelBus: true);
      final received = <int>[];
      final gates = <Completer<void>>[];
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        bufferCapacity: 2,
        bufferOverflow: BufferOverflow.dropOldest,
        onEvent: (event) {
          received.add(event);
          final gate = Completer<void>();
          gates.add(gate);
          return gate.future;
        },
      );

      bus.fire<int>(1, paths: ['x']);
      await pump();
      expect(received, [1]);
      expect(sub.isBusy, isTrue);

      for (var value = 2; value <= 5; value++) {
        bus.fire<int>(value, paths: ['x']);
      }
      expect(sub.buffered, 2);
      expect(sub.dropped, 2);

      gates.first.complete();
      await pump();
      expect(received, [1, 4]);

      gates[1].complete();
      await pump();
      expect(received, [1, 4, 5]);

      gates[2].complete();
      await pump();
      expect(sub.isBusy, isFalse);

      await sub.cancel();
      await bus.dispose();
    });

    test('pause holds events until resume', () async {
      final bus = EventBus();
      final received = <int>[];
      final sub = bus.subscribeEvents<int>(
          paths: ['x'], onEvent: received.add);

      sub.pause();
      bus.fire<int>(1, paths: ['x']);
      bus.fire<int>(2, paths: ['x']);
      await pump();
      expect(received, isEmpty);
      expect(sub.buffered, 2);

      sub.resume();
      await pump();
      expect(received, [1, 2]);

      await sub.cancel();
      await bus.dispose();
    });

    test('reject overflow drops the incoming event', () async {
      final bus = EventBus();
      final received = <int>[];
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        bufferCapacity: 0,
        bufferOverflow: BufferOverflow.reject,
        onEvent: received.add,
      );

      sub.pause();
      bus.fire<int>(1, paths: ['x']);
      await pump();
      expect(received, isEmpty);
      expect(sub.dropped, 1);

      sub.resume();
      await pump();
      expect(received, isEmpty);

      await sub.cancel();
      await bus.dispose();
    });

    test('capacity 0 still delivers when the listener is idle', () async {
      final bus = EventBus();
      final received = <int>[];
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        bufferCapacity: 0,
        bufferOverflow: BufferOverflow.reject,
        onEvent: received.add,
      );

      bus.fire<int>(1, paths: ['x']);
      await pump();
      expect(received, [1]);

      bus.fire<int>(2, paths: ['x']);
      await pump();
      expect(received, [1, 2]);
      expect(sub.dropped, 0);

      await sub.cancel();
      await bus.dispose();
    });

    test('capacity 0 rejects while an async listener is busy', () async {
      final bus = EventBus();
      final received = <int>[];
      final gate = Completer<void>();
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        bufferCapacity: 0,
        bufferOverflow: BufferOverflow.reject,
        onEvent: (event) {
          received.add(event);
          return gate.future;
        },
      );

      bus.fire<int>(1, paths: ['x']);
      await pump();
      expect(received, [1]);
      expect(sub.isBusy, isTrue);

      bus.fire<int>(2, paths: ['x']);
      expect(sub.dropped, 1);

      gate.complete();
      await pump();
      expect(received, [1]);

      await sub.cancel();
      await bus.dispose();
    });

    test('dropNewest keeps the oldest buffered events', () async {
      final bus = EventBus();
      final received = <int>[];
      final gates = <Completer<void>>[];
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        bufferCapacity: 1,
        bufferOverflow: BufferOverflow.dropNewest,
        onEvent: (event) {
          received.add(event);
          final gate = Completer<void>();
          gates.add(gate);
          return gate.future;
        },
      );

      bus.fire<int>(1, paths: ['x']);
      await pump();
      bus.fire<int>(2, paths: ['x']);
      bus.fire<int>(3, paths: ['x']);
      expect(sub.buffered, 1);
      expect(sub.dropped, 1);

      gates.first.complete();
      await pump();
      expect(received, [1, 2]);

      gates[1].complete();
      await pump();
      expect(received, [1, 2]);

      await sub.cancel();
      await bus.dispose();
    });

    test('resize shrinks the buffer by the current policy', () async {
      final bus = EventBus();
      final received = <int>[];
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        bufferCapacity: 3,
        onEvent: received.add,
      );

      sub.pause();
      for (var value = 1; value <= 4; value++) {
        bus.fire<int>(value, paths: ['x']);
      }
      expect(sub.buffered, 3);
      expect(sub.dropped, 1);

      sub.resize(1);
      expect(sub.buffered, 1);
      expect(sub.dropped, 3);

      sub.resume();
      await pump();
      expect(received, [4]);

      await sub.cancel();
      await bus.dispose();
    });

    test('the stream view receives delivered events', () async {
      final bus = EventBus();
      final events = <int>[];
      final sub = bus.subscribeEvents<int>(paths: ['x'], onEvent: (_) {});
      final view = sub.stream.listen(events.add);

      bus.fire<int>(7, paths: ['x']);
      await pump();
      expect(events, [7]);

      await view.cancel();
      await sub.cancel();
      await bus.dispose();
    });
  });

  group('EventSubscription: lifecycle', () {
    test('subscription counts as a listener and keeps the node', () async {
      final bus = EventBus(isModelBus: true);
      final sub = bus.subscribeEvents<int>(paths: ['x'], onEvent: (_) {});
      expect(bus.haveListener<int>(paths: ['x']), isTrue);

      bus.fire<int>(1, paths: ['x']);
      await sub.cancel();
      expect(bus.haveListener<int>(paths: ['x']), isFalse);
      // Model bus keeps the value after the subscription.
      expect(bus.currentData<int>(paths: ['x']), 1);

      await bus.dispose();
    });

    test('cancel removes the node on a common bus', () async {
      final bus = EventBus();
      final sub = bus.subscribeEvents<int>(paths: ['x'], onEvent: (_) {});

      await sub.cancel();
      expect(bus.haveListener<int>(paths: ['x']), isFalse);
      expect(bus.fire<int>(1, paths: ['x']), isFalse);

      await bus.dispose();
    });

    test('removeTopic closes the subscription and calls onDone', () async {
      final bus = EventBus();
      var done = false;
      final sub = bus.subscribeEvents<int>(
          paths: ['x'], onEvent: (_) {}, onDone: () => done = true);

      expect(bus.removeTopic<int>(paths: ['x']), isTrue);
      await pump();
      expect(sub.isCanceled, isTrue);
      expect(done, isTrue);

      await bus.dispose();
    });

    test('a repeated cancel is safe', () async {
      final bus = EventBus();
      final sub = bus.subscribeEvents<int>(paths: ['x'], onEvent: (_) {});

      await sub.cancel();
      await sub.cancel();

      await bus.dispose();
    });
  });

  group('legacy stream facade', () {
    test('listen delivers asynchronously', () async {
      final bus = EventBus();
      final order = <String>[];
      final sub = bus.subscribe<int>(
          paths: ['x'], onData: (_) => order.add('event'));

      order.add('before');
      bus.fire<int>(1, paths: ['x']);
      order.add('after');
      expect(order, ['before', 'after']);

      await pump();
      expect(order, ['before', 'after', 'event']);

      await sub.cancel();
      await bus.dispose();
    });

    test('pause and resume propagate to the node stream', () async {
      final bus = EventBus();
      final received = <int>[];
      final sub = bus.subscribe<int>(paths: ['x'], onData: received.add);

      sub.pause();
      bus.fire<int>(1, paths: ['x']);
      await pump();
      expect(received, isEmpty);

      sub.resume();
      await pump();
      expect(received, [1]);

      await sub.cancel();
      await bus.dispose();
    });

    test('a node stream view supports several listeners', () async {
      final bus = EventBus();
      final first = <int>[];
      final second = <int>[];
      final stream = bus.listen<int>(paths: ['x']);
      final sub1 = stream.listen(first.add);
      final sub2 = stream.listen(second.add);

      bus.fire<int>(1, paths: ['x']);
      await pump();
      expect(first, [1]);
      expect(second, [1]);

      await sub1.cancel();
      expect(bus.haveListener<int>(paths: ['x']), isTrue);
      await sub2.cancel();
      expect(bus.haveListener<int>(paths: ['x']), isFalse);

      await bus.dispose();
    });
  });

  group('EventSubscription: errors', () {
    test('a synchronous callback error reaches onError and delivery continues',
        () async {
      final bus = EventBus();
      final errors = <Object>[];
      final received = <int>[];
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        onEvent: (event) {
          if (event == 1) throw StateError('boom');
          received.add(event);
        },
        onError: (error, stackTrace) => errors.add(error),
      );

      bus.fire<int>(1, paths: ['x']);
      bus.fire<int>(2, paths: ['x']);
      await pump();
      expect(errors, hasLength(1));
      expect(errors.single, isA<StateError>());
      expect(received, [2]);

      await sub.cancel();
      await bus.dispose();
    });

    test('an asynchronous callback error reaches onError', () async {
      final bus = EventBus();
      final errors = <Object>[];
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        onEvent: (event) async {
          await Future<void>.delayed(Duration.zero);
          throw StateError('boom');
        },
        onError: (error, stackTrace) => errors.add(error),
      );

      bus.fire<int>(1, paths: ['x']);
      await pump();
      await pump();
      expect(errors, hasLength(1));

      await sub.cancel();
      await bus.dispose();
    });

    test('cancelOnError cancels the subscription', () async {
      final bus = EventBus();
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        cancelOnError: true,
        onEvent: (_) => throw StateError('boom'),
        onError: (_, __) {},
      );

      bus.fire<int>(1, paths: ['x']);
      await pump();
      expect(sub.isCanceled, isTrue);
      expect(bus.haveListener<int>(paths: ['x']), isFalse);

      await bus.dispose();
    });
  });
}
