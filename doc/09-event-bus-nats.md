# 09. `event_bus_arch_nats`: running the bus over NATS

[← 08. Transports](08-transports.md) · [Contents](README.md)

This chapter describes the NATS transport implemented in
[`packages/event_bus_arch_nats`](../packages/event_bus_arch_nats) 1.1.0 against core `^4.0.0` and
`event_bus_arch_transport` 0.2.0. The seam itself is described in
[08-transports.md](08-transports.md).

---

## 1. Scope

`EventBusNats.keys` is an `EventBus` that keeps the local API (`fire`, `request`,
`listen`, `subscribe`, `subscribe`, `currentData`) and adds a NATS direction:

* an `EventCodec` decides how an outgoing event becomes bytes and how incoming bytes become an
  `EventDTO`;
* the event **address** is the NATS subject;
* the transport owns connection state, reconnection and subscriptions.

The bus does not require a code generator. The price is a registry of codecs, kept in sync by the
application on both sides of the wire.

The NATS package is a thin adapter. The lifecycle, codecs, mapping, node and bus live in
[`packages/event_bus_arch_transport`](../packages/event_bus_arch_transport) and are shared with the
MQTT 5 transport; this package supplies the `dart_nats` client adapter, the NATS grammar and the
public `Nats*` names.

---

## 2. Architecture

```text
EventBusNats.keys                NATS factory and public aliases
 └── TransportEventBus.keys      shared bus: codecs, createNodeForKey, request
      ├── NatsAddressMapper      address <-> NATS subject, optional prefix
      │    └── NatsGrammar       NATS separator and wildcard symbols
      ├── EventCodecRegistry     encoder/decoder resolution by address or pattern
      ├── TransportConnection    transport seam
      │    └── ReconnectingTransportConnection
      │         └── DartNatsConnection   dart_nats client, headers
      └── TransportKeyEventNode<T>  one per key
           ├── EventNodeImp<T>   local value stream and currentData
           └── EventCodec        encode on publish, decode on subscribe
```

`dart_nats` is imported only by `dart_nats_connection.dart`. Everything else depends on
`TransportConnection`, which is what makes the bus testable without a server.

---

## 3. Address to subject

An event address is a dot-separated string, for example `orders.placed.v1`. By default this is also
the NATS subject. The address is user-supplied: no Dart type name and no `typeTags` are involved.

Two optional mappings sit at the boundary:

* **`subjectPrefix`** namespaces every subject. `acme.shop` turns `orders.placed.v1` into
  `acme.shop.orders.placed.v1`; the prefix is stripped before the codec runs.
* the grammar fix-ups: `*` stays `*`, `>` stays `>` (it must be the last token).

`NatsAddressMapper` validates the grammar in both directions:

* publish: no `*` or `>`, no empty tokens, dots or whitespace inside a token, no `$`-prefixed first
  token, `.` separator only;
* subscribe: `*` is a whole token, `>` may only be the last token, mixed tokens such as `sen*or`
  are rejected.

```dart
final addresses = NatsAddressMapper(prefix: 'acme.shop');
addresses.toSubject(EventKey<Order>('orders.placed'));   // acme.shop.orders.placed
addresses.toAddress('acme.shop.orders.placed');          // orders.placed
```

---

## 4. Codecs and resolution

`EventCodecRegistry` keys are addresses or address patterns without the prefix. Resolution is
deterministic:

| Direction | Order |
|---|---|
| Publish | exact address → most specific matching pattern |
| Subscribe | exact address → most specific matching pattern |

The most specific pattern has the most literal tokens; ties keep the insertion order of the
registry. An address is published only when a codec with `encode` resolves for it, and a node
subscribes only when a codec with `decode` resolves.

```dart
final bus = EventBusNats.keys(
  Uri.parse('nats://127.0.0.1:4222'),
  subjectPrefix: 'acme.shop',
  codecs: EventCodecRegistry(
    exact: {
      EventAddress('orders.placed.v1'): EventCodec(
        encode: (dto) =>
            (null, Uint8List.fromList(utf8.encode(jsonEncode(dto.data)))),
        decode: (data, address, {arguments}) => EventDTO.withKey(
          EventKey<Order>(address.value),
          Order.fromJson(jsonDecode(utf8.decode(data))),
          arguments: arguments,
        ),
      ),
    },
    patterns: {
      EventPattern('orders.*'): EventCodec(decode: decodeAnyOrder),
    },
  ),
);
```

