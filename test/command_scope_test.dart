import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() {
  group('Command', () {
    test('maxLen: 0 does not break the first call', () async {
      final bus = EventBus(isModelBus: true);
      final command = Command<int>(bus, maxLen: 0);

      await command.execute(1);

      expect(command.queueLength, 1);
      expect(command.lastCall?.$1, 1);
      await bus.dispose();
    });

    test('undo sends the previous value and can be repeated', () async {
      final bus = EventBus(isModelBus: true);
      final log = <int>[];
      bus.handlers.setHandler<int>(handler: (dto, lastData) async {
        log.add(dto.data);
      });
      final command = Command<int>(bus, maxLen: 10);

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
      final command = Command<int>(bus, maxLen: 10);

      expect(await command.undo(), null);

      await command.execute(1);
      expect(await command.undo(), null); // nothing to roll back: only one call in history
      await bus.dispose();
    });

    test('history is capped by maxLen', () async {
      final bus = EventBus(isModelBus: true);
      final command = Command<int>(bus, maxLen: 2);

      await command.execute(1);
      await command.execute(2);
      await command.execute(3);

      expect(command.queueLength, 2);
      expect(command.lastCall?.$1, 3);
      await bus.dispose();
    });

    test('queueLenght is kept as a deprecated alias', () async {
      final bus = EventBus(isModelBus: true);
      final command = Command<int>(bus, maxLen: 5);
      await command.execute(1);

      // ignore: deprecated_member_use_from_same_package
      expect(command.queueLenght, command.queueLength);
      await bus.dispose();
    });
  });

  group('Scope', () {
    test('default values do not break initScope and call', () async {
      final bus = EventBus(isModelBus: true);
      final scope = Scope<int>();

      await scope.initScope(bus, initialData: 0);
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

      await scope.initScope(bus, maxLenForUndo: 10, onUpdate: updates.add);
      await scope.call(5);
      await Future<void>.delayed(Duration.zero);

      expect(updates, [5]);
      scope.disposeScope();
      await bus.dispose();
    });

    test('undo restores the previous value', () async {
      final bus = EventBus(isModelBus: true);
      final scope = Scope<int>();
      await scope.initScope(bus,
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

    test('a repeated initScope removes the handler of the previous topic', () async {
      final bus = EventBus(isModelBus: true);
      final scope = Scope<int>();
      await scope.initScope(bus, path: '/a', maxLenForUndo: 10);
      bus.handlers.setHandler<int>(path: '/a', handler: (dto, lastData) async {});

      await scope.initScope(bus, path: '/b', maxLenForUndo: 10);

      expect(bus.haveHandler<int>(path: '/a'), false);
      expect(bus.haveListener<int>(path: '/b'), true);
      scope.disposeScope();
      await bus.dispose();
    });

    test('disposeScope(removeHandler: false) does not touch a handler it does not own',
        () async {
      final bus = EventBus(isModelBus: true);
      final scope = Scope<int>();
      await scope.initScope(bus, path: '/a', maxLenForUndo: 10);
      bus.handlers.setHandler<int>(path: '/a', handler: (dto, lastData) async {});

      scope.disposeScope(removeHandler: false);

      expect(bus.haveHandler<int>(path: '/a'), true);
      await bus.dispose();
    });
  });
}
