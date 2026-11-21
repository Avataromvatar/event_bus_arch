import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

// --- functions that run IN A WORKER ISOLATE (top-level only) ---

///Subscribes to `state`, remembers whether the subscription was completed,
///and reports it through `was_done`. Also answers requests, so the topic has a
///handler on the worker side.
void doneReporterWorker(EventBus bus, Object? initialData) {
  var done = false;
  bus.subscribe<int>(
      paths: ['state'], onData: (_) {}, onDone: () => done = true);
  bus.handlers.setHandler<bool>(
      paths: ['was_done'], handler: (dto, lastData) async => done);
}

///Removes `state` from inside the worker and reports through the request.
void workerDeleteWorker(EventBus bus, Object? initialData) {
  bus.handlers.setHandler<String>(
      paths: ['delete_state'],
      handler: (dto, lastData) async {
        bus.removeTopic<int>(paths: ['state']);
        return 'deleted';
      });
}

void silentWorker(EventBus bus, Object? initialData) {}

void main() {
  group('removeTopic: model bus', () {
    test('forgets the value and removes the node', () async {
      final bus = EventBus(isModelBus: true);
      bus.fire<int>(1, paths: ['state']);
      expect(bus.currentData<int>(paths: ['state']), 1);

      expect(bus.removeTopic<int>(paths: ['state']), isTrue);

      expect(bus.currentData<int>(paths: ['state']), isNull);
      expect(bus.haveListener<int>(paths: ['state']), isFalse);
      await bus.dispose();
    });

    test('returns false for a topic without a node', () async {
      final bus = EventBus(isModelBus: true);

      expect(bus.removeTopic<int>(paths: ['missing']), isFalse);
      await bus.dispose();
    });

    test('a later fire creates the node and stores the value again', () async {
      final bus = EventBus(isModelBus: true);
      bus.fire<int>(1, paths: ['state']);
      bus.removeTopic<int>(paths: ['state']);

      expect(bus.fire<int>(2, paths: ['state']), isTrue);
      expect(bus.currentData<int>(paths: ['state']), 2);
      await bus.dispose();
    });

    test('active listeners receive done', () async {
      final bus = EventBus(isModelBus: true);
      var done = false;
      bus.subscribe<int>(
          paths: ['state'], onData: (_) {}, onDone: () => done = true);

      bus.removeTopic<int>(paths: ['state']);
      await Future<void>.delayed(Duration.zero);

      expect(done, isTrue);
      await bus.dispose();
    });

    test('a pattern topic is removed with its listeners', () async {
      final bus = EventBus(isModelBus: true);
      final seen = <int>[];
      bus.subscribe<int>(paths: ['a', '*'], onData: seen.add);
      bus.fire<int>(1, paths: ['a', 'b']);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [1]);

      expect(bus.removeTopic<int>(paths: ['a', '*']), isTrue);
      expect(bus.haveListener<int>(paths: ['a', '*']), isFalse);

      bus.fire<int>(2, paths: ['a', 'b']);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [1]);
      await bus.dispose();
    });

    test('the handler stays and the next request rebuilds the node', () async {
      final bus = EventBus(isModelBus: true);
      final previous = <String?>[];
      bus.handlers.setHandler<String>(
          paths: ['state'],
          handler: (dto, lastData) async {
            previous.add(lastData);
            return dto.data;
          });

      await bus.request<String>('a', paths: ['state']);
      expect(bus.removeTopic<String>(paths: ['state']), isTrue);
      expect(bus.currentData<String>(paths: ['state']), isNull);

      await bus.request<String>('b', paths: ['state']);
      expect(bus.haveHandler<String>(paths: ['state']), isTrue);
      expect(bus.currentData<String>(paths: ['state']), 'b');

      await bus.request<String>('c', paths: ['state']);
      expect(previous, [null, null, 'b']);
      await bus.dispose();
    });
  });

  group('removeTopic: common bus', () {
    test('removes an existing node and returns true once', () async {
      final bus = EventBus();
      bus.subscribe<int>(paths: ['state'], onData: (_) {});

      expect(bus.removeTopic<int>(paths: ['state']), isTrue);
      expect(bus.removeTopic<int>(paths: ['state']), isFalse);
      await bus.dispose();
    });

    test('a late cancel of a removed node does not remove the new node',
        () async {
      final bus = EventBus();
      bus.subscribe<int>(paths: ['state'], onData: (_) {});

      expect(bus.removeTopic<int>(paths: ['state']), isTrue);

      final received = <int>[];
      final second = bus.subscribe<int>(paths: ['state'], onData: received.add);

      // Let the done/doOnCancel callbacks of the removed node run: with a
      // key-only removal they would delete the node created just above.
      await Future<void>.delayed(Duration.zero);

      expect(bus.fire<int>(1, paths: ['state']), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(received, [1]);

      await second.cancel();
      await bus.dispose();
    });

    test('throws StateError after dispose', () async {
      final bus = EventBus();
      await bus.dispose();

      expect(() => bus.removeTopic<int>(paths: ['state']), throwsStateError);
    });
  });

  group('removeTopic: EventBusIsolate', () {
    test('main-side delete reaches the worker', () async {
      final iso = EventBusIsolate(onInit: doneReporterWorker, isModelBus: true);
      await iso.waitInit;
      final sub = iso.subscribe<int>(paths: ['state'], onData: (_) {});
      expect(iso.haveListener<int>(paths: ['state']), isTrue);

      expect(iso.removeTopic<int>(paths: ['state']), isTrue);
      expect(iso.haveListener<int>(paths: ['state']), isFalse);

      // The delete is in the port before this request: the worker has already
      // completed its subscription.
      expect(await iso.request<bool>(true, paths: ['was_done']), isTrue);

      await sub.cancel();
      await iso.dispose();
    });

    test('a worker-side delete reaches the main isolate', () async {
      final iso = EventBusIsolate(onInit: workerDeleteWorker, isModelBus: true);
      await iso.waitInit;
      final sub = iso.subscribe<int>(paths: ['state'], onData: (_) {});
      expect(iso.haveListener<int>(paths: ['state']), isTrue);

      expect(
          await iso.request<String>('go', paths: ['delete_state']), 'deleted');

      expect(iso.haveListener<int>(paths: ['state']), isFalse);
      await sub.cancel();
      await iso.dispose();
    });

    test('throws before waitInit and after dispose', () async {
      final iso = EventBusIsolate(onInit: silentWorker, isModelBus: true);
      expect(() => iso.removeTopic<int>(paths: ['state']), throwsStateError);

      await iso.waitInit;
      await iso.dispose();
      expect(() => iso.removeTopic<int>(paths: ['state']), throwsStateError);
    });
  });
}
