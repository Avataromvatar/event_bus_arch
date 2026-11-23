// ignore_for_file: deprecated_member_use
import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_patterns/event_bus_arch_patterns.dart';
import 'package:test/test.dart';

void main() {
  group('Command', () {
    test('maxLen: 0 does not break the first call', () async {
      final bus = EventBus(isModelBus: true);
      final key = EventKey<int>('counter');
      final command = Command<int>(bus, key, maxLen: 0);

      await command.execute(1);

      expect(command.queueLength, 1);
      expect(command.lastCall?.$1, 1);
      await bus.dispose();
    });

    test('undo sends the previous value and can be repeated', () async {
      final bus = EventBus(isModelBus: true);
      final key = EventKey<int>('counter');
      final log = <int>[];
      bus.subscribe<int>(key, handler: (dto, lastData) async {
        log.add(dto.data);
      });
      final command = Command<int>(bus, key, maxLen: 10);

      await command.execute(1);
      await command.execute(2);
      await command.execute(3);
      await command.undo();
      expect(log, [1, 2, 3, 2]);

      await command.undo();
      expect(log, [1, 2, 3, 2, 1]);

      expect(command.lastCall?.$1, 1);
      await bus.dispose();
    });

    test('undo without history returns null', () async {
      final bus = EventBus(isModelBus: true);
      final command = Command<int>(bus, EventKey<int>('counter'), maxLen: 10);

      expect(await command.undo(), null);

      await command.execute(1);
      expect(await command.undo(),
          null); // nothing to roll back: only one call in history
      await bus.dispose();
    });

    test('history is capped by maxLen', () async {
      final bus = EventBus(isModelBus: true);
      final command = Command<int>(bus, EventKey<int>('counter'), maxLen: 2);

      await command.execute(1);
      await command.execute(2);
      await command.execute(3);

      expect(command.queueLength, 2);
      expect(command.lastCall?.$1, 3);
      await bus.dispose();
    });

    test('the history keeps the arguments of the call', () async {
      final bus = EventBus(isModelBus: true);
      final command = Command<int>(bus, EventKey<int>('counter'), maxLen: 5);

      await command.execute(1, arguments: {'multiplier': '10'});

      expect(command.lastCall?.$1, 1);
      expect(command.lastCall?.$2, {'multiplier': '10'});
      await bus.dispose();
    });

    test('a handler of another type does not take the request path', () async {
      final bus = EventBus(isModelBus: true);
      final key = EventKey<int>('counter');
      final foreign = bus.subscribe(EventKey<String>('counter'),
          handler: (dto, last) async => 'foreign');
      final command = Command<int>(bus, key, maxLen: 5);

      expect(await command.execute(7), isNull);
      expect(bus.currentData(key), 7);

      await foreign.cancel();
      await bus.dispose();
    });

    test('execute sends to the command key', () async {
      final bus = EventBus(isModelBus: true);
      final key = EventKey<int>('counter');
      final seen = <int>[];
      bus.subscribe<int>(key, handler: (dto, lastData) async {
        seen.add(dto.data);
      });
      final command = Command<int>(bus, key, maxLen: 5);

      await command.execute(7);

      expect(seen, [7]);
      // a command with another key addresses another node
      final other = Command<int>(bus, EventKey<int>('other'), maxLen: 5);
      await other.execute(8);
      expect(seen, [7]);
      await bus.dispose();
    });
  });

  group('Scope', () {
    test('default values do not break initScope and call', () async {
      final bus = EventBus(isModelBus: true);
      final scope = Scope<int>();

      await scope.initScope(bus, EventKey<int>('int'), initialData: 0);
      await scope.call(1);
      await Future<void>.delayed(Duration.zero);

      expect(scope.lastData, 1);
      expect(scope.lastCall?.$1, 1);
      scope.disposeScope();
      await bus.dispose();
    });

    test('onUpdate is called when a value appears', () async {
      final bus = EventBus(isModelBus: true);
      final scope = Scope<int>();
      final updates = <int>[];

      await scope.initScope(bus, EventKey<int>('int'),
          maxLenForUndo: 10, onUpdate: updates.add);
      await scope.call(5);
      await Future<void>.delayed(Duration.zero);

      expect(updates, [5]);
      scope.disposeScope();
      await bus.dispose();
    });

    test('undo restores the previous value', () async {
      final bus = EventBus(isModelBus: true);
      final scope = Scope<int>();
      await scope.initScope(bus, EventKey<int>('int'),
          initialData: 0, initialDataNeedExecute: false, maxLenForUndo: 10);

      await scope.call(1);
      await scope.call(2);
      await scope.undo();
      await Future<void>.delayed(Duration.zero);

      expect(scope.lastData, 1);
      scope.disposeScope();
      await bus.dispose();
    });

    test('accessing before initScope throws EventBusException', () {
      final scope = Scope<int>();

      expect(() => scope.call(1), throwsA(isA<EventBusException>()));
      expect(() => scope.lastCall, throwsA(isA<EventBusException>()));
      expect(() => scope.scopeBus, throwsA(isA<EventBusException>()));
    });

    test('a repeated initScope replaces its listener and keeps handlers',
        () async {
      final bus = EventBus(isModelBus: true);
      final scope = Scope<int>();
      final keyA = EventKey<int>('a');
      final keyB = EventKey<int>('b');
      final handler =
          bus.subscribe<int>(keyA, handler: (dto, lastData) async {});
      await scope.initScope(bus, keyA, maxLenForUndo: 10);

      await scope.initScope(bus, keyB, maxLenForUndo: 10);

      // The handler is not owned by Scope and stays; the old listener is gone.
      expect(bus.haveHandler(keyA), true);
      expect(bus.haveListener(keyA), false);
      expect(bus.haveListener(keyB), true);

      scope.disposeScope();
      await handler.cancel();
      await bus.dispose();
    });

    test('disposeScope does not touch a handler it does not own', () async {
      final bus = EventBus(isModelBus: true);
      final scope = Scope<int>();
      final key = EventKey<int>('a');
      final handler =
          bus.subscribe<int>(key, handler: (dto, lastData) async {});
      await scope.initScope(bus, key, maxLenForUndo: 10);

      scope.disposeScope();

      expect(bus.haveHandler(key), true);
      await handler.cancel();
      await bus.dispose();
    });
  });
}
