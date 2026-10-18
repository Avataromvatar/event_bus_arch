import 'dart:async';
import 'dart:typed_data';

import 'reconnect_policy.dart';
import 'transport_connection.dart';
import 'transport_exception.dart';

///The lifecycle shared by every reconnecting transport connection.
///
///It owns the status and error streams, the subscription registry, the
///reconnect timer and the backoff schedule. A concrete adapter implements the
///client-specific hooks ([connectClient], [publishRaw], …) and calls
///[handleDrop] when its client loses an established connection and
///[dispatchMessage] for every message received by a broker subscription.
///
///The adapters must create exactly one subscription per [subscribeRaw] call and
///report messages with the same registration id, so the registry can be
///replayed after a reconnect.
abstract class ReconnectingTransportConnection implements TransportConnection {
  ReconnectingTransportConnection({
    this.reconnect = const ReconnectPolicy(),
    this.originId,
  });

  ///The backoff schedule used after a failed attempt or a dropped connection.
  final ReconnectPolicy reconnect;

  ///Identifies this connection in the origin header. When null, self-echo is
  ///not filtered.
  final String? originId;

  final _statusController = StreamController<TransportStatus>.broadcast();
  final _errorController = StreamController<Object>.broadcast();
  final Map<int, _TransportRegistration> _registrations = {};
  final Set<int> _active = {};

  Timer? _reconnectTimer;
  TransportStatus _status = TransportStatus.disconnected;
  bool _started = false;
  bool _connecting = false;
  bool _disposed = false;
  int _attempt = 0;
  int _nextId = 0;

  // ---------------------------------------------------------------------------
  // Adapter hooks
  // ---------------------------------------------------------------------------

  ///Creates a fresh client and connects it. Throws on failure; the base
  ///reports the error and schedules a reconnect.
  Future<void> connectClient();

  ///Detaches and disposes the current client, if any. Must not throw when no
  ///client is attached. Called on a drop, before a reconnect, and on close.
  Future<void> disconnectClient();

  ///Whether the current client reports a fully established connection.
  bool get isClientConnected;

  ///Publishes through the current client. The base has already checked
  ///[isConnected]; arguments and the origin id are transmitted when the
  ///broker supports metadata. [replyTo] is passed to the broker as the reply
  ///subject.
  void publishRaw(
    String subject,
    Uint8List data, {
    Map<String, String>? arguments,
    String? originId,
    String? replyTo,
  });

  ///Creates a subject a response can be published to. NATS uses `_INBOX.…`;
  ///MQTT uses a response topic. The subject must not collide with the
  ///application's subject space.
  String newReplySubject();

  ///Creates a broker subscription for registration [id]. Messages must be
  ///reported through [dispatchMessage] with the same id.
  void subscribeRaw(int id, String subject);

  ///Cancels the broker subscription for registration [id].
  Future<void> unsubscribeRaw(int id);

  // ---------------------------------------------------------------------------
  // TransportConnection
  // ---------------------------------------------------------------------------

  @override
  bool get isConnected => _status == TransportStatus.connected;

  @override
  TransportStatus get status => _status;

  @override
  Stream<TransportStatus> get statusStream => _statusController.stream;

  @override
  Stream<Object> get errors => _errorController.stream;

