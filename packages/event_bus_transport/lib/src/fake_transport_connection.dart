import 'dart:async';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';

import 'transport_connection.dart';
import 'transport_exception.dart';

///One publish captured by [FakeTransportConnection].
class FakeTransportPublish {
  const FakeTransportPublish(
    this.subject,
    this.data,
    this.arguments,
    this.originId, [
    this.replyTo,
  ]);

  final String subject;
  final Uint8List data;
  final Map<String, String>? arguments;
  final String? originId;
  final String? replyTo;
}

///One request captured by [FakeTransportConnection].
class FakeTransportRequest {
  const FakeTransportRequest(
    this.subject,
    this.data,
    this.arguments,
    this.originId,
    this.replyTo,
  );

  final String subject;
  final Uint8List data;
  final Map<String, String>? arguments;
  final String? originId;

  ///The subject a response must be delivered to with [deliver].
  final String replyTo;
}

///An in-memory [TransportConnection] for tests that do not need a broker.
///
///It starts disconnected. [start] connects it immediately. Use [setStatus] to
///simulate a drop, [deliver] to push a message to active subscriptions, and
///[publishes] to inspect what the bus tried to publish.
class FakeTransportConnection implements TransportConnection {
  final _statuses = StreamController<TransportStatus>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final List<_FakeRegistration> _registrations = [];
  final List<FakeTransportPublish> publishes = [];
  final List<FakeTransportRequest> requests = [];

  TransportStatus _status = TransportStatus.disconnected;
  int _nextId = 0;
  int _nextInbox = 0;
  bool closed = false;

  @override
  bool get isConnected => _status == TransportStatus.connected;

  @override
  TransportStatus get status => _status;

  @override
  Stream<TransportStatus> get statusStream => _statuses.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Future<void> start() async {
    setStatus(TransportStatus.connected);
  }

  ///Changes the connection state and emits it.
  void setStatus(TransportStatus status) {
    _status = status;
    if (!_statuses.isClosed) {
      _statuses.add(status);
    }
  }

  ///Emits an asynchronous transport error.
  void reportError(Object error) {
    if (!_errors.isClosed) {
      _errors.add(error);
    }
  }

  @override
  void publish(
    String subject,
    Uint8List data, {
    Map<String, String>? arguments,
    String? originId,
    String? replyTo,
  }) {
    if (!isConnected) {
      throw TransportServerUnavailableException(subject);
    }
    publishes.add(
      FakeTransportPublish(subject, data, arguments, originId, replyTo),
    );
  }

  @override
  Future<TransportMessage> request(
    String subject,
    Uint8List data, {
    Map<String, String>? arguments,
    String? originId,
    Duration? timeout,
  }) async {
    if (!isConnected) {
      throw TransportServerUnavailableException(subject);
    }

    final replyTo = '_INBOX.${_nextInbox++}';
    requests.add(
      FakeTransportRequest(subject, data, arguments, originId, replyTo),
    );
    final completer = Completer<TransportMessage>();
    final subscription = subscribe(replyTo, (message) {
      if (!completer.isCompleted) completer.complete(message);
    });

    try {
      final response = completer.future;
      return timeout == null ? await response : await response.timeout(timeout);
    } finally {
      await subscription.cancel();
    }
  }

  @override
  TransportSubscription subscribe(
    String subject,
    void Function(TransportMessage message) onMessage,
  ) {
    final registration = _FakeRegistration(_nextId++, subject, onMessage);
    _registrations.add(registration);
    return _FakeSubscription(registration);
  }

  ///Delivers [message] to every active subscription whose subject pattern
  ///matches.
  void deliver(TransportMessage message) {
    final topic = Topic.fromString(message.subject);
    for (final registration in List.of(_registrations)) {
      if (registration.cancelled) continue;
      final pattern = Topic.fromString(registration.subject);
      if (TopicPattern.matches(pattern, topic)) {
        registration.onMessage(message);
      }
    }
  }

  ///The subjects of all subscriptions that have not been cancelled.
  List<String> get subscribedSubjects => _registrations
      .where((registration) => !registration.cancelled)
      .map((registration) => registration.subject)
      .toList();

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    setStatus(TransportStatus.closed);
    await _statuses.close();
    await _errors.close();
  }
}

class _FakeRegistration {
  _FakeRegistration(this.id, this.subject, this.onMessage);

  final int id;
  final String subject;
  final void Function(TransportMessage message) onMessage;
  bool cancelled = false;
}

class _FakeSubscription implements TransportSubscription {
  _FakeSubscription(this._registration);

  final _FakeRegistration _registration;
  bool _cancelled = false;

  @override
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    _registration.cancelled = true;
  }
}
