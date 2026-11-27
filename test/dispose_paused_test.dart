import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() {
  group('dispose and cancellation with paused stream subscribers', () {
    test('bus.dispose completes with a paused allEventStream listener',
        () async {
      final bus = EventBus();
      final listener = bus.allEventStream.listen((_) {});
      listener.pause();

      await bus.dispose().timeout(const Duration(seconds: 1));

      listener.resume();
      await listener.cancel();
    });

    test('node disposal completes with a paused raw listen subscriber',
        () async {
      final bus = EventBus();
      final listener = bus.listen(EventKey<int>('paused.node')).listen((_) {});
      listener.pause();

      await bus.dispose().timeout(const Duration(seconds: 1));

      listener.resume();
      await listener.cancel();
    });

    test('subscription.cancel completes with a paused .stream listener',
        () async {
      final bus = EventBus();
      final subscription =
          bus.subscribe(EventKey<int>('paused.view'), onEvent: (_) {});
      final view = subscription.stream.listen((_) {});
      view.pause();

      await subscription.cancel().timeout(const Duration(seconds: 1));

      view.resume();
      await view.cancel();
      await bus.dispose();
    });

    test('monitor.dispose completes with a paused errors listener', () async {
      final bus = EventBus();
      final monitor = EventBusErrorMonitor();
      monitor.add(bus);
      final listener = monitor.errors.listen((_) {});
      listener.pause();

      await monitor.dispose().timeout(const Duration(seconds: 1));

      listener.resume();
      await listener.cancel();
      await bus.dispose();
    });
  });
}
