import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_patterns/event_bus_arch_patterns.dart';
import 'package:test/test.dart';
import '../../../test/legacy_compat.dart';

///The names of public parameters are part of the API. This file calls the
///members with named arguments on purpose: renaming one breaks the build here
///instead of surprising a caller later.

enum NameState { a, b }

class NameEvent {}

void main() {
  group('Parameter names: Command and Scope', () {
    test('Command takes key and maxLen, execute takes arguments', () async {
      final bus = EventBus(isModelBus: true);
      final key = EventKey<int>('counter');
      final command = Command<int>(bus, key, maxLen: 3);

      await command.execute(1, arguments: {'a': '1'});

      expect(command.key, key);
      expect(command.queueLength, 1);
      await bus.dispose();
    });

    test(
        'initScope takes a key, initialData, initialDataNeedExecute, maxLenForUndo and onUpdate',
        () async {
      final bus = EventBus(isModelBus: true);
      final scope = Scope<int>();

      await scope.initScope(bus, EventKey<int>('counter'),
          initialData: 7,
          initialDataNeedExecute: false,
          maxLenForUndo: 4,
          onUpdate: (_) {});

      expect(scope.lastData, 7);
      scope.disposeScope();
      await bus.dispose();
    });
  });

  group('Parameter names: FSM', () {
    test('addFSMTransition takes selector, handler and filter', () async {
      final bus = EventBus();
      final machine = _NameMachine(bus);

      // the transition is registered for NameEvent.go: another address is another node
      bus.fireLegacy<NameEvent>(NameEvent(), paths: ['other']);
      await pumpEventQueue();
      expect(machine.state, NameState.a);

      bus.fireLegacy<NameEvent>(NameEvent(), paths: ['go']);
      await pumpEventQueue();

      expect(machine.state, NameState.b);
      await bus.dispose();
    });
  });
}

class _NameMachine with FSM<NameState> {
  _NameMachine(EventBus bus) {
    initFSM(bus, NameState.a, lastState: null);
    addFSMTransition<NameEvent>(NameState.a, NameState.b,
        selector: EventKey<NameEvent>('NameEvent.go'),
        filter: (current, last, event) => true,
        handler: (current, last, event, ignored) async => null);
  }
}
