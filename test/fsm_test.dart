import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

enum TestState { a, b, c }

class EventA {}

class EventB {}

class TestMachine with FSM<TestState> {
  final List<String> log = [];

  TestMachine(EventBus bus) {
    initFSM(bus, TestState.a);
    addFSMTransition<EventA>(TestState.a, TestState.b,
        handler: (current, last, event, ignored) async {
      log.add('$last->$current');
      return null;
    });
    addFSMTransition<EventB>(TestState.b, TestState.c,
        filter: (current, last, event) => true,
        handler: (current, last, event, ignored) async {
          log.add('$last->$current');
          return null;
        });
  }
}

void main() {
  group('FSM', () {
    test('a transition runs and changes the state', () async {
      final bus = EventBus();
      final machine = TestMachine(bus);

      bus.fire(EventA());
      await pumpEventQueue();

      expect(machine.state, TestState.b);
      expect(machine.lastState, TestState.a);
      expect(machine.log, ['TestState.a->TestState.b']);
      await bus.dispose();
    });

    test('dispose unsubscribes the machine from the bus', () async {
      final bus = EventBus();
      final machine = TestMachine(bus);
      bus.fire(EventA());
      await pumpEventQueue();
      expect(machine.state, TestState.b);

      machine.dispose();
      machine.changeState(TestState.a);
      bus.fire(EventA());
      await pumpEventQueue();

      expect(machine.state, TestState.a);
      expect(machine.log.length, 1);
      await bus.dispose();
    });

    test('a repeated initFSM does not leave a second subscription', () async {
      final bus = EventBus();
      final machine = TestMachine(bus);
      machine.initFSM(bus, TestState.a);

      bus.fire(EventA());
      await pumpEventQueue();

      expect(machine.log.length, 1);
      await bus.dispose();
    });

    test('events during a transition end up in ignoredEvents', () async {
      final bus = EventBus();
      final ignoredCounts = <int>[];
      final machine = TestMachine(bus);
      machine.addFSMTransition<EventB>(TestState.a, TestState.c,
          handler: (current, last, event, ignored) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        ignoredCounts.add(ignored.length);
        return null;
      });
      machine.initFSM(bus, TestState.a);

      machine.changeState(TestState.a);
      bus.fire(EventB());
      await Future<void>.delayed(const Duration(milliseconds: 5));
      bus.fire(EventB());
      bus.fire(EventB());
      // the transition handler waits 30 ms of real time
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(ignoredCounts, [2]);
      expect(machine.state, TestState.c);
      await bus.dispose();
    });
  });
}
