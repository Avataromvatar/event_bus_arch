import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';
import 'package:event_bus_arch_transport/testing.dart';
import 'package:test/test.dart';

class _DotGrammar extends SubjectGrammar {
  const _DotGrammar();

  @override
  String get separator => '.';

  @override
  String get singleWildcard => '*';

  @override
  String get tailWildcard => '>';

  @override
  void validatePublishToken(String token, {required bool isFirst}) {}

  @override
  void validateSubscriptionToken(String token,
      {required bool isFirst, required bool isLast}) {}
}

class _SlashGrammar extends _DotGrammar {
  const _SlashGrammar();

  @override
  String get separator => '/';
}

class Order {
  Order(this.id);
  final String id;
}

class Invoice {
  Invoice(this.id);
  final String id;
}

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

EventCodec orderCodec() => EventCodec(
      encode: (dto) => (null, _bytes((dto.data as Order).id)),
      decode: (data, address, {arguments}) => EventDTO<Order>.withKey(
        EventKey<Order>(address.value),
        Order(utf8.decode(data)),
      ),
    );

EventCodec orderInvoiceCodec() => EventCodec(
      encode: (dto) {
        final data = dto.data;
        if (data is Order) return (null, _bytes('order:${data.id}'));
        if (data is Invoice) return (null, _bytes('invoice:${data.id}'));
        throw StateError('unexpected payload ${data.runtimeType}');
      },
      decode: (data, address, {arguments}) {
        final text = utf8.decode(data);
        final separator = text.indexOf(':');
        final kind = text.substring(0, separator);
        final id = text.substring(separator + 1);
        if (kind == 'order') {
          return EventDTO<Order>.withKey(
              EventKey<Order>(address.value), Order(id));
        }
        return EventDTO<Invoice>.withKey(
            EventKey<Invoice>(address.value), Invoice(id));
      },
    );

