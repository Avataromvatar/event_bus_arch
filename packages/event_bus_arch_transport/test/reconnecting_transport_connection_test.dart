import 'dart:async';
import 'dart:typed_data';

import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';
import 'package:event_bus_arch_transport/testing.dart';
import 'package:test/test.dart';

///A connection that records what the base asks it to do.
class _Adapter extends ReconnectingTransportConnection {
  _Adapter({super.reconnect, super.originId});

  bool clientUp = false;
  bool failNextConnect = false;
  int connectCalls = 0;
  final List<FakeTransportPublish> publications = [];
  final Map<int, String> subscriptions = {};

  @override
  Future<void> connectClient() async {
    connectCalls++;
    if (failNextConnect) {
      failNextConnect = false;
      throw StateError('cannot connect');
    }
    clientUp = true;
  }

  @override
  Future<void> disconnectClient() async {
    clientUp = false;
    subscriptions.clear();
  }

  @override
  bool get isClientConnected => clientUp;

  int _nextInbox = 0;

  @override
  String newReplySubject() => '_INBOX.${_nextInbox++}';

  @override
  void publishRaw(
    String subject,
    Uint8List data, {
    Map<String, String>? arguments,
    String? originId,
    String? replyTo,
  }) {
    publications.add(
      FakeTransportPublish(subject, data, arguments, originId, replyTo),
    );
  }

  @override
  void subscribeRaw(int id, String subject) {
    subscriptions[id] = subject;
  }

  @override
  Future<void> unsubscribeRaw(int id) async {
    subscriptions.remove(id);
  }

  void receive(int id, String subject, {String? origin}) {
    dispatchMessage(
      id,
      TransportMessage(subject: subject, data: Uint8List(0)),
      origin: origin,
    );
  }
}

void main() {
  test('start connects and replays subscriptions registered before it',
      () async {
    final adapter = _Adapter();
    final subscription = adapter.subscribe('int.sensor', (_) {});

    await adapter.start();

    expect(adapter.isConnected, isTrue);
    expect(adapter.subscriptions.values, ['int.sensor']);

    await subscription.cancel();
    expect(adapter.subscriptions, isEmpty);

    await adapter.close();
  });

  test('a drop schedules a reconnect that replays subscriptions', () async {
    final adapter = _Adapter(
      reconnect: const ReconnectPolicy(initial: Duration(milliseconds: 10)),
    );
    adapter.subscribe('int.sensor', (_) {});
    await adapter.start();

    adapter.handleDrop();
    expect(adapter.isConnected, isFalse);
    expect(adapter.subscriptions, isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(adapter.isConnected, isTrue);
    expect(adapter.subscriptions.values, ['int.sensor']);
    await adapter.close();
  });

  test('a failed connect is reported and retried', () async {
    final adapter = _Adapter(
      reconnect: const ReconnectPolicy(initial: Duration(milliseconds: 10)),
    );
    final errors = <Object>[];
    adapter.errors.listen(errors.add);
    adapter.failNextConnect = true;

    await adapter.start();
    expect(adapter.isConnected, isFalse);
    expect(errors.single, isA<StateError>());

    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(adapter.isConnected, isTrue);
    expect(adapter.connectCalls, 2);
    await adapter.close();
  });

  test('publish throws while the connection is down', () async {
    final adapter = _Adapter();

    expect(
      () => adapter.publish('int.sensor', Uint8List(0)),
      throwsA(isA<TransportServerUnavailableException>()),
    );
  });

  test('a request publishes with a reply subject and returns the response',
      () async {
    final adapter = _Adapter();
    await adapter.start();

    final pending = adapter.request(
      'int.sensor',
      Uint8List.fromList([1]),
      arguments: {'tenant': 'acme'},
      timeout: const Duration(seconds: 1),
    );

    final published = adapter.publications.single;
    expect(published.replyTo, isNotNull);

    // The inbox is a plain subject; deliver directly to its registration.
    final inboxId = adapter.subscriptions.keys.single;
    adapter.dispatchMessage(
      inboxId,
      TransportMessage(subject: published.replyTo!, data: Uint8List(0)),
    );

    final response = await pending;
    expect(response.subject, published.replyTo);
  });

  test('a request times out when no response arrives', () async {
    final adapter = _Adapter();
    await adapter.start();

    expect(
      adapter.request(
        'int.sensor',
        Uint8List(0),
        timeout: const Duration(milliseconds: 10),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('messages published by the same origin are filtered out', () {
    final adapter = _Adapter(originId: 'self');
    final seen = <TransportMessage>[];
    adapter.subscribe('int.sensor', seen.add);
    adapter.clientUp = true;

    adapter.receive(0, 'int.sensor', origin: 'self');
    adapter.receive(0, 'int.sensor', origin: 'other');
    adapter.receive(0, 'int.sensor');

    expect(seen, hasLength(2));
  });

  test('close marks the connection closed and stops reconnect attempts',
      () async {
    final adapter = _Adapter(
      reconnect: const ReconnectPolicy(initial: Duration(milliseconds: 10)),
    );
    await adapter.start();
    final calls = adapter.connectCalls;

    adapter.handleDrop();
    await adapter.close();

    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(adapter.status, TransportStatus.closed);
    expect(adapter.connectCalls, calls);
  });
}
