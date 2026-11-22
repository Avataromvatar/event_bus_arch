import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

class Order {}

class SpecialOrder extends Order {}

class Invoice {}

void main() {
  group('EventAddress', () {
    test('keeps the value and derives tokens', () {
      final address = EventAddress('orders.placed');

      expect(address.value, 'orders.placed');
      expect(address.tokens, ['orders', 'placed']);
      expect(address.toString(), 'orders.placed');
    });

    test('equality and hashCode are by value', () {
      final a = EventAddress('orders.placed');
      final b = EventAddress.parse('orders.placed');
      final c = EventAddress('orders.canceled');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('rejects empty addresses and empty tokens', () {
      expect(() => EventAddress(''), throwsA(isA<EventBusException>()));
      expect(() => EventAddress('.orders'), throwsA(isA<EventBusException>()));
      expect(() => EventAddress('orders.'), throwsA(isA<EventBusException>()));
      expect(() => EventAddress('orders..placed'),
          throwsA(isA<EventBusException>()));
    });

    test('rejects wildcards in an exact address', () {
      expect(() => EventAddress('orders.*'), throwsA(isA<EventBusException>()));
      expect(() => EventAddress('orders.>'), throwsA(isA<EventBusException>()));
      expect(() => EventAddress('orders.a*'), throwsA(isA<EventBusException>()));
    });

    test('allows a non-broker character in a token', () {
      // Local addresses are broker-neutral; the transport validates its grammar.
      expect(EventAddress('orders/v2').tokens, ['orders/v2']);
    });
  });

  group('EventPattern', () {
    test('accepts exact and wildcard patterns', () {
      expect(EventPattern('orders.placed').value, 'orders.placed');
      expect(EventPattern('orders.*').tokens, ['orders', '*']);
      expect(EventPattern('orders.>').tokens, ['orders', '>']);
      expect(EventPattern('orders.*').hasWildcard, isTrue);
      expect(EventPattern('orders.placed').hasWildcard, isFalse);
    });

    test('rejects malformed patterns', () {
      expect(() => EventPattern(''), throwsA(isA<EventBusException>()));
      expect(() => EventPattern('>.orders'), throwsA(isA<EventBusException>()));
      expect(() => EventPattern('orders.>.x'),
          throwsA(isA<EventBusException>()));
      expect(() => EventPattern('orders.a*'),
          throwsA(isA<EventBusException>()));
      expect(() => EventPattern('orders..x'),
          throwsA(isA<EventBusException>()));
    });

    test('* matches exactly one token', () {
      final pattern = EventPattern('orders.*');

      expect(pattern.matches(EventAddress('orders.placed')), isTrue);
      expect(pattern.matches(EventAddress('orders.canceled')), isTrue);
      expect(pattern.matches(EventAddress('orders')), isFalse);
      expect(pattern.matches(EventAddress('orders.placed.v2')), isFalse);
      expect(pattern.matches(EventAddress('invoices.placed')), isFalse);
    });

    test('> matches one or more trailing tokens', () {
      final pattern = EventPattern('orders.>');

      expect(pattern.matches(EventAddress('orders.placed')), isTrue);
      expect(pattern.matches(EventAddress('orders.placed.v2')), isTrue);
      expect(pattern.matches(EventAddress('orders')), isFalse);
      expect(pattern.matches(EventAddress('invoices.placed')), isFalse);
    });

    test('a pattern without wildcards matches only that address', () {
      final pattern = EventPattern('orders.placed');

      expect(pattern.matches(EventAddress('orders.placed')), isTrue);
      expect(pattern.matches(EventAddress('orders.canceled')), isFalse);
    });

    test('a root > matches any non-empty address', () {
      final pattern = EventPattern('>');

      expect(pattern.matches(EventAddress('orders')), isTrue);
      expect(pattern.matches(EventAddress('orders.placed')), isTrue);
    });

    test('equality and hashCode are by pattern string', () {
      final a = EventPattern('orders.*');
      final b = EventPattern.parse('orders.*');
      final c = EventPattern('orders.>');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('EventKey', () {
    test('captures the exact address and the local type', () {
      final key = EventKey<Order>('orders.placed');

      expect(key.address.value, 'orders.placed');
      expect(key.type, EventKey<Order>('other').type);
      expect(key.toString(), 'orders.placed');
    });

    test('equality is by address and type', () {
      final a = EventKey<Order>('orders.placed');
      final b = EventKey<Order>('orders.placed');
      final otherAddress = EventKey<Order>('orders.canceled');
      final otherType = EventKey<SpecialOrder>('orders.placed');
      final widerType = EventKey<Object>('orders.placed');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(otherAddress));
      expect(a, isNot(otherType));
      expect(a, isNot(widerType));
    });

    test('accepts the type and its subtypes, rejects others', () {
      final key = EventKey<Order>('orders.placed');

      expect(key.accepts(Order()), isTrue);
      expect(key.accepts(SpecialOrder()), isTrue);
      expect(key.accepts(Invoice()), isFalse);
      expect(key.accepts(null), isFalse);
      expect(EventKey<Object>('x').accepts('anything'), isTrue);
      expect(EventKey<num>('x').accepts(1), isTrue);
      expect(EventKey<int>('x').accepts(1.5), isFalse);
    });

    test('an exact key rejects wildcard addresses', () {
      expect(() => EventKey<Order>('orders.*'),
          throwsA(isA<EventBusException>()));
    });

    test('a pattern key is not equal to an exact key with the same string', () {
      final exact = EventKey<Order>('orders.placed');
      final pattern = EventPatternKey<Order>('orders.placed');

      expect(exact == pattern, isFalse);
      expect(pattern == exact, isFalse);
    });
  });

  group('EventPatternKey', () {
    test('captures the pattern and the local type', () {
      final key = EventPatternKey<Order>('orders.*');

      expect(key.pattern.value, 'orders.*');
      expect(key.type, EventPatternKey<Order>('orders.>').type);
      expect(key.toString(), 'orders.*');
    });

    test('matches addresses by pattern', () {
      final key = EventPatternKey<Order>('orders.*');

      expect(key.matches(EventAddress('orders.placed')), isTrue);
      expect(key.matches(EventAddress('orders')), isFalse);
    });

    test('equality is by pattern and type', () {
      final a = EventPatternKey<Order>('orders.*');
      final b = EventPatternKey<Order>('orders.*');
      final otherPattern = EventPatternKey<Order>('orders.>');
      final otherType = EventPatternKey<SpecialOrder>('orders.*');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(otherPattern));
      expect(a, isNot(otherType));
    });

    test('accepts the type and its subtypes, rejects others', () {
      final key = EventPatternKey<Order>('orders.*');

      expect(key.accepts(SpecialOrder()), isTrue);
      expect(key.accepts(Invoice()), isFalse);
    });
  });

  group('EventSelector', () {
    test('an exact and a pattern key are both selectors', () {
      final EventSelector<Order> exact = EventKey<Order>('orders.placed');
      final EventSelector<Order> pattern = EventPatternKey<Order>('orders.*');

      expect(exact.accepts(SpecialOrder()), isTrue);
      expect(pattern.accepts(SpecialOrder()), isTrue);
      expect(exact.type, pattern.type);
    });
  });
}
