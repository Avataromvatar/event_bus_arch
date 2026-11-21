## 1.1.0

- Targets `event_bus_arch` `^4.0.0` and `event_bus_arch_transport` `^0.2.0`.
- `EventDTO.correlationId` travels in the `X-EventBus-Correlation-Id` NATS header and is attached
  to incoming DTOs; request responses carry it too.
- `EventBusNats` accepts `ObservabilityConfig` and forwards it to `TransportEventBus`.
- Documents that the shipped `dart_nats` adapter is TCP-only and VM-only; the NATS broker supports
  WebSocket, but this client does not.

## 1.0.0

- Initial NATS transport for `event_bus_arch`.
- Lazy typed nodes: `createNode` receives the topic, and `send` creates a node
  for topics present in a serializer or deserializer registry.
- Serializers and deserializers with exact-topic, type-token and wildcard
  resolution; optional subject prefix and type tags.
- `arguments` are transmitted in NATS headers; each bus filters its own echo
  with an origin header.
- Connection adapter with exponential-backoff reconnection, subscription
  restoration and an error stream. A publish while offline throws instead of
  being silently buffered.
- Wildcard subscriptions (`*`, `>`), nodes pinned for the bus lifetime, and a
  fake connection for tests without a server.
