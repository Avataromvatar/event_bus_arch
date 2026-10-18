# 09. `event_bus_nats`: running the bus over NATS

[← 08. Transports](08-transports.md) · [Contents](README.md)

This chapter describes the NATS transport implemented in
[`packages/event_bus_nats`](../packages/event_bus_nats). The earlier analysis in
[08-transports.md](08-transports.md) explains why the broker boundary looks the
way it does and what the MQTT/Redis options would cost.

---

## 1. Scope

`EventBusNats` is an `EventBus` that keeps the local API (`send`, `listen`,
`subscribe`, `setHandler`, `currentData`) and adds a NATS direction:

* a **serializer** decides how an outgoing event becomes bytes;
* a **deserializer** decides how incoming bytes become an `EventDTO`;
* topics are mapped to NATS subjects;
* the transport owns connection state, reconnection and subscriptions.

The bus does not require a code generator. The price is a registry of functions,
kept in sync by the application on both sides of the wire.

---

## 2. Architecture

```text
EventBusNats extends EventBusImpl
 ├── NatsSubjectMapper        local topic <-> wire subject, prefix, type tags
 ├── NatsRegistryIndex        serializer/deserializer resolution
 ├── NatsConnection           transport seam
 │    └── DartNatsConnection  dart_nats client, reconnect, headers
 └── EventNodeNatsImpl<T>     one per topic
      ├── EventNodeImp<T>     local value stream and currentData
      ├── serializer          used by send()
      └── deserializer        used by the NATS subscription
```

`dart_nats` is imported only by `dart_nats_connection.dart`. Everything else
depends on the `NatsConnection` interface, which is what makes the bus testable
without a server.

---

## 3. Topic to subject

A local topic is `<type>.<path...>`, for example `int.sensor.temp`. By default
this is also the NATS subject.

The core normalises the type token before it becomes a topic: `<` → `(`, `>` →
`)`, commas and whitespace → `_`, repeated `_` collapsed. `List<int>` therefore
becomes `List(int)`, which is safe in a subject.

Two optional mappings sit at the boundary:

* **`subjectPrefix`** namespaces every subject. `acme.shop` turns
  `int.sensor.temp` into `acme.shop.int.sensor.temp`; the prefix is stripped
  before the deserializer runs.
* **`typeTags`** replaces the type token with a stable wire name, for example
  `{'int': 'number'}`. Tags must be unique single tokens without `.`, `*`, `>`
  or whitespace.

`NatsSubjectMapper` validates the grammar in both directions:

* publish: no `*` or `>`, no empty tokens, dots or whitespace inside a token,
  no `$`-prefixed first token, `.` separator only;
* subscribe: `*` is a whole token, `>` may only be the last token, mixed tokens
  such as `sen*or` are rejected.

---

## 4. Registries and resolution

Registry keys are local topics without the prefix. Resolution is deterministic:

| Direction | Order |
|---|---|
| Publish | exact topic → type token |
| Subscribe | exact topic → type token → most specific wildcard pattern |

The most specific pattern has the most literal tokens; ties keep the insertion
order of the registry. Patterns are used only for deserializers. A topic that
contains wildcards is resolved by exact/type only, because matching a pattern
against a pattern is ambiguous.

A topic is published only when a serializer resolves for it, and a node
subscribes only when a deserializer resolves.

---

## 5. Outbound flow

`send<T>` is the ordinary core method. The core creates a node lazily for a
topic present in either registry (`shouldCreateNodeOnSend`); for any other
topic, a send with no node still returns `null`, exactly like a local bus.

`EventNodeNatsImpl.send` then:

1. checks `connection.isConnected` and throws
   `NatsServerUnavailableException` before local delivery when the server is
   unavailable;
2. calls the serializer (a failure becomes `NatsSerializationException`);
3. uses the serializer's subject override or maps the topic; an override is
   validated as a full wire subject;
4. publishes with the origin header and `X-EventBus-Arguments`;
5. delivers the event to local listeners. Request handlers are invoked by
   `request`, not by `fire`.

Publishing before local delivery is deliberate: a failed transport send must
not look like a successful local one.

---

## 6. Inbound flow

A node with a deserializer subscribes as soon as it is created. The subject is
`mapper.toSubject(topic, subscription: true)`, so `*` and `>` are passed to the
server and the server does the matching.

On an incoming message the node:

1. strips the prefix and parses the concrete subject into a local topic;
2. calls the deserializer with the payload, the local topic and the arguments
   from the headers;
3. checks that `dto.data is T`;
4. delivers the event with `EventNodeImp.send`, **without** publishing it again.

