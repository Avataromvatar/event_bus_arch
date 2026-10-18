import 'dart:async';
import 'dart:typed_data';

import 'package:event_bus_nats/event_bus_nats.dart';

///One publish captured by [FakeNatsConnection].
class FakePublish {
  FakePublish(this.subject, this.data, this.arguments, this.originId);

  final String subject;
  final Uint8List data;
  final Map<String, String>? arguments;
  final String? originId;
}

///An in-memory [NatsConnection] for tests that do not need a server.
///
///It starts connected. Use [setStatus] to simulate a drop, [deliver] to push a
///message to active subscriptions, and [publishes] to inspect what the bus
///tried to publish.
class FakeNatsConnection implements NatsConnection {
  final _statuses = StreamController<NatsConnectionStatus>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final List<_FakeRegistration> _registrations = [];
  final List<FakePublish> publishes = [];

  NatsConnectionStatus _status = NatsConnectionStatus.disconnected;
  int _nextId = 0;
  bool closed = false;

  @override
  bool get isConnected => _status == NatsConnectionStatus.connected;

  @override
  NatsConnectionStatus get status => _status;

  @override
  Stream<NatsConnectionStatus> get statusStream => _statuses.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Future<void> start() async {
    setStatus(NatsConnectionStatus.connected);
  }

  ///Changes the connection state and emits it.
  void setStatus(NatsConnectionStatus status) {
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
  }) {
    if (!isConnected) {
      throw NatsServerUnavailableException(subject);
    }
    publishes.add(FakePublish(subject, data, arguments, originId));
  }

  @override
  NatsSubscription subscribe(
    String subject,
    void Function(NatsMessage message) onMessage,
  ) {
    final registration = _FakeRegistration(_nextId++, subject, onMessage);
    _registrations.add(registration);
    return _FakeSubscription(registration);
  }

  ///Delivers [message] to every active subscription whose subject pattern
  ///matches.
  void deliver(NatsMessage message) {
    for (final registration in List.of(_registrations)) {
      if (!registration.cancelled &&
          _matches(registration.subject, message.subject)) {
        registration.onMessage(message);
      }
    }
  }

  static bool _matches(String pattern, String subject) {
    final patternTokens = pattern.split('.');
    final subjectTokens = subject.split('.');
    var index = 0;
    for (; index < patternTokens.length; index++) {
      final token = patternTokens[index];
      if (token == '>') {
        return index == patternTokens.length - 1 &&
            index < subjectTokens.length;
      }
      if (index >= subjectTokens.length) return false;
      if (token == '*') continue;
      if (token != subjectTokens[index]) return false;
    }
    return index == subjectTokens.length;
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
    setStatus(NatsConnectionStatus.closed);
    await _statuses.close();
    await _errors.close();
  }
}

class _FakeRegistration {
  _FakeRegistration(this.id, this.subject, this.onMessage);

  final int id;
  final String subject;
  final void Function(NatsMessage message) onMessage;
  bool cancelled = false;
}

class _FakeSubscription implements NatsSubscription {
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
