## 0.2.0

- Targets `event_bus_arch` `^4.1.1`.
- `TransportMessage` and `TransportConnection.publish`/`request` carry an optional
  `correlationId`; the transport node attaches it to incoming DTOs and forwards it on replies.
- `TransportEventBus` accepts `ObservabilityConfig` and reports remote request metrics.
- `FakeTransportConnection` records the correlation id on captured publishes and requests.
- The package compiles and runs on the web; a concrete `TransportConnection` decides the
  platform.
- `fire` delivers locally before publishing, so an offline broker does not roll back local
  listeners or `currentData`.
- Keyed nodes are no longer pinned: their broker subscription is cancelled with the last
  listener/handler, and a fire-only node is detached after delivery.
- An incoming `replyTo` is validated before publishing; an invalid subject is reported and not
  published. A request `CancelToken` fails the caller fast while a late response is ignored.
- `probeRequest(...).transportRequests` reports whether a keyed codec has both `encode` and
  `decode`; `canRequest` combines it with local/remote handler interest.

## 0.1.0

- Initial shared transport layer: connection seam, reconnecting lifecycle,
  subject grammar and mapper, registry index, transport bus and node, shared
  exceptions, and a fake connection for tests.
