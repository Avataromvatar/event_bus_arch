# 07. Platforms

[← API reference](06-api-reference.md) · [Documentation index](README.md)

The core bus works on the Dart VM and in the browser. Isolate-based APIs are VM-only.

## 1. Capability matrix

| Feature | VM / Flutter mobile and desktop | Browser (JS/Wasm) |
|---|---|---|
| `EventBus`, `listen`, `subscribe` | yes | yes |
| Model bus, `currentData`, `remove` | yes | yes |
| Handlers, request lifecycle, cancellation | yes | yes |
| `errors`, `EventBusErrorMonitor` | yes | yes |
| Observability (`ObservabilityConfig`, metrics) | yes | yes |
| `EventBusIsolate` | yes | **no** |
| `Layers`, `LayersSupervisor` | yes | **no** |
| `WorkerPool` | yes | **no** |
| `event_bus_arch_transport` seam | yes | yes |
| `event_bus_arch_nats` connection | yes (`dart_nats`, TCP) | **no** |
| `event_bus_arch_mqtt` shipped connection | yes (`MqttServerClient`) | **no** |

```dart
if (EventBusCapabilities.isolateSupported) {
  // EventBusIsolate, Layers, WorkerPool
} else {
  // local bus + a transport
}
```

`EventBusIsolate`, `Layers.createLayers`, `Layers.supervise` and `WorkerPool` throw
`UnsupportedError` at construction in the browser, before touching `dart:isolate`.

## 2. Web checks

```bash
dart test -p chrome test/web_smoke_test.dart
dart compile js tool/web_compile_check.dart -o build/web_check.js
```

The core package, model buses, subscriptions, observability and `event_bus_arch_transport`
compile for the web.

## 3. Broker adapters in the browser

`event_bus_arch_transport` is platform-neutral: it contains the connection seam, address mapping
and codecs, not a client. The shipped NATS and MQTT connections are VM-only.

- **NATS:** the broker supports WebSocket, but `dart_nats` is TCP-only. A browser application needs
  a custom `TransportConnection` over a browser WebSocket.
- **MQTT:** `mqtt5_client` provides `MqttBrowserClient`; wrap it in a custom `TransportConnection`
  and pass it to `EventBusMqtt.keys(..., connection: ...)`.

```dart
final bus = EventBusMqtt.keys(
  Uri.parse('wss://broker.example/mqtt'),
  connection: BrowserMqttConnection(url),
  codecs: codecs,
);
```

Sockets and isolate ports cannot cross an isolate boundary. A transport lives in one isolate, or
is proxied through a `SendPort`; in the browser there are no isolates to cross.

## 4. Platform notes

- `EventBusCapabilities.transportSupported` is true on both platforms: the seam is portable.
- Keep platform-specific client imports out of shared code; inject a `TransportConnection`.
- Flutter Web uses the browser path; the rest of the Flutter targets use the VM path.
