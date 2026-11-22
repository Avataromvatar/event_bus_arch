import 'dart:async';
import 'dart:isolate';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

class Order {
  Order(this.id);
  final String id;
}

class Invoice {
  Invoice(this.id);
  final String id;
}

void main() {
  group('EventBusIsolate: E key API', () {
    test('fireKey reaches a worker listener', () async {
      final port = ReceivePort();
      final isolate = EventBusIsolate(
        onInit: (bus, data) {
          final out = data as SendPort;
          bus.subscribeEventsKey<Order>(EventKey<Order>('orders'),
              onEvent: (order) => out.send(order.id));
        },
        initialData: port.sendPort,
      );
      await isolate.waitInit;

      expect(isolate.fireKey(EventKey<Order>('orders'), Order('A-1')), isTrue);
      expect(await port.first.timeout(const Duration(seconds: 2)), 'A-1');

      port.close();
      await isolate.dispose();
    });

    test('a worker fireKey reaches a main listener', () async {
      final start = Completer<void>();
      final isolate = EventBusIsolate(
        onInit: (bus, data) {
          bus.subscribeEventsKey<String>(EventKey<String>('start'),
              onEvent: (_) {
            bus.fireKey(EventKey<Order>('orders'), Order('W-1'));
          });
        },
      );
      await isolate.waitInit;

      final received = <Order>[];
      final sub = isolate.subscribeEventsKey<Order>(
          EventKey<Order>('orders'), onEvent: (order) {
        received.add(order);
        if (!start.isCompleted) start.complete();
      });

      isolate.fireKey(EventKey<String>('start'), 'go');
      await start.future.timeout(const Duration(seconds: 2));

      expect(received.single.id, 'W-1');
      expect(isolate.currentDataKey(EventKey<Order>('orders'))?.id, 'W-1');

      await sub.cancel();
      await isolate.dispose();
    });

    test('requestKey reaches a worker handler and returns its result',
        () async {
      final isolate = EventBusIsolate(
        onInit: (bus, data) {
          bus.subscribeEventsKey<Order>(EventKey<Order>('orders'),
              handler: (dto, lastData) async => dto.data.id);
        },
      );
      await isolate.waitInit;

      expect(await isolate.requestKey(EventKey<Order>('orders'), Order('A-1')),
          'A-1');

      await isolate.dispose();
    });

    test('a pattern key on the worker matches a concrete main fire',
        () async {
      final port = ReceivePort();
      final isolate = EventBusIsolate(
        onInit: (bus, data) {
          final out = data as SendPort;
          bus.subscribeEventsKey<Order>(
              EventPatternKey<Order>('orders.*'),
              onEvent: (order) => out.send(order.id));
        },
        initialData: port.sendPort,
      );
      await isolate.waitInit;

      expect(
        isolate.fireKey(EventKey<Order>('orders.placed'), Order('A-1')),
        isTrue,
      );
      expect(await port.first.timeout(const Duration(seconds: 2)), 'A-1');

      port.close();
      await isolate.dispose();
    });

    test('removeKey and removeAddress remove nodes across the bridge',
        () async {
      final isolate = EventBusIsolate(onInit: (bus, data) {});
      await isolate.waitInit;

      final sub = isolate.subscribeEventsKey<Order>(
          EventKey<Order>('orders'), onEvent: (_) {});
      expect(isolate.removeKey(EventKey<Order>('orders')), isTrue);
      expect(isolate.haveListenerKey(EventKey<Order>('orders')), isFalse);

      final sub2 = isolate.subscribeEventsKey<Invoice>(
          EventKey<Invoice>('orders'), onEvent: (_) {});
      expect(isolate.removeAddress(EventAddress('orders')), isTrue);
      expect(isolate.haveListenerKey(EventKey<Invoice>('orders')), isFalse);

      await sub.cancel();
      await sub2.cancel();
      await isolate.dispose();
    });
  });
}
