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
final ackKey = EventKey<Order>('ack');

Future<void> invoiceListener(EventBus bus, Object? _) async {
  bus.subscribe(invoiceKey, onEvent: (_) {});
}

Future<void> domainListener(EventBus bus, Object? _) async {
  bus.subscribe(domainPattern, onEvent: (event) => bus.fire(ackKey, event));
}

Future<void> invoiceHandler(EventBus bus, Object? _) async {
  bus.subscribe(invoiceKey, handler: (dto, last) async => dto.data.id);
}

Future<void> domainHandler(EventBus bus, Object? _) async {
  bus.subscribe(domainPattern,
      handler: (dto, last) async => (dto.data as Order).id);
}

Future<void> modelInvoiceInterest(EventBus bus, Object? _) async {
  final sub = bus.subscribe(invoiceKey, onEvent: (_) {});
  await sub.cancel();
}

void main() {
  test('fire does not accept an unrelated remote type', () async {
    final iso = EventBusIsolate(onInit: invoiceListener);
    await iso.waitInit;

    expect(iso.probeFire(orderKey, Order('A')).remoteListenerInterest, 0);
    expect(iso.fire(orderKey, Order('A')), isFalse);

    await iso.dispose();
  });

  test('fire accepts a remote supertype pattern listener', () async {
    final iso = EventBusIsolate(onInit: domainListener);
    await iso.waitInit;

    expect(iso.probeFire(orderKey, Order('A')).remoteListenerInterest, 1);
    final received = Completer<Order>();
    final sub = iso.subscribe(ackKey, onEvent: received.complete);

    expect(iso.fire(orderKey, Order('A')), isTrue);
    expect((await received.future.timeout(const Duration(seconds: 2))).id, 'A');

    await sub.cancel();
    await iso.dispose();
  });

  test('request does not route to a remote handler of another type', () async {
    final iso = EventBusIsolate(onInit: invoiceHandler);
    await iso.waitInit;

    expect(
        iso.probeRequest(orderKey, Order('A')).remoteHandlerInterest, isFalse);
    expect(iso.probeRequest(invoiceKey, Invoice('I')).remoteHandlerInterest,
        isTrue);
    await expectLater(
      iso.request(orderKey, Order('A')),
      throwsA(isA<NoHandlerException>()),
    );

    await iso.dispose();
  });

  test('request reaches a remote supertype pattern handler', () async {
    final iso = EventBusIsolate(onInit: domainHandler);
    await iso.waitInit;

    expect(await iso.request(orderKey, Order('A')), 'A');

    await iso.dispose();
  });

  test('model interest is typed', () async {
    final iso = EventBusIsolate(onInit: modelInvoiceInterest, isModelBus: true);
    await iso.waitInit;

    expect(iso.fire(orderKey, Order('A')), isFalse);

    await iso.dispose();
  });

  test('a local supertype handler wins over the bridge', () async {
    final iso = EventBusIsolate(onInit: invoiceHandler);
    await iso.waitInit;

    final local = iso.subscribe(domainPattern,
        handler: (dto, last) async => 'local:${(dto.data as Order).id}');

    expect(await iso.request(orderKey, Order('A')), 'local:A');

    await local.cancel();
    await iso.dispose();
  });
}
