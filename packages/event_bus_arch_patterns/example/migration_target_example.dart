// ignore_for_file: avoid_print

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_patterns/event_bus_arch_patterns.dart';

final calcKey = EventKey<int>('calc');
final stateKey = EventKey<int>('state');

///The 4.0 form of the 3.x sample used by the migration guide:
///handlers as subscriptions, handler errors, Scope/Command and an isolate.
void migrationWorker(EventBus bus, Object? initialData) {
  bus.subscribeEvents(calcKey, handler: (dto, lastData) async {
    if (dto.data < 0) throw ArgumentError.value(dto.data, 'value');
    return dto.data * 2;
  });
}

Future<void> main() async {
  final bus = EventBus();

  // A handler that replaces the old bus.handlers.setHandler.
  final calc = bus.subscribeEvents(calcKey, handler: (dto, lastData) async {
    if (dto.data < 0) throw ArgumentError.value(dto.data, 'value');
    return dto.data * 2;
  });

  print('request 21 -> ${await bus.request(calcKey, 21)}');
  try {
    await bus.request(calcKey, -1);
  } on ArgumentError catch (error) {
    print('handler error reaches the caller: ${error.message}');
  }

  // Scope subscribes with latest(1); Command keeps the call history.
  final scope = Scope<int>();
  await scope.initScope(bus, stateKey, initialData: 0);
  await scope.call(1);
  await scope.call(2);
  await scope.undo();
  print('scope lastData=${scope.lastData} lastCall=${scope.lastCall}');
  scope.disposeScope();

  // The isolate form; the handler is the same subscription API.
  final iso = EventBusIsolate(onInit: migrationWorker);
  await iso.waitInit;
  print('isolate request 21 -> ${await iso.request(calcKey, 21)}');
  await iso.dispose();

  await calc.cancel();
  await bus.dispose();
}