---

## 5. Outbound flow

`fire(key, data)` is the ordinary core method. The core creates a node lazily for an address present
in the codec registry (`shouldCreateNodeOnSendKey`); for any other address, a fire with no node
still returns `false`, exactly like a local bus.

`TransportKeyEventNode.deliver` then:

1. checks `connection.isConnected` and throws `NatsServerUnavailableException` before local
   delivery when the server is unavailable;
2. calls the encoder (a failure becomes `NatsSerializationException`);
3. uses the encoder's subject override or maps the address; an override is validated as a full wire
   subject;
4. publishes with the origin header, `X-EventBus-Arguments` and `X-EventBus-Correlation-Id` when
   the DTO has a correlation id;
5. delivers the event to local listeners. Request handlers are invoked by `request`, not by `fire`.

Only the node whose exact key equals the DTO key publishes. A pattern or supertype node delivers
locally without a second publication.

Publishing before local delivery is deliberate: a failed transport send must not look like a
successful local one.

---

## 6. Inbound flow

A node with a decoder subscribes as soon as it is created. The subject is
`addresses.toSubject(selector, subscription: true)`, so `*` and `>` are passed to the server and the
server does the matching.

On an incoming message the node:

1. strips the prefix and maps the concrete subject to an `EventAddress`;
2. resolves the codec for that concrete address and calls `decode` with the payload, the address
   and the arguments from the headers;
3. attaches the wire correlation id to the decoded DTO (`copyWith`) when the
   `X-EventBus-Correlation-Id` header is present;
4. checks that `dto.data is T`;
5. delivers the event with `EventNodeImp.deliver` (or `deliverIncoming` when a request handler
   dispatches it), **without** publishing it again.

Decoding failures and type mismatches are reported on `bus.errors`; the node and its subscription
stay alive.

The node is a `KeepAliveNode`: the transport owns an incoming subscription, so cancelling the last
local listener does not remove the node, its subscription or its `currentData`; `bus.dispose()`
does. `haveHandler` reflects request handlers registered on the bus, not the transport
subscription.

### Remote requests

`request(key, data)` first resolves a local handler. When one exists, the request never leaves the
process, exactly as on a local bus. When none does, and the key has both directions of a codec, the
request is published to the mapped subject with a NATS inbox (`_INBOX.…`) as the reply subject:

1. the requester's encoder encodes the request DTO;
2. `TransportConnection.request` subscribes to the inbox, publishes, and waits for the first
   response or the timeout;
3. on the responder the node decodes the message, invokes the local handler through the bus's
   `handleIncomingRequest`, and publishes the encoded result back to `replyTo` with the request's
   correlation id;
4. the requester decodes the response with the decoder registered for the request address and
   returns `dto.data`.

The response always goes to the inbox: an encoder subject override is ignored for responses. The
responder's encoder therefore has to encode the handler's return value under the request address.
Without a local handler and without a transport route the call throws `NoHandlerException`; a bus
without a matching handler stays silent, and the requester sees `TimeoutException`.

Only the node whose key equals the handler's registration key answers. A request can arrive on
several overlapping subscriptions (an exact listener node and a pattern handler node, for example),
so without this rule the handler would run once per matching node and listeners would see the
request several times. There are no queue groups, so every subscribed bus still receives the
request.

---

## 7. Connection and reconnection

The adapter owns one `dart_nats` client per connection attempt. The client's own retry loop is
disabled, so there is a single owner of the lifecycle.

* `NatsReconnectPolicy` implements exponential backoff (1s → 2s → 4s … up to 30s, unlimited by
  default; `maxAttempts` caps it).
* On a successful connection the adapter subscribes every registration from its local registry. The
  registry is the source of truth, not the codec map: it holds the exact subject and callback of
  every active node.
