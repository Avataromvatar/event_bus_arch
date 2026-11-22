# 10. `event_bus_arch_mqtt`: running the bus over MQTT 5

[← 09. event_bus_arch_nats](09-event-bus-nats.md) · [Contents](README.md)

This chapter describes the MQTT 5 transport implemented in
[`packages/event_bus_arch_mqtt`](../packages/event_bus_arch_mqtt) 0.2.0 against core `^4.0.0` and
`event_bus_arch_transport` 0.2.0. It builds on the shared layer, so the architecture is the same as
in [09-event-bus-nats.md](09-event-bus-nats.md); this chapter covers what MQTT changes.

---

## 1. Scope

`EventBusMqtt.keys` keeps the local API (`fire`, `request`, `listen`, `subscribe`,
`subscribeEvents`, `currentData`) and adds an MQTT direction. The transport talks to an **MQTT 5**
broker only: it relies on user properties (`arguments`, origin, correlation), the response topic
(request/reply) and `noLocal` (echo suppression), none of which exist in MQTT 3.1.1.

The Dart client is `mqtt5_client`; it is imported only by `mqtt5_client_connection.dart`. The
shipped connection uses the VM `MqttServerClient`; `mqtt5_client` also provides `MqttBrowserClient`
for a custom web connection (see [14](14-web.md)).

---

## 2. Architecture

```text
EventBusMqtt.keys                MQTT factory and public aliases
 └── TransportEventBus.keys      shared bus: codecs, createNodeForKey, request
      ├── MqttAddressMapper      address <-> MQTT topic, `/` separator, `+`/`#`
      │    └── MqttGrammar       level and wildcard validation
      ├── EventCodecRegistry     encoder/decoder resolution by address or pattern
      ├── TransportConnection    transport seam
      │    └── ReconnectingTransportConnection
      │         └── MqttServerConnection   mqtt5_client, user properties
      └── TransportKeyEventNode<T>  one per key
           ├── EventNodeImp<T>   local value stream and currentData
           └── EventCodec        encode on publish, decode on subscribe
```

---

## 3. Address to topic

The local address `orders.placed.v1` becomes the MQTT topic `orders/placed/v1`. Local addresses
always use `.`; MQTT uses `/`. The address is user-supplied: no Dart type name and no `typeTags`
are involved.

Options:

* **`subjectPrefix`** (`acme/shop`) namespaces every topic: `acme/shop/orders/placed/v1`. It is
  stripped before the codec runs.
* the grammar fix-ups: `*` → `+`, `>` → `#`.

`MqttGrammar` validates both directions:

* publish: a level must not be empty, contain `/`, `+`, `#` or a null character; the first level
  must not start with `$`;
* subscribe: `+` and `#` must be whole levels, `#` only the last one, mixed tokens such as `sen+or`
  are rejected.

```dart
final addresses = MqttAddressMapper(prefix: 'acme/shop');
addresses.toSubject(EventKey<Order>('orders.placed'));   // acme/shop/orders/placed
addresses.toAddress('acme/shop/orders/placed');          // orders.placed
```

---

## 4. Wildcards and the `#` difference

Core semantics: `*` matches exactly one token, `>` matches one or more trailing tokens. MQTT: `+`
matches exactly one level, `#` matches **zero or more** trailing levels.

The mapper translates the symbols:

```text
sensor.*  ->  sensor/+
sensor.>  ->  sensor/#
```

A broker subscription to `sensor/#` also receives the parent topic `sensor`. The local address
`sensor` does not match the core pattern `sensor.>`, so the node re-checks the `EventPattern`
after decoding and drops the over-delivered message. This keeps the bus semantics identical across
transports; the check is a no-op for NATS, where `>` already requires one trailing token.

---

## 5. Outbound flow

`fire(key, data)` creates a node lazily for an address present in the codec registry
(`shouldCreateNodeOnSendKey`); for any other address it keeps local semantics.

`TransportKeyEventNode.deliver` then:

