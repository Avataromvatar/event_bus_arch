import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';
import 'package:event_bus_arch_transport/testing.dart';
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

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

class _StrictGrammar extends SubjectGrammar {
  const _StrictGrammar();

  @override
  String get separator => '.';

  @override
  String get singleWildcard => '*';

  @override
  String get tailWildcard => '>';

  @override
  void validatePublishToken(String token, {required bool isFirst}) {
    if (token.isEmpty ||
        token.contains(' ') ||
        token.contains('*') ||
        token.contains('>')) {
      throw TransportSubjectException(
        'invalid publish token "$token"',
        subject: token,
      );
    }
  }

  @override
  void validateSubscriptionToken(String token,
      {required bool isFirst, required bool isLast}) {}
}

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
  group('TransportEventBus: reliability', () {
    late FakeTransportConnection connection;
    late TransportEventBus bus;

    Future<void> start({EventCodecRegistry? codecs}) async {
      bus = TransportEventBus.keys(
        connection: connection,
        addresses: EventAddressMapper(grammar: const _StrictGrammar()),
        codecs: codecs ??
            EventCodecRegistry(exact: {
              EventAddress('orders.placed'): orderCodec(),
            }),
        originId: 'test',
      );
      await bus.waitConnected();
    }

    setUp(() {
      connection = FakeTransportConnection();
    });

    tearDown(() async {
      await bus.dispose();
    });

    test('an offline fire still delivers locally and updates currentData',
        () async {
      await start();
      final received = <Order>[];
      final sub = bus.subscribe(orderKey, onEvent: received.add);

      connection.setStatus(TransportStatus.disconnected);
      expect(
        () => bus.fire(orderKey, Order('A-1')),
        throwsA(isA<TransportServerUnavailableException>()),
      );

      expect(bus.currentData(orderKey)?.id, 'A-1');
      await pumpEventQueue();
      expect(received.single.id, 'A-1');

      await sub.cancel();
    });

    test('a fire-only node is detached after the publish', () async {
      await start();

      expect(bus.fire(orderKey, Order('A-1')), isTrue);
      await pumpEventQueue();

      expect(connection.publishes, hasLength(1));
      expect(connection.subscribedSubjects, isEmpty);
      expect(bus.currentData(orderKey), isNull);
    });

    test(
        'the last listener cancels the broker subscription and a new listen '
        'resubscribes', () async {
      await start();
      final sub = bus.subscribe(orderKey, onEvent: (_) {});
      expect(connection.subscribedSubjects, contains('orders.placed'));

      await sub.cancel();
      await pumpEventQueue();
      expect(connection.subscribedSubjects, isEmpty);

      final received = <Order>[];
      final streamSub = bus.listen(orderKey).listen(received.add);
      expect(connection.subscribedSubjects, contains('orders.placed'));

      connection.deliver(TransportMessage(
        subject: 'orders.placed',
        data: _bytes('B-1'),
      ));
      await pumpEventQueue();
      expect(received.single.id, 'B-1');

      await streamSub.cancel();
      await pumpEventQueue();
      expect(connection.subscribedSubjects, isEmpty);
    });

    test('a successful broker request removes its cancellation listener',
        () async {
      await start();
      final token = CancelToken();

      final pending = bus.request(orderKey, Order('A-1'), cancelToken: token);
      await pumpEventQueue();
      expect(connection.requests, hasLength(1));

      connection.deliver(TransportMessage(
        subject: connection.requests.single.replyTo,
        data: _bytes('B-1'),
      ));
      expect((await pending).id, 'B-1');
      expect(token.listenerCount, 0);
    });

    test('cancelling a broker request fails fast and ignores a late response',
        () async {
      await start();
      final token = CancelToken();

      final pending = bus.request(orderKey, Order('A-1'), cancelToken: token);
      await pumpEventQueue();
      expect(connection.requests, hasLength(1));

      token.cancel();
      await expectLater(pending, throwsA(isA<RequestCanceledException>()));
      expect(token.listenerCount, 0);

      // The broker request itself keeps running until its own timeout; a late
      // response must not complete the cancelled caller.
      connection.deliver(TransportMessage(
        subject: connection.requests.single.replyTo,
        data: _bytes('LATE'),
      ));
      await pumpEventQueue();
    });

    test('an invalid replyTo is reported and not published', () async {
      await start();
      final errors = <EventBusError>[];
      final errorSub = bus.errors.listen(errors.add);
      var handled = false;
      final sub = bus.subscribe(orderKey, handler: (dto, last) async {
        handled = true;
        return Order('reply');
      });

      connection.deliver(TransportMessage(
        subject: 'orders.placed',
        data: _bytes('A-1'),
        replyTo: 'bad subject',
      ));
      await pumpEventQueue();

      expect(handled, isFalse);
      expect(connection.publishes, isEmpty);
      expect(errors.single.error, isA<TransportSubjectException>());

      await errorSub.cancel();
      await sub.cancel();
    });

    test('a valid replyTo receives one response', () async {
      await start();
      final sub = bus.subscribe(orderKey,
          handler: (dto, last) async => Order('reply-${dto.data.id}'));

      connection.deliver(TransportMessage(
        subject: 'orders.placed',
        data: _bytes('A-1'),
        replyTo: 'inbox.ok',
      ));
      await pumpEventQueue();

      expect(connection.publishes, hasLength(1));
      expect(connection.publishes.single.subject, 'inbox.ok');
      expect(utf8.decode(connection.publishes.single.data), 'reply-A-1');

      await sub.cancel();
    });

    test('a local handler of another type does not block the broker', () async {
      await start();
      var localCalls = 0;
      final local = bus.subscribe(invoiceKey, handler: (dto, last) async {
        localCalls++;
        return Invoice('local');
      });

      final pending = bus.request(orderKey, Order('A-1'));
      await pumpEventQueue();
      expect(connection.requests, hasLength(1));

      connection.deliver(TransportMessage(
        subject: connection.requests.single.replyTo,
        data: _bytes('B-1'),
      ));
      expect((await pending).id, 'B-1');
      expect(localCalls, 0);

      await local.cancel();
    });

    test('an incoming request selects the handler of the decoded type',
        () async {
      await start(
          codecs: EventCodecRegistry(exact: {
        EventAddress('orders.placed'): orderInvoiceCodec(),
      }));
      final invoices = bus.subscribe(invoiceKey,
          handler: (dto, last) async => Invoice('invoice-${dto.data.id}'));
      final orders = bus.subscribe(orderKey,
          handler: (dto, last) async => Order(dto.data.id));

      connection.deliver(TransportMessage(
        subject: 'orders.placed',
        data: _bytes('order:A-1'),
        replyTo: 'inbox.ok',
      ));
      await pumpEventQueue();

      final responses = connection.publishes
          .where((publish) => publish.subject == 'inbox.ok')
          .toList();
      expect(responses, hasLength(1));
      expect(utf8.decode(responses.single.data), 'order:A-1');

      await invoices.cancel();
      await orders.cancel();
    });

    test('a local supertype handler wins over the broker', () async {
      await start(codecs: EventCodecRegistry());
      final local = bus.subscribe(domainPattern,
          handler: (dto, last) async => (dto.data as Order).id);

      expect(await bus.request(orderKey, Order('A-1')), 'A-1');
      expect(connection.requests, isEmpty);

      await local.cancel();
    });
  });
}
