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

The transport is functional: topics map to NATS subjects (with an optional
prefix and type tags), serializers publish, deserializers subscribe (wildcards
included), `arguments` travel in headers, the bus reconnects with backoff and
filters its own echo. While the server is unavailable, `send` on a transport
topic throws instead of silently buffering.

Still missing before a stable release: full documentation, remote request/reply
(the `completer` over NATS) and at-least-once delivery (JetStream).