* Subscriptions are created only after the client reports `connected`, so the client's internal
  resubscribe cannot duplicate them.
* Publishing uses `buffer: false`. With the client default, a message written while offline would
  be queued and reported as sent, which contradicts the bus's contract; the adapter throws instead.
* `close()` is idempotent: it stops the timer, cancels subscriptions and the status listener, and
  force-closes the client.

The bus exposes `isConnected`, `status`, `connectionStatus`, `waitConnected` and the merged `errors`
stream.

---

## 8. Self-echo, arguments and correlation

NATS delivers a published message to every matching subscription on the connection, including one
owned by the publisher. Without a filter, a node that both publishes and subscribes to an address
would deliver its own event twice.

The adapter writes `X-EventBus-Origin: <bus id>` on every publish and drops messages whose origin
equals its own id before invoking any callback. The local send already delivered the event to local
listeners, so they see it once.

`arguments` are JSON-encoded into `X-EventBus-Arguments`. The decoder receives them as the named
`arguments` parameter and decides whether to copy them into the DTO.

`EventDTO.correlationId`, when present, is written to `X-EventBus-Correlation-Id`; the receiving
node attaches it with `copyWith`. It crosses fire and request/reply alike.

Both headers need NATS 2.2+. With `useHeaders: false` they are disabled, and the bus no longer
filters its echo and carries neither arguments nor a correlation id.

---

## 9. Errors

| Error | Where |
|---|---|
| `NatsServerUnavailableException` | `publish` while the connection is down |
| `NatsSerializationException` | encoder threw; reaches the sender |
| `NatsDeserializationException` | broken or mismatched incoming payload; `bus.errors` |
| `NatsPublishException` | payload too large, or a publish that failed after the check |
| `NatsSubjectException` | invalid address, subject or codec key |
| `NatsConnectionException` | connection use after close, exhausted retries |

Asynchronous failures are reported on `errors`. Errors that happen before `publish` returns are
thrown from the returned future.

---

## 10. Guarantees and limitations

* **At-most-once.** Core NATS has no acknowledgement and no persistence. JetStream is not used.
* **No global ordering.** The local bus is strictly ordered per node; a broker with multiple
  publishers is not.
* **Local-only members stay local.** `haveListener` and `haveHandler` inspect this process;
  `allEventStream` sees outgoing events, not incoming ones.
* **Requests prefer the local handler.** A remote request is sent only when no local handler is
  registered; there are no queue groups, so every subscribed bus receives it and answers on the
  inbox.
* **The address is the wire contract.** Put a version in it (`orders.placed.v1`); never derive it
  from `T.toString()` or `runtimeType`. Minification renames user classes.
* **No cross-bus node copy.** `EventNodeNatsImpl.copy()` throws.
* The server's `maxPayload` is checked before publishing.

---

## 11. Testing

Unit tests use `FakeNatsConnection`: no server, full control over status, captured publishes and
injected incoming messages. Integration tests are skipped unless `NATS_URL` is set:

```text
NATS_URL=nats://127.0.0.1:4222 dart test
```

They cover the adapter (publish, echo filter, arguments, correlation) and the bus (two buses
exchanging events, wildcard delivery, arguments, publisher not receiving its own echo, remote
request/reply and its timeout). The broker-backed integration tests are skipped without a server;
the transport seam is covered by the fake in `packages/event_bus_arch_transport/test`. The keyed
tests in `test/key_nats_test.dart` cover codec publication and the address mapper.

---

## File map

| File | Responsibility |
|---|---|
| `event_bus_arch_nats_base.dart` | `EventBusNats`: NATS factory over `TransportEventBus` |
| `nats_connection.dart` | `NatsConnection` aliases, statuses, message, options |
| `dart_nats_connection.dart` | `dart_nats` client adapter: connect, headers, subscriptions |
| `nats_subject.dart` | `NatsGrammar` and `NatsAddressMapper` |
| `nats_reconnect_policy.dart` | `NatsReconnectPolicy` alias for `ReconnectPolicy` |
| `nats_exception.dart` | `Nats*` aliases for the shared transport errors |

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
