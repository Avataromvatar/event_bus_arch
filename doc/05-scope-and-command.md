# 05. Scope and Command

[← 04. FSM](04-fsm.md) · [Contents](README.md) · [Next: API reference →](06-api-reference.md)

> `Scope` and `Command` are part of the separate `event_bus_arch_patterns` package. Add it to your
> dependencies and import `package:event_bus_arch_patterns/event_bus_arch_patterns.dart`; the core
> package does not export them.

`Scope<T>` is a value with call history and undo; `Command<T>` is the call log. Both go through the
bus: a call is a `request` when a handler exists, otherwise a `fire` (a model bus stores it).

## Scope

```dart
final scope = Scope<int>();
await scope.initScope(
  bus,
  paths: ['counter'],
  initialData: 0,
  maxLenForUndo: 10,               // history depth; undo needs at least 2 entries
  onUpdate: (value) => print('value: $value'),
);

await scope.call(1);               // goes through the bus
print(scope.lastData);             // 1 — filled by the scope's subscription
await scope.undo();                // sends the PREVIOUS value from the history
scope.disposeScope();
```

API:

```dart
mixin class Scope<T> {
  Future<void> initScope(EventBus bus, {
    T? initialData,
    bool initialDataNeedExecute = true,
    List<String>? paths,
    int maxLenForUndo = 10,
    void Function(T newData)? onUpdate,
  });

  Future<dynamic> call(T newData, {Map<String, String>? arguments});
  Future<dynamic> undo();
  void disposeScope();

  T? lastData;
  EventBus get scopeBus;
  (T?, Map<String, String>?)? get lastCall;
  void Function(T newData)? onUpdate;
}
```

How it works in 4.0:

* `initScope` creates a `Command` (the history) and one `EventSubscription<T>` with
  `bufferCapacity: 1`, `BufferOverflow.latest` — a scope is a latest-value consumer: while the
  callback is busy, the newest value wins and older ones are dropped and counted.
* `initialData` is sent through the bus by default (`initialDataNeedExecute: true`), so handlers and
  other listeners see it. Set it to `false` to seed only `lastData`.
* `call` executes the command: a `request` if the bus has a handler for the topic, else a `fire`
  (the result is `null`).
* `undo()` removes the last entry and re-sends the previous value. It returns `null` when fewer than
  two calls exist.
* `disposeScope()` cancels the scope's own subscription and drops the command. It no longer touches
  any handler registration (the 3.x `removeHandler:` parameter is gone); the node disappears when
  the last subscription is cancelled (unless the bus is a model bus or a transport pins it).
* `scopeBus` and `lastCall` throw `EventBusException` before `initScope`.

## Command

```dart
final command = Command<int>(bus, paths: ['counter'], maxLen: 10);
final result = await command.execute(1);
print(command.queueLength);     // 1
print(command.lastCall?.$1);    // 1
await command.undo();           // re-sends the previous value, or null
```

API:

```dart
abstract class Command<T> {
  Future<dynamic> execute(T data, {Map<String, String>? arguments});
  Future<dynamic> undo();
  EventBus get bindedBus;
  int get queueLength;
  List<String>? get paths;
  (T data, Map<String, String>? arguments)? get lastCall;

  factory Command(EventBus bus, {List<String>? paths, int maxLen = 10});
}
```

`execute` appends the call to a bounded history (`maxLen`, at least 1; the oldest entry is removed)
and then calls the bus. `_call` is a `request` when `haveHandler<T>(paths:)` is true; otherwise it
sends a `fire` and returns `null`. `undo` returns `null` when the history has fewer than two entries.

| Situation | Result |
|---|---|
| A handler exists for the topic | `request`; the handler's value or error is returned |
| No handler, common bus | `fire`; listeners get the value, the result is `null` |
| No handler, model bus | `fire` stores the value and returns `true`; the result is still `null` |
| `undo` with fewer than 2 calls | `null`, nothing is sent |

`Scope` is a convenience around one `Command` plus a latest-value subscription; use `Command`
directly when you only need the history and the bus call.

## Pitfalls

* `maxLenForUndo` must be at least 2 for `undo` to do anything; the default is 10.
* A `request` to a handler can fail with `BusyException`/`NoHandlerException`; `Scope.call` and
  `Command.execute` return that future error to the caller.
* A scope subscription is latest-value: if `onUpdate` is slow, intermediate values are **dropped**
  by design (`BufferOverflow.latest`, capacity 1). Use `sub.dropped` via your own subscription if
  you need every value.
* `disposeScope()` cancels only the scope's subscription; it does not remove the handler of another
  component. In 3.x a `removeHandler: true` flag removed a handler; that parameter no longer exists.

[Next: API reference →](06-api-reference.md)
