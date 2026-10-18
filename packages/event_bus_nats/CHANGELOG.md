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
