// ignore_for_file: deprecated_member_use
import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

// --- functions that run IN A WORKER ISOLATE (top-level only) ---

///Subscribes to `state`, remembers whether the subscription was completed,
///and reports it through `was_done`. Also answers requests, so the topic has a
///handler on the worker side.
void doneReporterWorker(EventBus bus, Object? initialData) {
  var done = false;
  bus
      .listen(EventKey<int>('int.state'))
      .listen((_) {}, onDone: () => done = true);
  bus.subscribe(EventKey<bool>('bool.was_done'),
      handler: (dto, lastData) async => done);
}

///Removes `state` from inside the worker and reports through the request.
void workerDeleteWorker(EventBus bus, Object? initialData) {
  bus.subscribe(EventKey<String>('String.delete_state'),
      handler: (dto, lastData) async {
    bus.remove(EventKey<int>('int.state'));
    return 'deleted';
  });
}

void silentWorker(EventBus bus, Object? initialData) {}

void main() {
  group('removeTopic: model bus', () {
    test('forgets the value and removes the node', () async {
      final bus = EventBus(isModelBus: true);
      bus.fire(EventKey<int>('int.state'), 1);
      expect(bus.currentData(EventKey<int>('int.state')), 1);

      expect(bus.remove(EventKey<int>('int.state')), isTrue);

      expect(bus.currentData(EventKey<int>('int.state')), isNull);
      expect(bus.haveListener(EventKey<int>('int.state')), isFalse);
      await bus.dispose();
    });

    test('returns false for a topic without a node', () async {
      final bus = EventBus(isModelBus: true);

      expect(bus.remove(EventKey<int>('int.missing')), isFalse);
      await bus.dispose();
    });

    test('a later fire creates the node and stores the value again', () async {
      final bus = EventBus(isModelBus: true);
      bus.fire(EventKey<int>('int.state'), 1);
      bus.remove(EventKey<int>('int.state'));

      expect(bus.fire(EventKey<int>('int.state'), 2), isTrue);
      expect(bus.currentData(EventKey<int>('int.state')), 2);
      await bus.dispose();
    });

    test('active listeners receive done', () async {
      final bus = EventBus(isModelBus: true);
      var done = false;
      bus
          .listen(EventKey<int>('int.state'))
          .listen((_) {}, onDone: () => done = true);

      bus.remove(EventKey<int>('int.state'));
      await Future<void>.delayed(Duration.zero);

      expect(done, isTrue);
      await bus.dispose();
    });

    test('a pattern topic is removed with its listeners', () async {
      final bus = EventBus(isModelBus: true);
      final seen = <int>[];
      bus.listen(EventPatternKey<int>('int.a.*')).listen(seen.add);
      bus.fire(EventKey<int>('int.a.b'), 1);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [1]);

      expect(bus.remove(EventPatternKey<int>('int.a.*')), isTrue);
      expect(bus.haveListener(EventPatternKey<int>('int.a.*')), isFalse);

      bus.fire(EventKey<int>('int.a.b'), 2);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [1]);
      await bus.dispose();
    });

    test('removeTopic also cancels the handler subscription', () async {
      final bus = EventBus(isModelBus: true);
      final previous = <String?>[];
      bus.subscribe(EventKey<String>('String.state'),
          handler: (dto, lastData) async {
        previous.add(lastData);
        return dto.data;
      });

      await bus.request(EventKey<String>('String.state'), 'a');
      expect(bus.haveHandler(EventKey<String>('String.state')), isTrue);

      expect(bus.remove(EventKey<String>('String.state')), isTrue);
      expect(bus.currentData(EventKey<String>('String.state')), isNull);
      expect(bus.haveHandler(EventKey<String>('String.state')), isFalse);

      await expectLater(
        bus.request(EventKey<String>('String.state'), 'b'),
        throwsA(isA<NoHandlerException>()),
      );
      expect(previous, [null]);
      await bus.dispose();
    });
  });

  group('removeTopic: common bus', () {
    test('removes an existing node and returns true once', () async {
      final bus = EventBus();
      bus.listen(EventKey<int>('int.state')).listen((_) {});

      expect(bus.remove(EventKey<int>('int.state')), isTrue);
      expect(bus.remove(EventKey<int>('int.state')), isFalse);
      await bus.dispose();
    });

    test('a late cancel of a removed node does not remove the new node',
        () async {
      final bus = EventBus();
      bus.listen(EventKey<int>('int.state')).listen((_) {});

      expect(bus.remove(EventKey<int>('int.state')), isTrue);

      final received = <int>[];
      final second =
          bus.listen(EventKey<int>('int.state')).listen(received.add);

      // Let the done/doOnCancel callbacks of the removed node run: with a
      // key-only removal they would delete the node created just above.
      await Future<void>.delayed(Duration.zero);

      expect(bus.fire(EventKey<int>('int.state'), 1), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(received, [1]);

      await second.cancel();
      await bus.dispose();
    });

    test('throws StateError after dispose', () async {
      final bus = EventBus();
      await bus.dispose();

      expect(() => bus.remove(EventKey<int>('int.state')), throwsStateError);
    });
  });

  group('removeTopic: EventBusIsolate', () {
    test('main-side delete reaches the worker', () async {
      final iso = EventBusIsolate(onInit: doneReporterWorker, isModelBus: true);
      await iso.waitInit;
      final sub = iso.listen(EventKey<int>('int.state')).listen((_) {});
      expect(iso.haveListener(EventKey<int>('int.state')), isTrue);

      expect(iso.remove(EventKey<int>('int.state')), isTrue);
      expect(iso.haveListener(EventKey<int>('int.state')), isFalse);

      // The delete is in the port before this request: the worker has already
      // completed its subscription.
      expect(await iso.request(EventKey<bool>('bool.was_done'), true), isTrue);

      await sub.cancel();
      await iso.dispose();
    });

    test('a worker-side delete reaches the main isolate', () async {
      final iso = EventBusIsolate(onInit: workerDeleteWorker, isModelBus: true);
      await iso.waitInit;
      final sub = iso.listen(EventKey<int>('int.state')).listen((_) {});
      expect(iso.haveListener(EventKey<int>('int.state')), isTrue);

      expect(await iso.request(EventKey<String>('String.delete_state'), 'go'),
          'deleted');

      expect(iso.haveListener(EventKey<int>('int.state')), isFalse);
      await sub.cancel();
      await iso.dispose();
    });

    test('throws before waitInit and after dispose', () async {
      final iso = EventBusIsolate(onInit: silentWorker, isModelBus: true);
      expect(() => iso.remove(EventKey<int>('int.state')), throwsStateError);

      await iso.waitInit;
      await iso.dispose();
      expect(() => iso.remove(EventKey<int>('int.state')), throwsStateError);
    });
  });
}