  @override
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    await _connectOnce();
  }

  @override
  void publish(
    String subject,
    Uint8List data, {
    Map<String, String>? arguments,
    String? originId,
    String? replyTo,
  }) {
    if (_disposed) {
      throw TransportConnectionException('connection is closed');
    }
    if (!isConnected) {
      throw TransportServerUnavailableException(subject);
    }
    publishRaw(
      subject,
      data,
      arguments: arguments,
      originId: originId,
      replyTo: replyTo,
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
    if (_disposed) {
      throw TransportConnectionException('connection is closed');
    }
    if (!isConnected) {
      throw TransportServerUnavailableException(subject);
    }

    final replySubject = newReplySubject();
    final completer = Completer<TransportMessage>();
    final subscription = subscribe(replySubject, (message) {
      if (!completer.isCompleted) completer.complete(message);
    });

    try {
      publish(
        subject,
        data,
        arguments: arguments,
        originId: originId,
        replyTo: replySubject,
      );
    } catch (_) {
      await subscription.cancel();
      rethrow;
    }

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
    if (_disposed) {
      throw TransportConnectionException('connection is closed');
    }
    final registration = _TransportRegistration(_nextId++, subject, onMessage);
    _registrations[registration.id] = registration;
    if (isConnected) {
      _subscribeClient(registration);
    }
    return _TransportSubscriptionImpl(this, registration.id);
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    for (final registration in _registrations.values) {
      registration.cancelled = true;
    }
    _registrations.clear();
    _active.clear();

    try {
      await disconnectClient();
    } catch (_) {
      // The connection is being torn down; a close error changes nothing.
    }

    _setStatus(TransportStatus.closed);
    await _statusController.close();
    await _errorController.close();
  }

  // ---------------------------------------------------------------------------
  // Adapter support
  // ---------------------------------------------------------------------------

  ///Called by the adapter when an established client connection drops.
  void handleDrop() {
    if (_disposed) return;
    if (_status == TransportStatus.disconnected ||
        _status == TransportStatus.closed) {
      return;
    }
    _setStatus(TransportStatus.disconnected);
    unawaited(_detachAndReconnect());
  }

  ///Delivers a broker message to the registration that owns it, applying the
  ///self-echo filter when [origin] is known.
  void dispatchMessage(
    int registrationId,
    TransportMessage message, {
    String? origin,
  }) {
    if (_disposed) return;
    if (originId != null && origin != null && origin == originId) return;
    final registration = _registrations[registrationId];
    if (registration == null || registration.cancelled) return;
    try {
      registration.onMessage(message);
    } catch (error, stackTrace) {
      reportError(error, stackTrace);
    }
  }

  ///Emits an asynchronous transport error.
  void reportError(Object error, [StackTrace? stackTrace]) {
    if (!_errorController.isClosed) {
      _errorController.add(error);
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _connectOnce() async {
    if (_disposed || _connecting || isConnected) return;
    _connecting = true;
    _setStatus(
      _attempt == 0 ? TransportStatus.connecting : TransportStatus.reconnecting,
    );

    try {
      await connectClient();
      if (_disposed) {
        await _safeDisconnectClient();
        return;
      }
      if (!isClientConnected) {
        await _safeDisconnectClient();
        _active.clear();
        _setStatus(TransportStatus.disconnected);
        _scheduleReconnect();
        return;
      }
      _attempt = 0;
      _setStatus(TransportStatus.connected);
      _resubscribeAll();
    } catch (error, stackTrace) {
      reportError(error, stackTrace);
      await _safeDisconnectClient();
      _active.clear();
      if (!_disposed) {
        _setStatus(TransportStatus.disconnected);
        _scheduleReconnect();
      }
    } finally {
      _connecting = false;
    }
  }

  Future<void> _detachAndReconnect() async {
    await _safeDisconnectClient();
    _active.clear();
    if (!_disposed) _scheduleReconnect();
  }

  Future<void> _safeDisconnectClient() async {
    try {
      await disconnectClient();
    } catch (error, stackTrace) {
      reportError(error, stackTrace);
    }
  }

  void _scheduleReconnect() {
    if (_disposed || isConnected || _reconnectTimer != null) return;
    if (reconnect.exhausted(_attempt)) {
      _setStatus(TransportStatus.closed);
      reportError(TransportConnectionException('reconnect attempts exhausted'));
      return;
    }
    final delay = reconnect.delayFor(_attempt);
    _attempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_connectOnce());
    });
  }

  void _resubscribeAll() {
    for (final registration in _registrations.values) {
      if (!registration.cancelled) {
        _subscribeClient(registration);
      }
    }
  }

  void _subscribeClient(_TransportRegistration registration) {
    if (!isConnected || registration.cancelled) return;
    if (!_active.add(registration.id)) return;
    _subscribeRawSafely(registration);
  }

  void _subscribeRawSafely(_TransportRegistration registration) {
    try {
      subscribeRaw(registration.id, registration.subject);
    } catch (error, stackTrace) {
      reportError(error, stackTrace);
    }
  }

  Future<void> _cancelRegistration(int id) async {
    final registration = _registrations.remove(id);
    if (registration == null) return;
    registration.cancelled = true;
    if (_active.remove(id)) {
      try {
        await unsubscribeRaw(id);
      } catch (error, stackTrace) {
        reportError(error, stackTrace);
      }
    }
  }

  void _setStatus(TransportStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }
}

class _TransportRegistration {
  _TransportRegistration(this.id, this.subject, this.onMessage);

  final int id;
  final String subject;
  final void Function(TransportMessage message) onMessage;
  bool cancelled = false;
}

class _TransportSubscriptionImpl implements TransportSubscription {
  _TransportSubscriptionImpl(this._connection, this._id);

  final ReconnectingTransportConnection _connection;
  final int _id;
  bool _cancelled = false;

  @override
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    await _connection._cancelRegistration(_id);
  }
}
