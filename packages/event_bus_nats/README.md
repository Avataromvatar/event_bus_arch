# event_bus_nats

NATS transport for `event_bus_arch`.

The package is under development; the API is not stable yet.

## Planned behaviour

- A topic used with `event_bus_arch` (`int.sensor.temp.value`) is mapped to a
  NATS subject with the same dot-separated shape.
- `serializers` define which topics are published to the server.
- `deserializers` define which topics are received from the server.
- The bus tracks the connection itself and reconnects when it can. While the
  server is unavailable, `send` on a transport topic reports the failure to
  the caller instead of silently buffering the event.
- Wildcards follow the NATS grammar: `*` for one token, `>` for the tail.

## Status

The core hooks (`createNode` receives the topic, the type token is normalised
to a broker-safe token) are in place. The connection adapter and the NATS
direction of the node are the next steps.
