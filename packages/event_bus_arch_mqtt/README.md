# event_bus_arch_mqtt

MQTT 5 transport for [`event_bus_arch`](https://pub.dev/packages/event_bus_arch).

`EventBusMqtt.keys` is an `EventBus` whose nodes publish to and subscribe from an MQTT 5 broker.
Application code keeps using `fire`, `request`, `listen`, `subscribe` and `subscribe`; the
transport is configured with an `EventCodecRegistry` keyed by event address.

The package is a thin MQTT adapter over
[`event_bus_arch_transport`](../event_bus_arch_transport): the connection lifecycle, subscription
registry, address ↔ topic mapping, node and bus are shared with the NATS transport. This package
supplies the `mqtt5_client` adapter, the MQTT grammar and the public `Mqtt*` names.

## Requirements

- Dart SDK 3.12 or newer (VM; `dart:io` sockets and WebSockets).
- An MQTT **5** broker. MQTT 3.1.1 is not supported: the transport uses user properties, response
  topics and `noLocal`, which only exist in MQTT 5.
- The broker address may be `mqtt://host`, `mqtts://host`, `ws://host` or `wss://host`. Default
  ports are 1883, 8883, 80 and 443.

## Quick start

Two buses in one process: one publishes to the broker, the other receives from it. In a real
application they would usually run in different processes.

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_mqtt/event_bus_arch_mqtt.dart';

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

  final publisher = EventBusMqtt.keys(
    Uri.parse('mqtt://localhost:1883'),
    codecs: EventCodecRegistry(exact: {sensorTemp: intCodec()}),
  );

  final subscriber = EventBusMqtt.keys(
    Uri.parse('mqtt://localhost:1883'),
    codecs: EventCodecRegistry(patterns: {sensorAny: intCodec()}),
  );

  await Future.wait([
    publisher.waitConnected(timeout: const Duration(seconds: 5)),
    subscriber.waitConnected(timeout: const Duration(seconds: 5)),
  ]);

  final received = Completer<int>();
  final subscription = subscriber.subscribe(
    EventPatternKey<int>('sensor.*'),
    onEvent: (value) {
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

A runnable keyed version is in `example/event_bus_arch_mqtt_example.dart`.

## Addresses and topics

The event address `orders.placed.v1` becomes the MQTT topic `orders/placed/v1`. The address is
user-supplied; no Dart type name and no `typeTags` are involved.

`subjectPrefix` namespaces every topic:

```dart
EventBusMqtt.keys(..., subjectPrefix: 'acme/shop');
// orders.placed.v1 -> acme/shop/orders/placed/v1
```

The prefix is stripped before the codec runs, so the codec always receives the local address.

## Codecs

`EventCodecRegistry` keys are addresses or address patterns. Resolution order:

| Direction | Order |
|---|---|
| Publish (`encode`) | exact address → most specific matching pattern |
| Subscribe (`decode`) | exact address → most specific matching pattern |

- An address is published to the broker only when an encoder resolves for it.
- A node subscribes only when a decoder resolves for it.
- The most specific pattern is the one with the most literal tokens; ties keep the insertion order
  of the registry.
- A codec may implement only one direction: a publisher needs `encode`, a subscriber needs `decode`.
- A node is created lazily by `listen`, `subscribe` or `fire`/`request`. `fire` creates a node
  only for an address present in the codec registry; otherwise it keeps local bus semantics and
  returns false.

### Wildcards and the `#` difference

`*` becomes `+` (one level), `>` becomes `#` (zero or more trailing levels). Core `>` requires at
least one trailing token, while MQTT `#` also matches the parent topic; the node re-checks the
`EventPattern` after decoding and drops over-delivered messages, so local semantics stay identical
across transports.

`fire`/`request` require an `EventKey`; a request may be answered by a handler registered on an
`EventPatternKey`.

### Encoder topic override

An encoder may return a non-null first element to publish to a full wire topic instead of the
mapped address. The override is validated as an MQTT publish topic; the node still delivers the
event locally and the incoming subscription still uses the mapped address/pattern. Responses to
requests always go to the response topic, so the override does not apply to them.

## Requests

A request keeps local semantics when a local handler exists. Otherwise it is published with a
unique `_INBOX/...` topic in the MQTT 5 **response topic** property, and the first response is
decoded with the codec registered for the request address. `timeout` is supported; broker-side
cancellation is not part of the 4.0 contract.

## Errors

| Error | Where |
|---|---|
| `MqttServerUnavailableException` | `fire` while the connection is down |
| `MqttSerializationException` | encoder threw; reaches the sender |
| `MqttDeserializationException` | broken or mismatched payload; `bus.errors` |
| `MqttPublishException` | a publish failed after the connection check |
| `MqttSubjectException` | invalid address, filter or codec key |
| `MqttConnectionException` | connection use after close, exhausted retries |

## Tests

```text
dart test
MQTT_URL=mqtt://127.0.0.1:1883 dart test   # broker-backed tests
```