1. checks `connection.isConnected` and throws `MqttServerUnavailableException` before local
   delivery when the broker is unavailable;
2. calls the encoder (a failure becomes `MqttSerializationException`);
3. uses the encoder's topic override or maps the address; an override is validated as a full wire
   topic;
4. publishes with QoS from `MqttConnectionOptions.qos`, the origin user property,
   `X-EventBus-Arguments` and `X-EventBus-Correlation-Id` when the DTO has a correlation id;
5. delivers the event to local listeners.

Only the node whose exact key equals the DTO key publishes. A pattern or supertype node delivers
locally without a second publication.

Publishing before local delivery is deliberate: a failed transport send must not look like a
successful local one. Because MQTT has no publish-buffer contract in this adapter, a publish is
synchronous at the client API level; failures throw `MqttPublishException`.

---

## 6. Inbound flow

A node with a decoder subscribes as soon as it is created. The adapter creates the subscription with
MQTT 5 `noLocal` by default, so the broker does not send a client its own publications. The server
does the wildcard matching.

On an incoming message the adapter:

1. extracts the topic, payload, response topic and user properties;
2. reads the MQTT 5 subscription identifier and calls the base with exactly the registration that
   matched; when the broker omits identifiers, it falls back to matching all local filters;
3. the base applies the origin filter;
4. the node strips the prefix, maps the concrete topic to an `EventAddress`, resolves the codec for
   that address, decodes, re-checks the core wildcard pattern (the `#` case), attaches the
   correlation user property (`copyWith`), checks `dto.data is T`, and delivers locally without
   publishing again.

Every subscription gets a unique subscription identifier (the registration id plus one). This
matters when filters overlap: an exact node and a pattern node on the same client both match a
topic, and a broker may send one PUBLISH per matching subscription. The identifier tells the adapter
which registration the copy belongs to, so each node receives the event once. A broker that sends
one PUBLISH carrying several identifiers also works: each node is notified once.

Decoding failures and type mismatches are reported on `bus.errors`; the node and its subscription
stay alive.

The node is a `KeepAliveNode`: cancelling the last local listener does not remove the node or its
subscription; `bus.dispose()` does.

---

## 7. Request/reply

`request(key, data)` keeps local semantics when a handler is registered. Otherwise the request is
published with a unique `_INBOX/...` topic in the MQTT 5 **response topic** property.

1. The requester encodes the request and publishes it.
2. The responder's node sees `responseTopic`, invokes the local handler through the core
   `handleIncomingRequest`, and publishes the result to that topic.
3. The requester decodes the first response with the codec registered for the request address.

The response always goes to the response topic; an encoder topic override is ignored for responses.
The responder's encoder must encode the handler's return value under the request address. Without a
local handler and without a transport route the call throws `NoHandlerException`; a responder
without a handler reports `NoHandlerException` on `bus.errors`, and the requester sees
`TimeoutException`.

Only the node whose key equals the handler's registration key answers, so a request that matches
both an exact node and a pattern node is answered once and reaches listeners once. Correlation data
is not used: every request gets its own response topic. A bus without a matching handler stays
silent. There are no shared subscriptions, so every subscribed bus receives the request.

---

## 8. Connection and reconnection

The adapter owns one `mqtt5_client` client per connection attempt; the client's own auto-reconnect
is disabled. The shared base supplies exponential backoff (`MqttReconnectPolicy`, default 1s → 30s,
unlimited) and replays the subscription registry after a reconnect.

* `cleanStart` is true by default. A persistent session is possible with `cleanStart: false` and a
  session expiry interval, but the bus resubscribes from its own registry regardless.
* The default client id is derived from the bus origin id; a fixed `clientId` must be unique per
  live connection.
* `mqtt://`, `mqtts://`, `ws://` and `wss://` are supported with the usual default ports;
  `mqtts`/`wss` set the client's `secure` flag.
