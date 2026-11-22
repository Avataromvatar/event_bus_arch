import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

class DomainEvent {}

class Order extends DomainEvent {
  Order(this.id);
  final String id;
}

class Invoice extends DomainEvent {
  Invoice(this.id);
  final String id;
}

Future<void> _pump() => pumpEventQueue();

void main() {
  group('EventBus: E key API', () {
    test('fireKey and subscribeEventsKey deliver on an exact key', () async {
      final bus = EventBus();
      final received = <int>[];
      final key = EventKey<int>('counter');

      final sub = bus.subscribeEventsKey<int>(key, onEvent: received.add);
      expect(bus.fireKey(key, 1), isTrue);
      expect(bus.fireKey(key, 2), isTrue);
      await _pump();

      expect(received, [1, 2]);
      expect(bus.currentDataKey(key), 2);
      await sub.cancel();
      await bus.dispose();
    });

    test('different types on one address have separate nodes and values',
        () async {
      final bus = EventBus();
      final orders = <Order>[];
      final invoices = <Invoice>[];
      final orderKey = EventKey<Order>('orders');
      final invoiceKey = EventKey<Invoice>('orders');

      final orderSub =
          bus.subscribeEventsKey<Order>(orderKey, onEvent: orders.add);
      final invoiceSub =
          bus.subscribeEventsKey<Invoice>(invoiceKey, onEvent: invoices.add);

      bus.fireKey(orderKey, Order('A-1'));
      await _pump();
      expect(orders, hasLength(1));
      expect(invoices, isEmpty);
      expect(bus.currentDataKey(orderKey)?.id, 'A-1');
      expect(bus.currentDataKey(invoiceKey), isNull);

      bus.fireKey(invoiceKey, Invoice('I-1'));
      await _pump();
      expect(orders, hasLength(1));
      expect(invoices, hasLength(1));
      expect(bus.currentDataKey(invoiceKey)?.id, 'I-1');

      await orderSub.cancel();
      await invoiceSub.cancel();
      await bus.dispose();
    });

    test('a supertype key accepts subtype data on the same address', () async {
      final bus = EventBus();
      final seen = <DomainEvent>[];
      final domainKey = EventKey<DomainEvent>('events');

      final sub = bus.subscribeEventsKey<DomainEvent>(domainKey,
          onEvent: seen.add);
      bus.fireKey(EventKey<Order>('events'), Order('A-1'));
      await _pump();

      expect(seen, hasLength(1));
      expect(seen.single, isA<Order>());
      expect(bus.currentDataKey(domainKey), isA<Order>());

      await sub.cancel();
      await bus.dispose();
    });

    test('a pattern key receives concrete addresses of its type', () async {
      final bus = EventBus();
      final received = <Order>[];
      final pattern = EventPatternKey<Order>('orders.*');

      final sub =
          bus.subscribeEventsKey<Order>(pattern, onEvent: received.add);
      bus.fireKey(EventKey<Order>('orders.placed'), Order('A-1'));
      bus.fireKey(EventKey<Invoice>('orders.placed'), Invoice('I-1'));
      await _pump();

      expect(received, hasLength(1));
      expect(received.single.id, 'A-1');
      expect(
          bus.haveListenerKey<Order>(EventKey<Order>('orders.placed')), isTrue);
      expect(
          bus.haveListenerKey<Invoice>(EventKey<Invoice>('orders.placed')),
          isFalse,
          reason: 'the Invoice key has no listener of its own');

      await sub.cancel();
      await bus.dispose();
    });

    test('requestKey resolves an exact handler before a pattern handler',
        () async {
      final bus = EventBus();
      final patternKey = EventPatternKey<int>('sensor.*');
      final exactKey = EventKey<int>('sensor.temp');

      final patternSub = bus.subscribeEventsKey<int>(patternKey,
          handler: (dto, lastData) async => 'pattern');
      final exactSub = bus.subscribeEventsKey<int>(exactKey,
          handler: (dto, lastData) async => 'exact');

      expect(await bus.requestKey(exactKey, 1), 'exact');
      expect(await bus.requestKey(EventKey<int>('sensor.humidity'), 1),
          'pattern');

      await patternSub.cancel();
      await exactSub.cancel();
      await bus.dispose();
    });

    test('a request handler keyed by a supertype answers subtype data',
        () async {
      final bus = EventBus();
      final domainPattern = EventPatternKey<DomainEvent>('orders.*');
      final sub = bus.subscribeEventsKey<DomainEvent>(domainPattern,
          handler: (dto, lastData) async => dto.data.runtimeType);

      final result = await bus.requestKey(
          EventKey<Order>('orders.placed'), Order('A-1'));
      expect(result, Order);

      await sub.cancel();
      await bus.dispose();
    });

    test('a type mismatch has no handler', () async {
      final bus = EventBus();
      final sub = bus.subscribeEventsKey<Order>(EventKey<Order>('orders'),
          handler: (dto, lastData) async => dto.data);

      await expectLater(
        bus.requestKey(EventKey<Invoice>('orders'), Invoice('I-1')),
        throwsA(isA<NoHandlerException>()),
      );

      await sub.cancel();
      await bus.dispose();
    });

    test('removeKey removes one type and keeps the other types', () async {
      final bus = EventBus();
      final orderKey = EventKey<Order>('orders');
      final invoiceKey = EventKey<Invoice>('orders');
      final orderSub =
          bus.subscribeEventsKey<Order>(orderKey, onEvent: (_) {});
      final invoiceSub =
          bus.subscribeEventsKey<Invoice>(invoiceKey, onEvent: (_) {});

      expect(bus.removeKey(orderKey), isTrue);
      expect(bus.currentDataKey(orderKey), isNull);
      expect(bus.haveListenerKey(invoiceKey), isTrue);

      expect(bus.removeAddress(EventAddress('orders')), isTrue);
      expect(bus.haveListenerKey(invoiceKey), isFalse);

      await orderSub.cancel();
      await invoiceSub.cancel();
      await bus.dispose();
    });

    test('haveHandlerKey and haveAvailableHandlerKey see the typed selector',
        () async {
      final bus = EventBus();
      final key = EventKey<int>('counter');
      final pattern = EventPatternKey<int>('counter.*');
      final sub = bus.subscribeEventsKey<int>(key,
          handler: (dto, lastData) async => dto.data);

      expect(bus.haveHandlerKey(key), isTrue);
      expect(bus.haveAvailableHandlerKey(key), isTrue);
      expect(bus.haveHandlerKey(pattern), isFalse);

      await sub.cancel();
      expect(bus.haveHandlerKey(key), isFalse);
      await bus.dispose();
    });

    test('a model bus keeps separate values per key', () async {
      final bus = EventBus(isModelBus: true);
      final orderKey = EventKey<Order>('orders');
      final invoiceKey = EventKey<Invoice>('orders');

      bus.fireKey(orderKey, Order('A-1'));
      bus.fireKey(invoiceKey, Invoice('I-1'));

      expect(bus.currentDataKey(orderKey)?.id, 'A-1');
      expect(bus.currentDataKey(invoiceKey)?.id, 'I-1');
      await bus.dispose();
    });

    test('metrics use the stable address', () async {
      final bus = EventBus(
          observability: const ObservabilityConfig(enabled: true));
      final key = EventKey<Order>('orders.placed');

      bus.fireKey(key, Order('A-1'));
      final snapshot = bus.metrics.snapshot();

      expect(snapshot.fired, 1);
      expect(snapshot.topics.single.key, 'orders.placed');
      expect(snapshot.topics.single.dropped, 1);

      await bus.dispose();
    });

    test('EventBusError exposes address', () {
      final error = EventBusError(
        kind: EventBusErrorKind.listener,
        topic: 'orders.placed',
        error: StateError('boom'),
      );

      expect(error.address, 'orders.placed');
      expect(error.topic, 'orders.placed');
    });

    test('EventDTO.withKey carries the key and the stable address', () {
      final key = EventKey<int>('counter');
      final dto = EventDTO.withKey(key, 1);

      expect(dto.key, key);
      expect(dto.address, 'counter');
      expect(dto.topic.topic, 'counter');
      expect(dto.toJson()['topic'], 'counter');
    });
  });
}
