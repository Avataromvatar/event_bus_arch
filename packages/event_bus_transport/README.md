# event_bus_transport

Broker-agnostic transport layer for
[`event_bus_arch`](https://pub.dev/packages/event_bus_arch). It contains no
broker client and no broker-specific grammar: a concrete transport package
supplies a connection adapter and a `SubjectGrammar`.

`event_bus_nats` is the reference adapter; MQTT 5 uses the same layer.

## What is here

| Type | Responsibility |
|---|---|
| `TransportConnection` | The transport seam: status, errors, publish, subscribe, request |
| `TransportMessage` | One message as it exists on the wire: subject, bytes, arguments, reply subject |
| `ReconnectingTransportConnection` | Connection lifecycle, status/errors streams, subscription registry, reconnect backoff |
| `ReconnectPolicy` | Exponential backoff |
| `SubjectGrammar` | Separator and wildcard symbols (`*`/`>` locally, broker symbols on the wire) |
| `TopicSubjectMapper` | Local topic ↔ wire subject, prefix, type tags, validation |
| `TopicRegistryIndex<T>` | Exact → type → most-specific-pattern resolution |
| `TransportEventBus` | An `EventBusImpl` that publishes to and subscribes from a broker |
| `TransportEventNode<T>` | A node that publishes outbound events and delivers inbound ones locally |
| `EventBusTransportException` and subclasses | Error types |
| `FakeTransportConnection` (`testing.dart`) | In-memory connection for tests |

## Adding a broker

1. Implement a connection adapter on top of `ReconnectingTransportConnection`:

   ```dart
   class MyConnection extends ReconnectingTransportConnection {
     @override
     Future<void> connectClient() async { /* connect the client */ }
     @override
     Future<void> disconnectClient() async { /* tear it down */ }
     @override
     bool get isClientConnected => /* client reports connected */;
     @override
     void publishRaw(String subject, Uint8List data,
         {Map<String, String>? arguments, String? originId,
          String? replyTo}) { /* publish */ }
     @override
     void subscribeRaw(int id, String subject) { /* subscribe; report via
         dispatchMessage(id, message, origin: origin) */ }
     @override
     Future<void> unsubscribeRaw(int id) async { /* unsubscribe */ }
     @override
     String newReplySubject() => /* an inbox-like subject */;
   }
   ```

   The base replays registrations after a reconnect, filters self-echo by
   `originId`, and implements `request` on top of `subscribe` + `publish`.

2. Implement a `SubjectGrammar` with the broker's separator and wildcard
   symbols. Local topics always use `.` and the canonical wildcards `*` and
   `>`, which the mapper translates.

3. Build a `TransportEventBus` with the connection, a `TopicSubjectMapper`, the
   serializer/deserializer registries and an origin id. `event_bus_nats` is a
   thin subclass/factory around it.

## Publishing and subscribing

A topic is published only when a serializer resolves for it and subscribed only
when a deserializer does. Resolution order is exact topic → type token →
(deserializers only) most specific wildcard pattern.

Nodes are created lazily and with a type: `listen<T>`, `setHandler<T>` and
`fire<T>`/`request<T>` call `createNode<T>`, so the node can check incoming
payload types. A node with a deserializer is a `KeepAliveNode`.

## Requests

`TransportEventBus.request` keeps local semantics when a local handler exists.
Otherwise it publishes the request with a reply subject and waits for the first
response. A node that receives a message with `replyTo` invokes the local
handler through the core `handleIncomingRequest` and publishes the encoded
result back to that reply subject. The response always goes to the reply
subject; a subject returned by the serializer is ignored for responses.

## Tests

```text
dart test
```
