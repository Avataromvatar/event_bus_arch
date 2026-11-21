## 0.2.0

- Targets `event_bus_arch` `^4.0.0`.
- `TransportMessage` and `TransportConnection.publish`/`request` carry an optional
  `correlationId`; the transport node attaches it to incoming DTOs and forwards it on replies.
- `TransportEventBus` accepts `ObservabilityConfig` and reports remote request metrics.
- `FakeTransportConnection` records the correlation id on captured publishes and requests.
- The package compiles and runs on the web; a concrete `TransportConnection` decides the
  platform.

## 0.1.0

- Initial shared transport layer: connection seam, reconnecting lifecycle,
  subject grammar and mapper, registry index, transport bus and node, shared
  exceptions, and a fake connection for tests.
