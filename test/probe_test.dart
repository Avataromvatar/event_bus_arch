// ignore_for_file: deprecated_member_use
import 'dart:async';

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

final orderKey = EventKey<Order>('orders.placed');
final invoiceKey = EventKey<Invoice>('orders.placed');
final domainPattern = EventPatternKey<DomainEvent>('orders.*');

void main() {
  group('probeFire', () {
    test('counts a supertype pattern listener', () async {
      final bus = EventBus();
      final sub = bus.subscribe(domainPattern, onEvent: (_) {});

      final probe = bus.probeFire(orderKey, Order('A'));
      expect(probe.localListeners, 1);
      expect(probe.hasRawListener, isFalse);
      expect(probe.accepted, isTrue);

      await sub.cancel();
      await bus.dispose();
    });

    test('does not count a listener of another type', () async {
      final bus = EventBus();
      final sub = bus.subscribe(invoiceKey, onEvent: (_) {});

      final probe = bus.probeFire(orderKey, Order('A'));
      expect(probe.localListeners, 0);
      expect(probe.accepted, isFalse);

      await sub.cancel();
      await bus.dispose();
    });

    test('reports a raw listen listener', () async {
      final bus = EventBus();
      final streamSub = bus.listen(domainPattern).listen((_) {});

      final probe = bus.probeFire(orderKey, Order('A'));
      expect(probe.hasRawListener, isTrue);
      expect(probe.localListeners, 0);
      expect(probe.accepted, isTrue);

      await streamSub.cancel();
      await bus.dispose();
    });

    test('reports a model store without a listener', () async {
      final bus = EventBus(isModelBus: true);

      final probe = bus.probeFire(orderKey, Order('A'));
      expect(probe.modelStores, isTrue);
      expect(probe.accepted, isTrue);
      expect(bus.currentData(orderKey), isNull);

      await bus.dispose();
    });

    test('has no side effects', () async {
      final bus =
          EventBus(observability: const ObservabilityConfig(enabled: true));
      final events = <EventDTO>[];
      final all = bus.allEventStream.listen((event) => events.add(event.$1));

      final probe = bus.probeFire(orderKey, Order('A'));

      expect(probe.localListeners, 0);
      expect(bus.metrics.snapshot().fired, 0);
      expect(bus.currentData(orderKey), isNull);
      expect(events, isEmpty);

      await all.cancel();
      await bus.dispose();
    });

    test('keeps two exact types on one address separate', () async {
      final bus = EventBus();
      final orders = bus.subscribe(orderKey, onEvent: (_) {});
      final invoices = bus.subscribe(invoiceKey, onEvent: (_) {});

      expect(bus.probeFire(orderKey, Order('A')).localListeners, 1);
      expect(bus.probeFire(invoiceKey, Invoice('I')).localListeners, 1);

      await orders.cancel();
      await invoices.cancel();
      await bus.dispose();
    });
  });

  group('deprecated have* queries', () {
    test('haveHandler is exact-type and cannot see a foreign handler',
        () async {
      final bus = EventBus();
      final sub =
          bus.subscribe(invoiceKey, handler: (dto, last) async => dto.data.id);

      expect(bus.haveHandler(invoiceKey), isTrue);
      expect(bus.haveHandler(orderKey), isFalse);
      expect(bus.probeRequest(orderKey, Order('A')).localHandlers, 0);

      await sub.cancel();
      await bus.dispose();
    });

    test('haveListener stays exact while probeFire sees a supertype pattern',
        () async {
      final bus = EventBus();
      final sub = bus.subscribe(domainPattern, onEvent: (_) {});

      expect(bus.haveListener(orderKey), isFalse);
      expect(bus.probeFire(orderKey, Order('A')).localListeners, 1);

      await sub.cancel();
      await bus.dispose();
    });
  });

  group('probeRequest', () {
    test('counts an exact handler and its capacity', () async {
      final bus = EventBus();
      final sub = bus.subscribe(orderKey, handler: (dto, last) async => 1);

      final probe = bus.probeRequest(orderKey, Order('A'));
      expect(probe.localHandlers, 1);
      expect(probe.localAvailableHandlers, 1);
      expect(probe.hasHandler, isTrue);
      expect(probe.isBusy, isFalse);

      await sub.cancel();
      await bus.dispose();
    });

    test('does not count a handler of another type', () async {
      final bus = EventBus();
      final sub = bus.subscribe(invoiceKey, handler: (dto, last) async => 1);

      final probe = bus.probeRequest(orderKey, Order('A'));
      expect(probe.localHandlers, 0);
      expect(probe.hasHandler, isFalse);

      await sub.cancel();
      await bus.dispose();
    });

    test('a pattern handler accepts a subtype', () async {
      final bus = EventBus();
      final sub = bus.subscribe(domainPattern, handler: (dto, last) async => 1);

      final probe = bus.probeRequest(orderKey, Order('A'));
      expect(probe.localHandlers, 1);

      await sub.cancel();
      await bus.dispose();
    });

    test('reports a busy exact tier and does not count a pattern fallback',
        () async {
      final bus = EventBus();
      final gate = Completer<void>();
      final exact = bus.subscribe(orderKey, requestQueueCapacity: 0,
          handler: (dto, last) async {
        await gate.future;
        return 'exact';
      });
      final pattern =
          bus.subscribe(domainPattern, handler: (dto, last) async => 'pattern');

      final pending = bus.request(orderKey, Order('A'));
      await Future<void>.delayed(Duration.zero);

      final probe = bus.probeRequest(orderKey, Order('A'));
      expect(probe.localHandlers, 1);
      expect(probe.localAvailableHandlers, 0);
      expect(probe.isBusy, isTrue);

      gate.complete();
      expect(await pending, 'exact');

      await exact.cancel();
      await pattern.cancel();
      await bus.dispose();
    });

    test('has no side effects', () async {
      final bus =
          EventBus(observability: const ObservabilityConfig(enabled: true));
      final events = <EventDTO>[];
      final all = bus.allEventStream.listen((event) => events.add(event.$1));

      final probe = bus.probeRequest(orderKey, Order('A'));
      expect(probe.localHandlers, 0);
      expect(bus.metrics.snapshot().fired, 0);
      expect(events, isEmpty);

      await all.cancel();
      await bus.dispose();
    });
  });
}
