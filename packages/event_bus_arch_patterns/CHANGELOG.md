## 0.1.0

- Initial package: `FSM`, `Scope` and `Command` moved out of the `event_bus_arch` core so the
  bus package stays a routing library.
- Targets `event_bus_arch` `^4.0.0`.
- The FSM resets its transition-in-progress flag in a `finally`, so a handler exception no
  longer leaves the machine stuck.
