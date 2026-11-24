# ADR-0010: Keyed transport seam and node lifecycle

- Status: Accepted
- Date: 2026-11-24
- Current in: 4.1.1

## Context

NATS, MQTT and any future broker must share one seam without forcing the core to depend on a
broker client. The transport also has to preserve the keyed model: the wire subject is an explicit
application address, the payload type is local, and a pattern/supertype subscription must not
publish a second copy of an event that an exact subscription already sent.

A broker can be offline, a publish can fail, a request can be cancelled, and a dynamic address can
otherwise leave an unused subscription alive forever. Those failure and lifecycle paths belong to
the shared transport package, not to each adapter.

## Decision

1. `TransportEventBus.keys(connection:, addresses:, codecs:, originId:, observability:)` extends
   the core bus. `EventAddressMapper` translates addresses/patterns to broker subjects using a
   `SubjectGrammar` and an optional namespace; `EventCodecRegistry` resolves an exact codec first,
   then the most specific pattern.
2. `EventCodec.encode` returns `(overrideSubject?, bytes)` and `decode(data, address,
   {arguments})` returns an `EventDTO`. `EventCodecRegistry` exposes `canEncode`/`canDecode`; a
   codec may intentionally support only one direction.
3. A `TransportKeyEventNode<T>` is created lazily for a key or pattern selector. It subscribes to
   the broker only when a decoder can resolve for the selector (a pattern node subscribes when the
   registry has any decoder, because individual messages resolve by concrete address). Only the
   exact-key node whose key equals the fired DTO key publishes; pattern and supertype nodes deliver
   locally and never republish.
4. `fire` delivers locally first and then publishes. If the broker is offline or the publish throws,
   the local listeners and `currentData` remain updated and the transport exception propagates.
   A node created solely to publish a fire is detached after delivery; a node loses its broker
   subscription when its last local listener/handler is cancelled. `remove(selector)` is the
   explicit eviction.
5. `request` uses a local handler that accepts the data first. Otherwise both encoder and decoder
   are required; the request is published with a reply subject and the first response is decoded.
   `CancelToken` cancels the caller-side future with `RequestCanceledException`; the underlying
   broker request continues until its own timeout and a late response is ignored. There is no
   broker-side cancel message in 4.1.1.
6. An incoming request resolves exactly one answering registration through
   `handlerAddressFor(address, data)`, invokes the core `handleIncomingRequest`, encodes the result
   and publishes it to the incoming `replyTo`. Overlapping exact/pattern nodes cannot both answer.
7. `replyTo` is validated with the address mapper before publishing. An invalid subject is reported
   as a transport error and nothing is published. The response always goes to `replyTo`; an
   encoder-returned subject is ignored for responses.
8. `TransportMessage` carries the subject, bytes, arguments, correlation id and reply subject.
   Transport errors are emitted as `EventBusError` data with the transport source and a redacted
   envelope.
9. `event_bus_arch_nats` and `event_bus_arch_mqtt` provide only the broker-specific
   `SubjectGrammar`, connection adapter and factories; shared code stays in
   `event_bus_arch_transport`. Type tags, string serializer registries and the legacy
   `TransportEventNode` are not part of the keyed path.

## Consequences

- An offline broker cannot erase an event that already reached local listeners; the caller still
  receives the transport failure.
- A dynamic address does not leave a permanent broker subscription after its last local consumer.
- A transport request is cancellable at the caller but not at the broker; this is an explicit
  contract and a future feature may add a cancel protocol.
- The exact-key-only publish rule prevents duplicate delivery when an exact node and a pattern or
  supertype node both match.
- A codec that supports only one direction can fire but cannot request; `probeRequest` exposes the
  capability as `transportRequests` (`canRequest` combines it with handler interest) rather than
  treating every codec as request-capable.

## Alternatives considered

- **Publish from every matching node.** Rejected: duplicate wire messages when exact and pattern
  subscriptions overlap.
- **Publish before local delivery.** Rejected: an offline broker would lose the local event and
  `currentData`.
- **Pin every transport node for the bus lifetime.** Rejected: dynamic addresses leak broker
  subscriptions.
- **Cancel the broker request on token cancellation.** Rejected for 4.1: no standard broker
  primitive; the caller-side future is the contract.
- **Let each adapter implement its own bus/node lifecycle.** Rejected: duplicated failure handling
  and divergent semantics.