Deserialization failures and type mismatches are reported on `bus.errors`; the
node and its subscription stay alive.

The node is a `KeepAliveNode`: the transport owns an incoming subscription, so
cancelling the last local listener does not remove the node, its subscription or
its `currentData`; `bus.dispose()` does. `haveHandler` reflects request handlers
registered on the bus, not the transport subscription.

---

## 7. Connection and reconnection

The adapter owns one `dart_nats` client per connection attempt. The client's
own retry loop is disabled, so there is a single owner of the lifecycle.

* `NatsReconnectPolicy` implements exponential backoff (1s → 2s → 4s … up to
  30s, unlimited by default; `maxAttempts` caps it).
* On a successful connection the adapter subscribes every registration from its
  local registry. The registry is the source of truth, not the deserializer
  map: it holds the exact subject and callback of every active node.
* Subscriptions are created only after the client reports `connected`, so the
  client's internal resubscribe cannot duplicate them.
* Publishing uses `buffer: false`. With the client default, a message written
  while offline would be queued and reported as sent, which contradicts the
  bus's contract; the adapter throws instead.
* `close()` is idempotent: it stops the timer, cancels subscriptions and the
  status listener, and force-closes the client.

The bus exposes `isConnected`, `status`, `connectionStatus`, `waitConnected`
and the merged `errors` stream.

---

## 8. Self-echo and arguments

NATS delivers a published message to every matching subscription on the
connection, including one owned by the publisher. Without a filter, a node that
both publishes and subscribes to a topic would deliver its own event twice.

The adapter writes `X-EventBus-Origin: <bus id>` on every publish and drops
messages whose origin equals its own id before invoking any callback. The local
send already delivered the event to local listeners, so they see it once.

`arguments` are JSON-encoded into `X-EventBus-Arguments`. The deserializer
receives them as the named `arguments` parameter and decides whether to copy
them into the DTO.

Both features need NATS 2.2+. With `useHeaders: false` they are disabled, and
the bus no longer filters its echo.

---

## 9. Errors

| Error | Where |
|---|---|
| `NatsServerUnavailableException` | `send` while the connection is down |
| `NatsSerializationException` | serializer threw; reaches the sender |
| `NatsDeserializationException` | broken or mismatched incoming payload; `bus.errors` |
| `NatsPublishException` | payload too large, or a publish that failed after the check |
| `NatsSubjectException` | invalid topic, subject or registry key |
| `NatsConnectionException` | connection use after close, exhausted retries |

Asynchronous failures are reported on `errors`. Errors that happen before
`send` returns are thrown from the returned future.

---

## 10. Guarantees and limitations

* **At-most-once.** Core NATS has no acknowledgement and no persistence.
  JetStream is not used.
* **No global ordering.** The local bus is strictly ordered per node; a broker
  with multiple publishers is not.
* **Local-only members stay local.** `haveListener` and `haveHandler` inspect
  this process; `allEventStream` sees outgoing events, not incoming ones.
* **`completer` is local.** Remote request/reply is not implemented; the
  connection carries `replyTo` for a future API.
* **`runtimeType` is not a stable wire address.** Web release builds minify
  type names, AOT obfuscation renames them. Use `typeTags` or stable explicit
  type names in production.
* **No cross-bus node copy.** `EventNodeNatsImpl.copy()` throws.
* The server's `maxPayload` is checked before publishing.

---

## 11. Testing

Unit tests use `FakeNatsConnection`: no server, full control over status,
captured publishes and injected incoming messages. Integration tests are
skipped unless `NATS_URL` is set:

```text
NATS_URL=nats://127.0.0.1:4222 dart test
```

They cover the adapter (publish, echo filter, arguments) and the bus (two buses
exchanging events, wildcard delivery, arguments, publisher not receiving its own
echo). The example `packages/event_bus_nats/example/event_bus_nats_example.dart`
is a two-bus end-to-end demo.

---

## File map

| File | Responsibility |
|---|---|
| `event_bus_nats_base.dart` | `EventBusNats`, registries, error stream |
| `event_node_nats.dart` | `EventNodeNatsImpl`, outbound/inbound flows |
| `nats_connection.dart` | `NatsConnection`, statuses, message, options |
| `dart_nats_connection.dart` | real client, reconnect, headers, subscriptions |
| `nats_subject.dart` | topic ↔ subject mapping and validation |
| `nats_registry.dart` | exact/type/pattern resolution |
| `nats_serialization.dart` | serializer/deserializer typedefs |
| `nats_reconnect_policy.dart` | backoff |
| `nats_exception.dart` | error types |
