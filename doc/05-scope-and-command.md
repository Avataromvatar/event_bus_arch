# 05. Scope and Command

[← 04. FSM](04-fsm.md) · [Contents](README.md) · [Next: API reference →](06-api-reference.md)

Two wrappers over the bus for working with the "current value":

* **`Command<T>`** — publishes a value to the bus and keeps a call history (`maxLen`), supports
  `undo`;
* **`Scope<T>`** — `Command` + a bus subscription: keeps the current value, passes it to
  `onUpdate`, and can remove the handler from the bus when it is done.

## Command

```dart
abstract class Command<T> {
  factory Command(EventBus busBinded, {List<String>? paths, int maxLen = 10});

  Future<dynamic> execute(T data, {Map<String, String>? arguments});
  Future<dynamic> undo();
  EventBus get bindedBus;
  int get queueLength;                            // history depth
  List<String>? get paths;
  (T data, Map<String, String>? arguments)? get lastCall;
}
```

```dart
final bus = EventBus();
bus.handlers.setHandler<int>(paths: ['counter'], handler: (dto, lastData) async {
  return dto.data;                     // the response for request()
});

final command = Command<int>(bus, paths: ['counter'], maxLen: 10);

await command.execute(1);              // published to the bus, history: [1]
await command.execute(2);              // history: [1, 2]
command.queueLength;                   // 2
command.lastCall;                      // (2, null)  → (data, arguments)
await command.undo();                  // see below
```

`execute` decides how to publish:

* when the bus has a handler for the topic, it calls `bus.request` and returns the handler's
  result;
* otherwise it calls `bus.fire` and returns `null` — the value is still delivered to listeners (a
  model bus stores it as `currentData`).

The history stores `(data, arguments)` pairs and `lastCall` returns the newest one in that order.
`maxLen` caps the history depth: on overflow the oldest value is evicted. A value less than one is
clamped to 1, so `maxLen: 0` no longer breaks the very first call.

`paths` is the address of the command: every `execute` publishes to `Topic.create<T>(paths: paths)`,
so a handler registered with the same paths answers it. Without `paths` the command addresses the
type alone.

### What `undo()` does

`undo()` removes the current value from the end of the history and publishes the **previous** one to
the bus:

```dart
final log = <int>[];
// the handler writes dto.data to log
await command.execute(1);   // log: [1]
await command.execute(2);   // log: [1, 2]
await command.execute(3);   // log: [1, 2, 3]
await command.undo();       // log: [1, 2, 3, 2]  ← rollback one step back
await command.undo();       // log: [1, 2, 3, 2, 1]
```

If there is nothing to roll back (fewer than two calls in the history), `undo()` returns `null` and
sends nothing. Note: the rollback depth is limited by `maxLen` — with `maxLen: 2` only one
step back is available.

## Scope

```dart
mixin class Scope<T> {
  T? lastData;
  void Function(T newData)? onUpdate;
  EventBus get scopeBus;
  (T?, Map<String, String>?)? get lastCall;

  Future<void> initScope(EventBus bus, {
    T? initialData,
    bool initialDataNeedExecute = true,
    List<String>? paths,
    int maxLenForUndo = 10,       // history depth; undo needs >= 2
    void Function(T newData)? onUpdate,
  });

  Future<dynamic> call(T newData, {Map<String, String>? arguments});
  Future<dynamic> undo();
  void disposeScope({bool removeHandler = true});
}
```

`Scope` is a mixin class: you can both mix it in (`class Counter with Scope<int>`) and create
it directly (`final scope = Scope<int>()`).

### Usage

```dart
final bus = EventBus(isModelBus: true);
bus.handlers.setHandler<int>(paths: ['counter'], handler: (dto, lastData) async {
  return 'accepted ${dto.data}';
});

final scope = Scope<int>();
await scope.initScope(
  bus,
  paths: ['counter'],
  initialData: 0,         // will be published (initialDataNeedExecute: true by default)
  maxLenForUndo: 10,      // rollback history depth
  onUpdate: (value) => print('current value: $value'),
);

print(await scope.call(1));   // 'accepted 1' — the request result
                              // onUpdate will print 'current value: 1'
print(scope.lastData);        // 1
print(scope.lastCall);        // (1, null) — from the Command queue

scope.disposeScope();         // remove the handler from the bus and unsubscribe
```

### What happens inside

```text
scope.initScope(bus, paths: ['counter'])
   ├─ creates Command<T>(bus, paths: ['counter'], maxLen: maxLenForUndo)
   ├─ subscribes: bus.listen<T>(paths: ['counter']) → lastData = value; onUpdate(value)
   └─ if initialData != null
         └─ initialDataNeedExecute: true  → await Command.execute(initialData)  (goes through the bus)
            initialDataNeedExecute: false → lastData = initialData              (local only)

scope.call(value)   → Command.execute → bus.request if a handler exists,
                                        otherwise bus.fire and null
scope.undo()        → Command.undo    → repeats the previous value (see above)
scope.disposeScope()→ removeHandler from the bus (if removeHandler: true) + cancel the subscription
```

`lastData` and `onUpdate` are filled **from the bus** — with the value after the node has seen
it, not with what you passed to `call`. Delivery has already happened by the time
`await call(...)` returns. If a topic has no node and the bus is common, `fire` still delivers to
the scope's subscription, because `initScope` creates the node itself.

`arguments` passed to `call` travel with the event and are readable in the handler as
`dto.arguments`; they are kept in the command history next to the data, so `undo()` re-sends them
with the previous value.

### Common mistakes

| Mistake | What happens |
|---|---|
| `maxLenForUndo < 2` | `undo()` cannot roll back: there is no previous value in the history |
| Calling `call` before `initScope` | `EventBusException("Scope<int> not initialize")` |
| Accessing `lastCall`/`scopeBus` before `initScope` | the same exception |
| `disposeScope(removeHandler: true)` when the topic has only the scope's subscription | the handler is removed and the node is destroyed; `lastData` is lost |
| `disposeScope(removeHandler: true)` when the topic has foreign listeners | the handler is removed, but the node stays because listeners remain |
| `maxLenForUndo` smaller than the number of steps you undo | the history is capped, so the older values are already evicted |

A repeated `initScope` removes the handler of the previous topic itself (it calls `disposeScope`), so
re-initialization does not leave "dead" handlers behind.

`Scope` assumes it owns the handler of the topic: it is both the subscriber and the handler.
If anyone else uses the topic, call `disposeScope(removeHandler: false)` so you do not remove a
shared handler.

## What's next

* [06-api-reference.md](06-api-reference.md) — the full API reference.
* [07-caveats.md](07-caveats.md) — known defects and workarounds.
