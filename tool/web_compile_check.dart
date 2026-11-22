// Compile-only check: the core package and the local bus must build for the
// web target.
//
// Run:
//   dart compile js tool/web_compile_check.dart -o build/web_check.js
//
// The isolate APIs are not available on the web; the capability flag must say
// so at compile time (see ADR-0008).

// ignore_for_file: avoid_print

import 'package:event_bus_arch/event_bus_arch.dart';

void main() async {
  final bus = EventBus(
      observability: const ObservabilityConfig(enabled: true));
  final key = EventKey<int>('web.check');
  final sub = bus.subscribe(key, onEvent: (_) {});
  bus.fire(key, 1, correlationId: 'web-check');
  print('web build ok; isolates: ${EventBusCapabilities.isolateSupported}');
  await sub.cancel();
  await bus.dispose();
}