* The bus exposes `isConnected`, `status`, `connectionStatus`, `waitConnected` and the merged
  `errors` stream.

---

## 9. Errors

| Error | Where |
|---|---|
| `MqttServerUnavailableException` | `fire` while the connection is down |
| `MqttSerializationException` | encoder threw; reaches the sender |
| `MqttDeserializationException` | broken or mismatched payload; `bus.errors` |
| `MqttPublishException` | a publish failed after the connection check |
| `MqttSubjectException` | invalid address, filter or codec key |
| `MqttConnectionException` | connection use after close, exhausted retries |

Asynchronous failures are reported on `errors`. Errors that happen before `fire` returns are thrown
from the call.

---

## 10. Guarantees and limitations

* **MQTT 5 only.** MQTT 3.1.1 lacks user properties, response topics and `noLocal`.
* **User properties carry metadata.** `arguments`, the origin id and `correlationId` travel as
  MQTT 5 user properties. With `MqttConnectionOptions.useUserProperties: false` none of them are
  transmitted: the origin filter is disabled and the receiver sees no arguments or correlation id.
* **At-most-once by default.** The default QoS is 0. QoS 1/2 are broker session features; the bus
  does not deduplicate redeliveries.
* **Retained messages** are delivered on subscription and become `currentData`. The bus never sets
  the retain flag on publish.
* **No ordering across publishers.** Ordering per client is a broker feature.
* **Local-only members stay local.** `haveListener`/`haveHandler` inspect this process;
  `allEventStream` sees outgoing events only.
* **Requests prefer the local handler.** Remote requests use response topics; there are no shared
  subscriptions.
* **The address is the wire contract.** Put a version in it; never derive it from `T.toString()` or
  `runtimeType`. Minification renames user classes.
* **No cross-bus node copy.** `TransportKeyEventNode.copy()` throws.

---

## 11. Testing

Unit tests use `FakeMqttConnection` (the shared fake): no broker, full control over status, captured
publishes and injected incoming messages. Integration tests are skipped unless `MQTT_URL` is set:

```text
MQTT_URL=mqtt://127.0.0.1:1883 dart test
```

They cover two buses exchanging events, wildcard delivery, echo suppression, arguments,
correlation, request/reply and its timeout. Broker-backed integration tests are skipped without a
broker; the transport seam is covered by the fake in `packages/event_bus_arch_transport/test`. The
keyed tests in `test/key_mqtt_test.dart` cover codec publication and the address mapper.

---

## File map

| File | Responsibility |
|---|---|
| `event_bus_arch_mqtt_base.dart` | `EventBusMqtt`: MQTT factory over `TransportEventBus` |
| `mqtt5_client_connection.dart` | `mqtt5_client` adapter: connect, user properties, subscriptions, matching |
| `mqtt_connection.dart` | `MqttConnection` aliases, options, QoS enum |
| `mqtt_subject.dart` | `MqttGrammar`, `MqttSubjectMapper` (legacy) and `MqttAddressMapper` |
| `mqtt_registry.dart` | `MqttRegistryIndex` alias for `TopicRegistryIndex` (legacy) |
| `mqtt_serialization.dart` | shared serializer/deserializer typedefs (legacy) |
| `mqtt_reconnect_policy.dart` | `MqttReconnectPolicy` alias for `ReconnectPolicy` |
| `mqtt_exception.dart` | `Mqtt*` aliases for the shared transport errors |

Shared layer (`packages/event_bus_arch_transport/lib/src`):

| File | Responsibility |
|---|---|
| `transport_connection.dart` | connection seam, message, status, headers |
| `reconnecting_transport_connection.dart` | lifecycle, registry, reconnect, request/reply |
| `transport_event_bus.dart` | bus, codecs, remote request |
| `transport_key_event_node.dart` | keyed outbound/inbound node, request answering |
| `event_address_mapper.dart` | address ↔ subject mapping |
| `event_codec.dart` | encoder/decoder and registry |
| `transport_exception.dart` | shared error types |
