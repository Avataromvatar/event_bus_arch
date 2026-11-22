# event_bus_arch_nats

NATS transport for [`event_bus_arch`](https://pub.dev/packages/event_bus_arch).

`EventBusNats.keys` is an `EventBus` whose nodes publish to and subscribe from a NATS server.
Application code keeps using `fire`, `request`, `listen`, `subscribe` and `subscribeEvents`; the
transport is configured with an `EventCodecRegistry` keyed by event address.

The package is a thin NATS adapter over
[`event_bus_arch_transport`](../event_bus_arch_transport): the connection lifecycle, subscription
registry, address ↔ subject mapping, node and bus are shared with other transports. This package
supplies the `dart_nats` client adapter, the NATS grammar and the public `Nats*` names.

## Requirements

- Dart SDK 3.12 or newer.
- A NATS server. Headers (`arguments` and self-echo filtering) need NATS 2.2+. With an older server
  set `NatsConnectionOptions(useHeaders: false)`, but then `arguments` are not transmitted and the
  bus does not filter its own echo.

## Quick start

Two buses in one process: one publishes to the server, the other receives from it. In a real
application they would usually run in different processes.

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_nats/event_bus_arch_nats.dart';

EventCodec intCodec() => EventCodec(
      encode: (dto) =>
          (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
      decode: (data, address, {arguments}) => EventDTO.withKey(
        EventKey<int>(address.value),
        int.parse(utf8.decode(data)),
        arguments: arguments,
      ),
    );

Future<void> main() async {
  final sensorTemp = EventAddress('sensor.temp');
  final sensorAny = EventPattern('sensor.*');

  final publisher = EventBusNats.keys(
    Uri.parse('nats://localhost:4222'),
    codecs: EventCodecRegistry(exact: {sensorTemp: intCodec()}),
  );

  final subscriber = EventBusNats.keys(
    Uri.parse('nats://localhost:4222'),
    codecs: EventCodecRegistry(patterns: {sensorAny: intCodec()}),
  );

  await Future.wait([
    publisher.waitConnected(timeout: const Duration(seconds: 5)),
    subscriber.waitConnected(timeout: const Duration(seconds: 5)),
  ]);

  final received = Completer<int>();
  final subscription = subscriber.subscribe(
    EventPatternKey<int>('sensor.*'),
    onData: (value) {
      print('received: $value');
      received.complete(value);
    },
  );

  publisher.fire(EventKey<int>('sensor.temp'), 21);

  await received.future.timeout(const Duration(seconds: 5));

  await subscription.cancel();
  await publisher.dispose();
  await subscriber.dispose();
}
```

A runnable keyed version is in `example/event_bus_arch_nats_example.dart`.

## Addresses and subjects

The event address is the wire subject: `orders.placed.v1` is published to
`orders.placed.v1`. The address is user-supplied; no Dart type name and no `typeTags` are involved.

`subjectPrefix` namespaces every subject:

```dart
EventBusNats.keys(..., subjectPrefix: 'acme.shop');
// orders.placed.v1 -> acme.shop.orders.placed.v1
```

The prefix is stripped before the codec is called, so the codec always receives the local address.

## Codecs

`EventCodecRegistry` keys are addresses or address patterns. Resolution order:

| Direction | Order |
|---|---|
| Publish (`encode`) | exact address → most specific matching pattern |
| Subscribe (`decode`) | exact address → most specific matching pattern |

- An address is published to the server only when an encoder resolves for it.
- A node subscribes only when a decoder resolves for it.
- The most specific pattern is the one with the most literal tokens; ties keep the insertion order
  of the registry.
- A codec may implement only one direction: a publisher needs `encode`, a subscriber needs `decode`.

A node is created lazily by `listen`, `subscribeEvents` or `fire`/`request`. `fire` creates a node
only for an address present in the codec registry; for any other address it keeps local bus
semantics and returns `false` when no node exists.

### Wildcards

Wildcard semantics are defined by the core `EventPattern`: `*` matches exactly one token, `>`
matches one or more trailing tokens and must be last. NATS uses the same symbols. `fire` and
`request` calls themselves must carry an `EventKey`; a request may be answered by a handler
registered on an `EventPatternKey`.

### Encoder subject override

An encoder may return a non-null first element to publish to a full wire subject instead of the
mapped address. The override is validated as a NATS publish subject; the node still delivers the
event locally and the incoming subscription still uses the mapped address/pattern. Responses to
requests always go to the inbox, so the override does not apply to them.

## Requests

A request keeps local semantics when a local handler exists. Otherwise it is published to the
mapped subject with a NATS inbox (`_INBOX.…`) as the reply subject, and the first response is
decoded with the codec registered for the request address. `timeout` is supported; broker-side
cancellation is not part of the 4.0 contract.

## Errors

| Error | Where |
|---|---|
| `NatsServerUnavailableException` | `publish` while the connection is down |
| `NatsSerializationException` | encoder threw; reaches the sender |
| `NatsDeserializationException` | broken or mismatched payload; `bus.errors` |
| `NatsPublishException` | payload too large, or a publish that failed after the check |
| `NatsSubjectException` | invalid address, subject or codec key |
| `NatsConnectionException` | connection use after close, exhausted retries |

## Tests

```text
dart test
NATS_URL=nats://127.0.0.1:4222 dart test   # broker-backed tests
```
