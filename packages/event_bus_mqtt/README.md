# event_bus_mqtt

MQTT 5 transport for [`event_bus_arch`](https://pub.dev/packages/event_bus_arch).

`EventBusMqtt` is an `EventBus` whose nodes publish to and subscribe from an
MQTT 5 broker. Application code keeps using `fire`, `request`, `listen`,
`subscribe` and `setHandler`; the transport is configured with serializers and
deserializers.

The package is a thin MQTT adapter over
[`event_bus_transport`](../event_bus_transport): the connection lifecycle,
subscription registry, topic ↔ subject mapping, node and bus are shared with
the NATS transport. This package supplies the `mqtt5_client` adapter, the MQTT
grammar and the public `Mqtt*` names.

## Requirements

- Dart SDK 3.12 or newer (VM; `dart:io` sockets and WebSockets).
- An MQTT **5** broker. MQTT 3.1.1 is not supported: the transport uses user
  properties, response topics and `noLocal`, which only exist in MQTT 5.
- The broker address may be `mqtt://host`, `mqtts://host`, `ws://host` or
  `wss://host`. Default ports are 1883, 8883, 80 and 443.

## Quick start

Two buses in one process: one publishes to the broker, the other receives from
it. In a real application they would usually run in different processes.

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_mqtt/event_bus_mqtt.dart';

Future<void> main() async {
  final publisher = EventBusMqtt(
    Uri.parse('mqtt://localhost:1883'),
    serializers: {
      'int.sensor.temp': (dto) =>
          (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
    },
  );

  final subscriber = EventBusMqtt(
    Uri.parse('mqtt://localhost:1883'),
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

The runnable version is in `example/event_bus_mqtt_example.dart`.

## Topics and subjects

A local topic is `<type>.<path...>`, for example `int.sensor.temp`. On the wire
it becomes `int/sensor/temp`. The type token is normalised by the core to a
broker-safe token: `List<int>` becomes `List(int)`.

`subjectPrefix` namespaces every topic:

```dart
EventBusMqtt(..., subjectPrefix: 'acme/shop');
// int.sensor.temp -> acme/shop/int/sensor/temp
```

The prefix is stripped before the deserializer runs. `typeTags` replaces the
type token with a stable wire name:

```dart
EventBusMqtt(..., typeTags: {'int': 'number'});
// int.sensor.temp -> number/sensor/temp
```

Keys are local type tokens as they appear in `Topic.type`; values must be
unique single levels without `/`, `+`, `#` or a null character.

## Serializers and deserializers

Registry keys are local topics. Resolution order:

| Direction | Order |
|---|---|
| Publish (`serializers`) | exact topic → type token |
| Subscribe (`deserializers`) | exact topic → type token → most specific wildcard pattern |

- A topic is published to the broker only when a serializer resolves for it.
- A node subscribes only when a deserializer resolves for it.
- A node is created lazily by `listen<T>`, `setHandler<T>` or
  `fire<T>`/`request<T>`. `fire` creates a node only for a topic present in one
  of the registries; otherwise it keeps local bus semantics and returns false.

### Wildcards

Core wildcard semantics are defined by `TopicPattern`: `*` matches exactly one
path token, `>` matches one or more trailing tokens. The MQTT grammar translates
them to `+` and `#`:

```text
int.sensor.*  ->  int/sensor/+
int.>         ->  int/#
```

MQTT `#` also matches the parent level (`int/#` receives `int`), while the core
`>` requires at least one trailing token. The node drops those extra messages,
so the bus keeps the core semantics.

Wildcards are rejected in publish subjects and serializer keys. The broker
delivers a concrete topic (`int/sensor/humidity`), and the node passes the
concrete local topic to the deserializer.

### Serializer subject override

The serializer may return a topic as the first element of its record. A
non-null topic is used as is: it is a full wire topic, including the prefix if
one is configured. It must be a concrete publish topic.

## Arguments and echo suppression

`fire(arguments: {...})` puts the map into the `X-EventBus-Arguments` **user
property** as JSON. The deserializer receives it as the named `arguments`
parameter. `X-EventBus-Origin` identifies the bus.

Subscriptions set MQTT 5 `noLocal`, so the broker does not send a client its own
publications. The origin property is checked as well. With
`MqttConnectionOptions(noLocal: false, useUserProperties: false)` both
mechanisms are disabled and a node that publishes and subscribes to the same
topic receives its own event twice.

## Requests

`request` uses a local handler when one is registered. Otherwise the request
goes over MQTT and the first response is returned:

```dart
final doubled = await requester.request<int>(
  21,
  paths: ['sensor', 'double'],
  timeout: const Duration(seconds: 2),
);
```

The request is published with a unique `_INBOX/...` topic in the MQTT 5
**response topic** property. The responder's node invokes its local handler
through the core and publishes the encoded result back to that response topic.
The requester decodes it with the deserializer registered for the request topic.

The responder needs a handler plus a serializer and a deserializer: the
deserializer decodes the request, the serializer encodes the handler's result
under the request topic. A request with neither a local handler nor a transport
route throws `NoHandlerException`. A responder without a handler reports
`NoHandlerException` on `bus.errors`; the requester sees `TimeoutException`.

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
  `MqttServerUnavailableException` before local delivery; the event is not
  silently buffered.
- Reconnection is owned by the shared `ReconnectingTransportConnection`: a new
  `mqtt5_client` client is created per attempt, with exponential backoff
  (`MqttReconnectPolicy`, default 1s → 30s, unlimited attempts). Subscriptions
  are restored from a local registry, exactly once.
- The default client id is derived from the bus's origin id. When several buses
  share a broker they use distinct ids; a fixed `clientId` must be unique per
  live connection.
- `cleanStart` is true by default. A persistent session can be requested with
  `MqttConnectionOptions(cleanStart: false, sessionExpiryInterval: ...)`, but
  the bus still resubscribes from its own registry after a reconnect.
- A node is a `KeepAliveNode`: cancelling the last local listener does not
  unsubscribe while the bus is alive. `dispose` of the bus cancels every
  subscription.

## Errors

- `MqttServerUnavailableException` — `fire` while disconnected.
- `MqttSerializationException` — the serializer threw; the caller receives it.
- `MqttDeserializationException` — an incoming payload or request response
  could not be decoded, or an event's data type does not match `T`; it is
  reported on `bus.errors` and the node keeps running.
- `MqttPublishException` — a publish failed after the connection check.
- `MqttSubjectException` — a topic or subscription cannot be represented.
- `MqttConnectionException` — connection use after close or exhausted retries.

## Guarantees and limitations

- The transport targets **MQTT 5 only**. MQTT 3.1.1 brokers and clients are not
  supported.
- `fire` uses the configured QoS (default `atMostOnce`). Core MQTT has no
  end-to-end acknowledgement; QoS 1/2 are handled by the broker's session
  layer, and the bus itself does not deduplicate redeliveries.
- Retained messages are delivered by the broker on subscription (default MQTT
  retain handling) and become `currentData`; the bus never sets the retain flag
  on publishes.
- There are no shared subscriptions or consumer groups: every subscribed bus
  receives a request.
- Ordering across publishers is not guaranteed.
- The local-only members keep their local meaning: `haveListener` and
  `haveHandler` only see this process, and `allEventStream` sees outgoing
  events, not incoming ones.
- `MqttSubjectMapper` keeps the core `>` (one-or-more) semantics even though
  the broker's `#` is zero-or-more.
- `runtimeType` as a wire address is not stable under web minification or AOT
  obfuscation. Use `typeTags` before deploying.

## Tests

```powershell
# unit tests, fake connection, no broker
dart test

# with a live MQTT 5 broker, including integration tests
$env:MQTT_URL = "mqtt://127.0.0.1:1883"
dart test
```

The integration file skips itself when `MQTT_URL` is not set.
