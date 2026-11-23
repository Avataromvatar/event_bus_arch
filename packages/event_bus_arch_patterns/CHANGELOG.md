## 0.1.0

- Initial package: `FSM`, `Scope` and `Command` moved out of the `event_bus_arch` core so the
  bus package stays a routing library.
- Targets `event_bus_arch` `^4.1.0`.
- The FSM resets its transition-in-progress flag in a `finally`, so a handler exception no
  longer leaves the machine stuck.
- `Command.execute` sends a request only when a local handler accepts the value type; a handler
  of another type on the same address no longer takes the request path.
