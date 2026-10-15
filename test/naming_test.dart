import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void _worker(EventBus bus, Object? initialData) {
  bus.handlers.setHandler<String>(handler: (dto, lastData) async {
    dto.completer?.complete('$initialData: ${dto.data}');
  });
}

void _workerOld(EventBus bus, Object? initalData) {}

void main() {
  group('Parameter names', () {
    test('EventBusIsolate accepts initialData', () async {
      final iso = EventBusIsolate(onInit: _worker, initialData: 'prefix');
      await iso.waitInit;

      expect(await iso.send<String>('x'), 'prefix: x');
      await iso.dispose();
    });

    test('the old name initalData keeps working', () async {
      final iso = EventBusIsolate(onInit: _workerOld,
          // ignore: deprecated_member_use_from_same_package
          initalData: 'prefix');
      await iso.waitInit;
      await iso.dispose();
    });

    test('Scope.initScope accepts initialData and initialDataNeedExecute', () async {
      final bus = EventBus(isModelBus: true);
      final scope = Scope<int>();
      await scope.initScope(bus,
          initialData: 7, initialDataNeedExecute: false, maxLenForUndo: 10);

      expect(scope.lastData, 7);
      scope.disposeScope();
      await bus.dispose();
    });
  });
}
