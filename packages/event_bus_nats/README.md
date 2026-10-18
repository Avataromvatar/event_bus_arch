# event_bus_nats

NATS transport for [`event_bus_arch`](https://pub.dev/packages/event_bus_arch).

`EventBusNats` is an `EventBus` whose nodes publish to and subscribe from a
NATS server. Application code keeps using `fire`, `request`, `listen`, `subscribe` and
`setHandler`; the transport is configured with serializers and deserializers.

## Requirements

- Dart SDK 3.12 or newer.
- A NATS server. Headers (`arguments` and self-echo filtering) need NATS 2.2+.
  With an older server set `NatsConnectionOptions(useHeaders: false)`, but then
  `arguments` are not transmitted and the bus does not filter its own echo.

## Quick start

Two buses in one process: one publishes to the server, the other receives from
it. In a real application they would usually run in different processes.

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_nats/event_bus_nats.dart';

Future<void> main() async {
  final publisher = EventBusNats(
    Uri.parse('nats://localhost:4222'),
    serializers: {
      'int.sensor.temp': (dto) =>
          (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
    },
  );

  final subscriber = EventBusNats(
    Uri.parse('nats://localhost:4222'),
    deserializers: {
      'int.sensor.*': (data, topic, {arguments}) => EventDTO<int>(
        int.parse(utf8.decode(data)),
        topic: Topic.parse(topic),
      ),
    },
  );

  await Future.wait([
    publisher.waitConnected(timeout: const Duration(seconds: 5)),
    subscriber.waitConnected(timeout: const Duration(seconds: 5)),
  ]);

  final received = Completer<int>();
  final subscription = subscriber.subscribe<int>(
    paths: ['sensor', '*'],
    onData: (value) {
      print('received: $value');
      received.complete(value);
    },
  );

  publisher.fire<int>(21, paths: ['sensor', 'temp']);

  await received.future.timeout(const Duration(seconds: 5));

  await subscription.cancel();
  await publisher.dispose();
  await subscriber.dispose();
}
```

The runnable version is in `example/event_bus_nats_example.dart`.

## Topics and subjects

A local topic is `<type>.<path...>`, for example `int.sensor.temp`. By default
it is also the wire subject. The type token comes from the static type `T` of
the call and is normalised by the core to a broker-safe token: `List<int>`
becomes `List(int)`.

`subjectPrefix` namespaces every subject:

```dart
EventBusNats(..., subjectPrefix: 'acme.shop');
// int.sensor.temp -> acme.shop.int.sensor.temp
```

The prefix is stripped before the deserializer is called, so the deserializer
always receives a local topic.

`typeTags` replaces the type token with a stable wire name. This is the escape
hatch for `runtimeType` names that are minified on the web or obfuscated in an
AOT build:

```dart
EventBusNats(..., typeTags: {'int': 'number'});
// int.sensor.temp -> number.sensor.temp
```

Keys are the local type tokens as they appear in `Topic.type`; values must be
unique single tokens without `.`, `*`, `>` or whitespace.

## Serializers and deserializers

Registry keys are local topics. Resolution order:

| Direction | Order |
|---|---|
| Publish (`serializers`) | exact topic → type token |
| Subscribe (`deserializers`) | exact topic → type token → most specific wildcard pattern |

- A topic is published to the server only when a serializer resolves for it.
- A node subscribes only when a deserializer resolves for it.
- The most specific pattern is the one with the most literal tokens; ties keep
  the insertion order of the registry.
- A topic that itself contains wildcards is resolved by exact/type only:
  matching a pattern against a pattern is ambiguous.

A node is created lazily by `listen<T>`, `setHandler<T>` or `fire<T>`/`request<T>`. `fire`
creates a node only for a topic present in one of the registries; for any other
topic it keeps local bus semantics and returns `null` when no node exists.

### Wildcards

Subscriptions and deserializer keys may use NATS wildcards:

- `*` matches exactly one token: `int.sensor.*.value`;
- `>` matches one or more trailing tokens and must be the last token:
  `int.sensor.>`.

Wildcards are rejected in publish subjects and serializer keys. The server
delivers a concrete subject (`int.sensor.humidity`), and the node passes that
concrete local topic to the deserializer.

### Serializer subject override

The serializer may return a subject as the first element of its record. A
non-null subject is used as is: it is a full wire subject, including the prefix
if one is configured. It must be a concrete publish subject.

## Arguments

`fire(arguments: {...})` puts the map into the `X-EventBus-Arguments` header as
JSON. The deserializer receives it as the named `arguments` parameter and
decides whether to put it into the `EventDTO`. This requires NATS headers.

## Connection lifecycle

```dart
bus.isConnected;          // true while the client is fully connected
bus.status;               // connecting / connected / reconnecting / ...
bus.connectionStatus;     // stream of status changes
await bus.waitConnected(timeout: Duration(seconds: 5));
bus.errors;               // stream of asynchronous transport/node errors
```

- The constructor starts connecting in the background. `fire` on a transport
  topic while the connection is down throws
  `NatsServerUnavailableException` before local delivery; the event is not
  silently buffered.
- Reconnection is owned by the transport: a new `dart_nats` client is created
  per attempt, with exponential backoff (`NatsReconnectPolicy`, default 1s →
  30s, unlimited attempts). Subscriptions are restored from a local registry,
  exactly once.
- The bus writes `X-EventBus-Origin` on every publish and drops messages with
  its own origin, so a node that both publishes and subscribes does not receive
  its own event twice. Local listeners still receive it from the local fire.
- A node is pinned in the bus map by an internal handler: cancelling the last
  local listener does not unsubscribe while the bus is alive. `dispose` of the
  bus cancels every subscription. Because of the internal handler,
  `haveHandler` returns true for every NATS node.

## Errors

- `NatsServerUnavailableException` — `fire` while disconnected.
- `NatsSerializationException` — the serializer threw; the caller receives it.
- `NatsDeserializationException` — an incoming payload could not be decoded or
  its data type does not match `T`; it is reported on `bus.errors` and the node
  keeps running.
- Transport failures that happen after `fire` returned (a race on the socket)
  are reported on `bus.errors`.

## Guarantees and limitations

- Core NATS is **at-most-once**: no persistence, no acknowledgement of a
  publish. JetStream is not used.
- Ordering across publishers is not guaranteed. Per-publisher order is what
  the server provides; do not rely on the local bus's strict per-node order.
- The local-only members keep their local meaning: `haveListener` and
  `haveHandler` only see this process, and `allEventStream` sees outgoing
  events, not incoming ones.
- `EventDTO.completer` is local. Remote request/reply is not implemented yet;
  `msg.replyTo` is carried by the connection for a future API.
- `EventNodeNatsImpl.copy()` throws: a node cannot be rebound to another bus.
- `runtimeType` as a wire address is not stable under web minification or AOT
  obfuscation. Use `typeTags` (or a type whose name is stable) before deploying.
- The server's `maxPayload` is checked before publishing; a larger event throws
  `NatsPublishException`.

## Tests

```powershell
# unit tests, fake connection, no server
dart test

# with a live server, including integration tests
$env:NATS_URL = "nats://127.0.0.1:4222"
dart test
```

The integration files skip themselves when `NATS_URL` is not set.
