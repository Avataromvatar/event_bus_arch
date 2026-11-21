## 0.2.0

- Targets `event_bus_arch` `^4.0.0` and `event_bus_arch_transport` `^0.2.0`.
- `EventDTO.correlationId` travels as an MQTT 5 user property and is attached to incoming DTOs;
  request responses carry it too.
- `EventBusMqtt` accepts `ObservabilityConfig` and forwards it to `TransportEventBus`.
- The shipped `MqttServerConnection` uses the VM `MqttServerClient`; `ws://`/`wss://` work on the
  VM. For the browser, `mqtt5_client` provides `MqttBrowserClient`, which can be wrapped in a
  custom `TransportConnection` (no browser adapter ships in 4.0.0).

## 0.1.0

- Initial MQTT 5 transport: `EventBusMqtt`, `MqttServerConnection`,
  `MqttGrammar`/`MqttSubjectMapper`, user-property arguments, `noLocal`
  echo suppression, and NATS-style request/reply through MQTT 5 response
  topics.
