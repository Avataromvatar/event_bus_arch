# event_bus_arch_patterns

Higher-level patterns on top of
[`event_bus_arch`](https://pub.dev/packages/event_bus_arch): a finite state machine, a
latest-value scope with call history, and the command abstraction used by the scope.

The core package stays a routing library; it does not export these types.

## What is here

| Type | Responsibility |
|---|---|
| `FSM<T>` | A state machine driven by `allEventStream`: transitions have a filter, a handler and an `ignoredEvents` list |
| `Scope<T>` | A value with `lastData`, `initScope`, `onUpdate`, `undo` and a latest-value subscription |
| `Command<T>` | The call history behind a scope: `execute`, `undo`, `lastCall`, `maxLen` |

## Install

```yaml
dependencies:
  event_bus_arch: ^4.0.0
  event_bus_arch_patterns: ^0.1.0
```

```dart
import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_patterns/event_bus_arch_patterns.dart';
```

## FSM

```dart
enum State { idle, loading, ready }

class Loader with FSM<State> {
  Loader(EventBus bus) {
    initFSM(bus, State.idle);
    addFSMTransition<Start>(State.idle, State.loading,
      selector: EventKey<Start>('start'),
      handler: (current, last, event, ignored) async {
        await load(event.url);
        return null;
      });
    addFSMTransition<Done>(State.loading, State.ready,
      selector: EventKey<Done>('done'));
  }
}
```

A handler that throws does not stop the machine: the transition is committed, the
events collected during it are cleared, and the next event can drive the next transition.

## Scope and Command

```dart
final scope = Scope<int>();
await scope.initScope(bus, EventKey<int>('counter'), initialData: 0);
await scope.call(1);
await scope.undo();          // re-sends the previous value
scope.disposeScope();
```

`Scope` subscribes with `bufferCapacity: 1` and `BufferOverflow.latest`; `Command` keeps the
call history and turns a call into `request` when a handler exists, otherwise into `fire`.

## Documentation

- [FSM guide](https://github.com/Avataromvatar/dart_event_bus/blob/master/doc/04-fsm.md)
- [Scope and Command guide](https://github.com/Avataromvatar/dart_event_bus/blob/master/doc/05-scope-and-command.md)

## Examples

- [`example/fsm_example.dart`](example/fsm_example.dart)
- [`example/migration_target_example.dart`](example/migration_target_example.dart)

## Tests

```bash
dart test
```
