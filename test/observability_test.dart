import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

Future<void> pump() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

///Reports the correlation id it received; used across the isolate bridge.
void correlationWorker(EventBus bus, Object? initialData) {
  bus.subscribeEvents<String>(
      handler: (dto, lastData) async => dto.correlationId ?? 'none');
}

void main() {
  group('Observability: off by default', () {
    test('a plain bus collects nothing on the hot path', () async {
      final bus = EventBus();
      expect(bus.isObservable, isFalse);

      final sub = bus.subscribeEvents<int>(onEvent: (_) {});
      bus.fire<int>(1);
      await pump();

      final snapshot = bus.metrics.snapshot();
      expect(snapshot.fired, 0);
      expect(snapshot.topics, isEmpty);

      await sub.cancel();
      await bus.dispose();
    });

    test('metrics can be enabled for errors while metric counters stay off',
        () async {
      final bus = EventBus(
          observability: const ObservabilityConfig(enabled: true, metrics: false));
      expect(bus.isObservable, isTrue);

      bus.fire<int>(1);
      final snapshot = bus.metrics.snapshot();
      expect(snapshot.fired, 0);
      expect(snapshot.topics, isEmpty);

      await bus.dispose();
    });
  });

  group('Observability: metrics', () {
    test('fire counts delivered and dropped events per type token', () async {
      final bus = EventBus(
          observability: const ObservabilityConfig(enabled: true));
      final sub = bus.subscribeEvents<int>(onEvent: (_) {});

      expect(bus.fire<int>(1), isTrue);
      expect(bus.fire<int>(2), isTrue);
      expect(bus.fire<String>('nobody'), isFalse);
      await pump();

      final snapshot = bus.metrics.snapshot();
      expect(snapshot.fired, 3);
      expect(snapshot.delivered, 2);
      expect(snapshot.dropped, 1);

      final intTopic =
          snapshot.topics.firstWhere((topic) => topic.key == 'int');
      expect(intTopic.fired, 2);
      expect(intTopic.delivered, 2);
      final stringTopic =
          snapshot.topics.firstWhere((topic) => topic.key == 'String');
      expect(stringTopic.dropped, 1);

      await sub.cancel();
      await bus.dispose();
    });

    test('request outcomes are counted per topic', () async {
      final bus = EventBus(
          observability: const ObservabilityConfig(enabled: true));
      final sub = bus.subscribeEvents<int>(handler: (dto, lastData) async {
        if (dto.data == 0) throw StateError('boom');
        if (dto.data == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        return dto.data;
      });

      expect(await bus.request<int>(2), 2); // completed
      await expectLater(bus.request<int>(0), throwsStateError); // errored
      await expectLater(
        bus.request<int>(1, timeout: const Duration(milliseconds: 10)),
        throwsA(isA<RequestTimeoutException>()),
      );
      await expectLater(
        bus.request<String>('x'),
        throwsA(isA<NoHandlerException>()),
      );

      final preCancelled = CancelToken()..cancel();
      await expectLater(
        bus.request<int>(5, cancelToken: preCancelled),
        throwsA(isA<RequestCanceledException>()),
      );

      final snapshot = bus.metrics.snapshot();
      final intTopic =
          snapshot.topics.firstWhere((topic) => topic.key == 'int');
      expect(intTopic.requestsStarted, 4);
      expect(intTopic.requestsCompleted, 1);
      expect(intTopic.requestsErrored, 1);
      expect(intTopic.requestsTimeout, 1);
      expect(intTopic.requestsCanceled, 1);
      expect(intTopic.requestLatency.count, greaterThan(0));

      final stringTopic =
          snapshot.topics.firstWhere((topic) => topic.key == 'String');
      expect(stringTopic.requestsErrored, 1);

      await sub.cancel();
      await bus.dispose();
    });

    test('subscription state appears in the snapshot', () async {
      final bus = EventBus(
          observability: const ObservabilityConfig(enabled: true));
      final sub = bus.subscribeEvents<int>(handler: (dto, lastData) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return dto.data;
      });

      final pending = bus.request<int>(1);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final subscribed = bus.metrics.snapshot().subscriptions
          .firstWhere((metrics) => metrics.hasHandler);
      expect(subscribed.inFlight, 1);
      expect(subscribed.handlerConcurrency, 1);
      expect(subscribed.requestQueueCapacity, 64);
      expect(subscribed.hasListener, isFalse);

      await pending;
      await sub.cancel();
      await bus.dispose();
    });

    test('queue depth and queue-wait latency are captured', () async {
      final bus = EventBus(
          observability: const ObservabilityConfig(enabled: true));
      final sub = bus.subscribeEvents<int>(handler: (dto, lastData) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return dto.data;
      });

      final first = bus.request<int>(1);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final second = bus.request<int>(2);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final pending = bus.metrics.snapshot().subscriptions
          .firstWhere((metrics) => metrics.hasHandler);
      expect(pending.bufferedRequests, 1);
      expect(pending.maxBufferedRequests, 1);

      await first;
      await second;
      final done = bus.metrics.snapshot().subscriptions
          .firstWhere((metrics) => metrics.hasHandler);
      expect(done.maxBufferedRequests, 1);
      expect(done.queueWaitLatency, isNotNull);
      expect(done.queueWaitLatency!.count, 1);

      await sub.cancel();
      await bus.dispose();
    });

    test('cardinality limit sends new keys to __other__', () async {
      final bus = EventBus(
          observability:
              const ObservabilityConfig(enabled: true, cardinalityLimit: 1));

      bus.fire<int>(1);
      bus.fire<String>('x');
      bus.fire<double>(1.0);

      final snapshot = bus.metrics.snapshot();
      expect(snapshot.droppedMetricSeries, 2);
      expect(
          snapshot.topics.map((topic) => topic.key), containsAll(['int', '__other__']));
      final other =
          snapshot.topics.firstWhere((topic) => topic.key == '__other__');
      expect(other.fired, 2);

      await bus.dispose();
    });

    test('sampleRate 0 keeps counters and records no latency samples',
        () async {
      final bus = EventBus(
          observability:
              const ObservabilityConfig(enabled: true, sampleRate: 0));

      bus.fire<int>(1);
      final topic = bus.metrics.snapshot().topics.single;
      expect(topic.fired, 1);
      expect(topic.dispatchLatency.count, 0);

      await bus.dispose();
    });

    test('changes emits a coalesced snapshot', () async {
      final bus = EventBus(
          observability: const ObservabilityConfig(enabled: true));
      final first = bus.metrics.changes.first.timeout(const Duration(seconds: 2));

      bus.fire<int>(1);
      bus.fire<int>(2);

      final snapshot = await first;
      expect(snapshot.fired, 2);

      await bus.dispose();
    });

    test('capturePayloads attaches the event to a listener error', () async {
      final bus = EventBus(
          observability: const ObservabilityConfig(
              enabled: true, capturePayloads: true));
      final errorFuture = bus.errors.first;
      final sub = bus.subscribeEvents<int>(
          paths: ['boom'], onEvent: (_) => throw StateError('listener'));

      bus.fire<int>(7, paths: ['boom']);
      final error = await errorFuture.timeout(const Duration(seconds: 1));

      expect(error.kind, EventBusErrorKind.listener);
      expect(error.event, isNotNull);
      expect(error.event!.data, 7);

      await sub.cancel();
      await bus.dispose();
    });

    test('payloads are redacted by default', () async {
      final bus = EventBus(
          observability: const ObservabilityConfig(enabled: true));
      final errorFuture = bus.errors.first;
      final sub = bus.subscribeEvents<int>(
          paths: ['boom'], onEvent: (_) => throw StateError('listener'));

      bus.fire<int>(7, paths: ['boom']);
      final error = await errorFuture.timeout(const Duration(seconds: 1));

      expect(error.event, isNull);
      await sub.cancel();
      await bus.dispose();
    });
  });

  group('Correlation id', () {
    test('reaches handlers, allEventStream and error envelopes', () async {
      final bus = EventBus(
          observability: const ObservabilityConfig(enabled: true));
      final sub = bus.subscribeEvents<int>(handler: (dto, lastData) async {
        if (dto.data == 0) throw StateError('boom');
        return dto.correlationId;
      });

      expect(await bus.request<int>(1, correlationId: 'request-1'),
          'request-1');

      final errorFuture = bus.errors.first;
      await expectLater(
        bus.request<int>(0, correlationId: 'request-2'),
        throwsStateError,
      );
      final error = await errorFuture.timeout(const Duration(seconds: 1));
      expect(error.correlationId, 'request-2');

      final seen = <String?>[];
      final all = bus.allEventStream.listen((event) {
        seen.add(event.$1.correlationId);
      });
      bus.fire<int>(2, correlationId: 'fire-1');
      await pump();
      expect(seen, contains('fire-1'));

      await all.cancel();
      await sub.cancel();
      await bus.dispose();
    });

    test('crosses the isolate bridge and counts on the isolate bus', () async {
      final iso = EventBusIsolate(
        onInit: correlationWorker,
        observability: const ObservabilityConfig(enabled: true),
      );
      await iso.waitInit;

      expect(await iso.request<String>('x', correlationId: 'iso-1'), 'iso-1');

      final snapshot = iso.metrics.snapshot();
      final topic =
          snapshot.topics.firstWhere((metrics) => metrics.key == 'String');
      expect(topic.requestsStarted, 1);
      expect(topic.requestsCompleted, 1);

      await iso.dispose();
    });
  });
}