void main() {
  group('EventAddressMapper', () {
    test('maps exact and pattern addresses to wire subjects', () {
      final mapper = EventAddressMapper(grammar: const _DotGrammar());

      expect(
          mapper.toSubject(EventKey<int>('orders.placed')), 'orders.placed');
      expect(
          mapper.toSubject(EventPatternKey<int>('orders.*'),
              subscription: true),
          'orders.*');
      expect(mapper.toAddress('orders.placed'),
          EventAddress('orders.placed'));
      expect(mapper.toPattern('orders.*'), EventPattern('orders.*'));
    });

    test('translates the local separator to the broker separator', () {
      final mapper = EventAddressMapper(grammar: const _SlashGrammar());

      expect(mapper.toSubject(EventKey<int>('orders.placed')), 'orders/placed');
      expect(mapper.toAddress('orders/placed'), EventAddress('orders.placed'));
    });

    test('applies and strips the prefix', () {
      final mapper = EventAddressMapper(
          grammar: const _DotGrammar(), prefix: 'acme');

      expect(mapper.toSubject(EventKey<int>('orders')), 'acme.orders');
      expect(mapper.toAddress('acme.orders'), EventAddress('orders'));
      expect(() => mapper.toAddress('other.orders'),
          throwsA(isA<TransportSubjectException>()));
    });
  });

  group('EventCodecRegistry', () {
    test('exact wins over a pattern and the most specific pattern wins', () {
      final exact = orderCodec();
      final short = orderCodec();
      final long = orderCodec();
      final registry = EventCodecRegistry(
        exact: {EventAddress('orders.placed'): exact},
        patterns: {
          EventPattern('orders.*'): short,
          EventPattern('orders.>') : long,
        },
      );

      expect(registry.resolve(EventAddress('orders.placed')), exact);
      expect(registry.resolve(EventAddress('orders.canceled')), short);
      expect(registry.resolve(EventAddress('orders.a.b')), long);
    });
  });

  group('TransportEventBus.keys', () {
    late FakeTransportConnection connection;
    late TransportEventBus bus;

    setUp(() {
      connection = FakeTransportConnection();
    });

    Future<void> start(EventCodecRegistry codecs) async {
      bus = TransportEventBus.keys(
        connection: connection,
        addresses: EventAddressMapper(grammar: const _DotGrammar()),
        codecs: codecs,
        originId: 'test',
      );
      await bus.waitConnected();
    }

    tearDown(() async {
      await bus.dispose();
    });

    test('fireKey publishes once and delivers locally', () async {
      await start(EventCodecRegistry(
          exact: {EventAddress('orders.placed'): orderCodec()}));
      final key = EventKey<Order>('orders.placed');
      final received = <Order>[];
      final sub = bus.subscribe<Order>(key, onEvent: received.add);

      expect(bus.fire(key, Order('A-1')), isTrue);
      await pumpEventQueue();

      expect(connection.publishes, hasLength(1));
      expect(connection.publishes.single.subject, 'orders.placed');
      expect(utf8.decode(connection.publishes.single.data), 'A-1');
      expect(received.single.id, 'A-1');
      expect(bus.currentData(key)?.id, 'A-1');

      await sub.cancel();
    });

    test('two types on one address publish once per fired key', () async {
      await start(EventCodecRegistry(
          exact: {EventAddress('orders'): orderInvoiceCodec()}));
      final orderKey = EventKey<Order>('orders');
      final invoiceKey = EventKey<Invoice>('orders');
      final orders = <Order>[];
      final invoices = <Invoice>[];
      final orderSub =
          bus.subscribe<Order>(orderKey, onEvent: orders.add);
      final invoiceSub =
          bus.subscribe<Invoice>(invoiceKey, onEvent: invoices.add);

      bus.fire(orderKey, Order('A-1'));
      await pumpEventQueue();
      expect(connection.publishes, hasLength(1));
      expect(orders, hasLength(1));
      expect(invoices, isEmpty);

      bus.fire(invoiceKey, Invoice('I-1'));
      await pumpEventQueue();
      expect(connection.publishes, hasLength(2));
      expect(invoices, hasLength(1));
      expect(orders, hasLength(1));

      await orderSub.cancel();
      await invoiceSub.cancel();
    });

    test('a pattern node receives incoming messages and never publishes',
        () async {
      await start(EventCodecRegistry(patterns: {
        EventPattern('orders.*'): orderCodec(),
      }));
      final received = <Order>[];
      final sub = bus.subscribe<Order>(
          EventPatternKey<Order>('orders.*'),
          onEvent: received.add);

      expect(connection.subscribedSubjects, contains('orders.*'));
      connection.deliver(TransportMessage(
        subject: 'orders.placed',
        data: _bytes('A-1'),
      ));
      await pumpEventQueue();

      expect(received.single.id, 'A-1');
      expect(connection.publishes, isEmpty);

      // A local fire on the concrete key publishes once; the pattern node
      // delivers locally and does not publish again.
      final key = EventKey<Order>('orders.placed');
      final exactSub =
          bus.subscribe<Order>(key, onEvent: (_) {});
      bus.fire(key, Order('A-2'));
      await pumpEventQueue();

      expect(connection.publishes, hasLength(1));
      expect(connection.publishes.single.subject, 'orders.placed');

      await sub.cancel();
      await exactSub.cancel();
    });

    test('requestKey sends a broker request and decodes the response',
        () async {
      await start(EventCodecRegistry(
          exact: {EventAddress('orders'): orderCodec()}));
      final key = EventKey<Order>('orders');

      final future = bus.request(key, Order('A-1'));
      await pumpEventQueue();

      expect(connection.requests, hasLength(1));
      final request = connection.requests.single;
      expect(request.subject, 'orders');
      expect(utf8.decode(request.data), 'A-1');

      connection.deliver(TransportMessage(
        subject: request.replyTo,
        data: _bytes('A-2'),
      ));

      final response = await future;
      expect(response, isA<Order>());
      expect((response as Order).id, 'A-2');
    });

    test('a missing codec leaves the event local', () async {
      await start(EventCodecRegistry());
      final key = EventKey<Order>('orders');
      final received = <Order>[];
      final sub = bus.subscribe<Order>(key, onEvent: received.add);

      expect(bus.fire(key, Order('A-1')), isTrue);
      await pumpEventQueue();

      expect(connection.publishes, isEmpty);
      expect(received, hasLength(1));

      await sub.cancel();
    });
  });
}
