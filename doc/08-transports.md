# 08. Transports

[← 07. Pitfalls](07-caveats.md) · [Contents](README.md) · [Next: event_bus_arch_nats →](09-event-bus-nats.md)

A transport runs the same bus over a broker. The core owns the delivery and dispatch semantics; the
transport package owns the wire mapping and the connection lifecycle. This document describes the
seam and the rules every adapter follows; NATS and MQTT are in [09](09-event-bus-nats.md) and
[10](10-event-bus-mqtt.md).

## 1. Packages

| Package | Version | Role |
|---|---|---|
| `event_bus_arch_transport` | 0.2.0 | `TransportConnection`, `TransportEventBus`, `TransportEventNode`, the reconnecting base, subject mapping, codecs |
| `event_bus_arch_nats` | 1.1.0 | NATS adapter (`dart_nats`, TCP; VM-only) |
| `event_bus_arch_mqtt` | 0.2.0 | MQTT 5 adapter (`mqtt5_client`; VM client, `ws://`/`wss://` on the VM) |

The transport package depends on core `^4.0.0`. A 3.x adapter is not wire-compatible with 4.0: the
metadata and the isolate protocol changed.

## 2. The seam

```dart
abstract class TransportConnection {
  bool get isConnected;
  TransportStatus get status;
  Stream<TransportStatus> get statusStream;
  Stream<Object> get errors;

  Future<void> start();
  void publish(String subject, Uint8List data, {
    Map<String, String>? arguments,
    String? correlationId,
    String? originId,
    String? replyTo,
  });
  Future<TransportMessage> request(String subject, Uint8List data, {
    Map<String, String>? arguments,
    String? correlationId,
    String? originId,
    Duration? timeout,
  });
  TransportSubscription subscribe(String subject,
      void Function(TransportMessage message) onMessage);
  Future<void> close();
}
```

`TransportEventBus` is an `EventBusImpl` whose nodes are `TransportEventNode`s. `createNode` asks the
subject mapper for a subscription and resolves a serializer/deserializer from the registries.
`fire` publishes through the serializer and delivers locally; an incoming message is delivered
locally **without being published again**.

```mermaid
sequenceDiagram
    autonumber
    participant C as Caller
    participant B as TransportEventBus
    participant N as TransportEventNode
    participant Conn as TransportConnection
    participant Broker as Broker
    participant H as Remote handler

    C->>B: request(dto, correlationId: "c-1")
    B->>N: encode with a serializer
    N->>Conn: request(subject, bytes, correlationId)
    Conn->>Broker: publish + reply subject
    Broker->>H: deliver
    H-->>Broker: publish to reply subject (+ correlationId)
    Broker-->>Conn: response message
    Conn-->>N: TransportMessage(correlationId: "c-1")
    N-->>B: decoded EventDTO
    B-->>C: result
```

Key points:

* **No local handler?** `request` goes to the broker; with a local handler the request never leaves
  the process (same rule as an isolate bridge). `NoHandlerException` if neither side has one.
* **Headers/user properties** carry `arguments` and `correlationId`; a broker without metadata
  support cannot carry them. NATS uses headers (2.2+), MQTT 5 uses user properties.
* **Self-echo** is suppressed by the origin id (`X-EventBus-Origin`): a message published by this
  bus is ignored when it comes back. MQTT also sets `noLocal`.
* **Cancellation is local.** Broker-side cancellation is not part of the 4.0 contract: the caller's
  `timeout` bounds the wait; a busy responder sends no reply and the caller times out.
* **One connection per bus** unless a shared connection manager is introduced; disposing a bus
  closes its connection.

## 3. Address mapping

The local topic is `type` plus `paths` (`Order.created.eu`). A `SubjectGrammar` defines the wire
separator and wildcards:

