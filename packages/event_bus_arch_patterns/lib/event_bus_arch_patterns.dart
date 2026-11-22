///Higher-level patterns on top of `event_bus_arch`.
///
///The package contains a finite state machine ([FSM]), a latest-value scope
///([Scope]) with call history, and the command abstraction ([Command]) used by
///the scope. They live outside the core package so the bus itself stays a
///routing library and does not depend on these patterns.
library;

export 'src/command.dart';
export 'src/fsm.dart';
export 'src/scope.dart';
