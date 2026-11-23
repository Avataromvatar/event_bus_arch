import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

Future<void> pump() => Future<void>.delayed(Duration.zero);

final key = EventKey<int>('x');

void main() {
  group('EventSubscription: buffer defaults', () {
    test('a managed listener defaults to 1024', () async {
      final bus = EventBus();
      final sub = bus.subscribe(key, onEvent: (_) {});

      expect(sub.bufferCapacity, 1024);

      await sub.cancel();
      await bus.dispose();
    });

    test('null is explicit unbounded', () async {
      final bus = EventBus();
      final sub = bus.subscribe(key, bufferCapacity: null, onEvent: (_) {});

      expect(sub.bufferCapacity, isNull);

      await sub.cancel();
      await bus.dispose();
    });
  });

  group('EventSubscription: overflow policy', () {
    test('latest drops the whole stale backlog and keeps the newest event',
        () async {
      final bus = EventBus();
      final received = <int>[];
      final gate = Completer<void>();
      final sub = bus.subscribe(
        key,
        bufferCapacity: 3,
        bufferOverflow: BufferOverflow.latest,
        onEvent: (event) {
          received.add(event);
          return gate.future;
        },
      );

      bus.fire(key, 1);
      await pump();
      expect(received, [1]);

      for (var value = 2; value <= 5; value++) {
        bus.fire(key, value);
      }
      await pump();

      expect(sub.buffered, 1);
      expect(sub.dropped, 3);

      gate.complete();
      await pump();
      expect(received, [1, 5]);

      await sub.cancel();
      await bus.dispose();
    });

    test('dropOldest keeps a sliding window', () async {
      final bus = EventBus();
      final received = <int>[];
      final gate = Completer<void>();
      final sub = bus.subscribe(
        key,
        bufferCapacity: 3,
        bufferOverflow: BufferOverflow.dropOldest,
        onEvent: (event) {
          received.add(event);
          return gate.future;
        },
      );

      bus.fire(key, 1);
      await pump();
      expect(received, [1]);

      for (var value = 2; value <= 5; value++) {
        bus.fire(key, value);
      }
      await pump();

      expect(sub.buffered, 3);
      expect(sub.dropped, 1);

      gate.complete();
      await pump();
      expect(received, [1, 3, 4, 5]);

      await sub.cancel();
      await bus.dispose();
    });
  });

  group('EventSubscription: queued request cancellation', () {
    test('cancelling the subscription cancels queued requests', () async {
      final bus = EventBus();
      final gate = Completer<void>();
      final sub = bus.subscribe(
        key,
        requestQueueCapacity: 1,
        handler: (dto, last) async {
          await gate.future;
          return dto.data;
        },
      );

      final first = bus.request(key, 1);
      final second = bus.request(key, 2);
      final secondCheck =
          expectLater(second, throwsA(isA<RequestCanceledException>()));
      await pump();

      await sub.cancel();
      await secondCheck;

      gate.complete();
      expect(await first, 1);

      await bus.dispose();
    });

    test('disposing the bus cancels queued requests', () async {
      final bus = EventBus();
      final gate = Completer<void>();
      bus.subscribe(
        key,
        requestQueueCapacity: 1,
        handler: (dto, last) async {
          await gate.future;
          return dto.data;
        },
      );

      final first = bus.request(key, 1);
      final second = bus.request(key, 2);
      final secondCheck =
          expectLater(second, throwsA(isA<RequestCanceledException>()));
      await pump();

      await bus.dispose();
      await secondCheck;

      gate.complete();
      expect(await first, 1);
    });
  });
}
