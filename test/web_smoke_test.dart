@TestOn('browser')
library;

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

///A minimal web-target smoke test: the local bus must work in a browser.
///
///The isolate API is intentionally not exercised here; on the web it throws
///`UnsupportedError` once the capability guard lands (see ADR-0008).
void main() {
  test('a common bus delivers fire to a listener on the web target', () async {
    final bus = EventBus();
    final received = <int>[];
    final sub = bus.subscribe<int>(paths: ['web'], onData: received.add);

    expect(bus.fire<int>(1, paths: ['web']), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(received, [1]);

    await sub.cancel();
    await bus.dispose();
  });

  test('a model bus retains currentData on the web target', () async {
    final bus = EventBus(isModelBus: true);

    bus.fire<String>('value', paths: ['web', 'model']);
    expect(bus.currentData<String>(paths: ['web', 'model']), 'value');

    expect(bus.removeTopic<String>(paths: ['web', 'model']), isTrue);
    expect(bus.currentData<String>(paths: ['web', 'model']), isNull);

    await bus.dispose();
  });
}