| | Local | NATS | MQTT 5 |
|---|---|---|---|
| Separator | `.` | `.` | separate levels, mapped by the adapter |
| Single wildcard | `*` | `*` | `+` |
| Rest wildcard | `>` (final, one or more) | `>` (final) | `#` (also zero levels) |
| Metadata | DTO fields | headers | user properties |
| Request/reply | in-process | reply subject | response topic |

`TopicSubjectMapper` maps a topic to a subject and back, with an optional prefix and type tags. The
type token is normalised for broker safety (`<` → `(`, `>` → `)`, commas/whitespace → `_`). MQTT's
`#` matches zero levels while the core `>` needs at least one; `TransportEventNode` filters
over-delivered messages so the two grammars agree.

## 4. Serialization

```dart
typedef EventDTOSerialization = (String?, Uint8List) Function(EventDTO dto);
typedef EventDTODeserialization = EventDTO Function(
  Uint8List data, String topic, {Map<String, String>? arguments});
```

Register codecs by a key derived from the type token (and optionally paths). A topic without a
serializer is local-only for `fire`; a topic without a deserializer is not subscribed on the wire.
Codec failures become `EventBusError` of kind `serialization`/`deserialization` and never crash the
connection. The deserializer returns a DTO; the node then attaches the wire correlation id with
`copyWith`.

## 5. Reconnection

`ReconnectingTransportConnection` owns the lifecycle: status, errors, subscriptions and the backoff
schedule. A concrete adapter implements `connectClient`, `disconnectClient`, `isClientConnected`,
`publishRaw`, `subscribeRaw`, `unsubscribeRaw` and `newReplySubject`. Subscriptions are remembered
and replayed after a reconnect; a request waiting across a reconnect fails through its timeout.

```dart
const ReconnectPolicy(
  initial: Duration(seconds: 1),
  max: Duration(seconds: 30),
  multiplier: 2,
  maxAttempts: null,      // null = forever
);
```

## 6. Platform support

The seam and `TransportEventBus` compile and run on the web. The shipped broker connections do not:

* **NATS** — `dart_nats` is TCP-only; the adapter is VM-only. The NATS broker itself supports
  WebSocket, but the Dart client does not.
* **MQTT** — the adapter uses the VM `MqttServerClient`; `ws://`/`wss://` work on the VM. For the
  browser, `mqtt5_client` has `MqttBrowserClient`; wrap it in a custom `TransportConnection` and
  inject it through `connection:`.
* A web application can implement the seam over any browser WebSocket; no broker adapter in the
  browser ships in 4.0.0.

Sockets also cannot cross an isolate boundary: a transport lives in one isolate, or is proxied
through a `SendPort` (the same reason `onInit` must be top-level).

## 7. Pitfalls

1. **Wire-address stability.** The type token is the Dart type name; release-mode minification can
   change `runtimeType` for local/anonymous types. Use explicit `typeTags`/stable topics for a
   production wire format.
2. **Broker limits.** Payload limits, header limits, retained-message semantics and MQTT user
   property size differ; a serializer that works locally may be too large for the broker.
3. **Delivery guarantee.** NATS core is at-most-once, MQTT defaults to QoS 0; reconnects can lose
   the window between disconnect and resubscribe. The bus does not add broker-side durability.
4. **Self-echo.** Keep the origin id stable for a bus; without it the bus cannot filter its own
   publications, and a fire can loop through the broker.
5. **Cancellation.** There is no broker-side unsubscribe for in-flight requests; the caller's
   timeout and the responder's capacity are the controls.
6. **Request redefinition.** A broker request is answered by the first response; the transport
   resolves one local handler exactly (exact then pattern, one answer) to avoid duplicate replies.
7. **Web.** Do not instantiate the shipped NATS/MQTT connections in a browser; use the seam with a
   browser connection.
8. **Isolate + transport.** A transport is confined to its isolate; workers that need it should
   receive events through a bridge, not open their own sockets.

[Next: event_bus_arch_nats →](09-event-bus-nats.md)
