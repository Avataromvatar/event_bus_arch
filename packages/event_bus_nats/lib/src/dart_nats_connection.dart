import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_nats/dart_nats.dart' as nats;

import 'nats_connection.dart';
import 'nats_exception.dart';
import 'nats_reconnect_policy.dart';

///The real [NatsConnection], backed by `dart_nats`.
///
///The adapter owns one [nats.Client] per connection attempt. The client's own
///retry loop is disabled (`retry: false`): reconnection is driven here with
///[NatsReconnectPolicy], so there is only one owner of the lifecycle.
///
///Subscriptions are remembered in a local registry and are created only after
///a client reports `connected`. Calling `sub()` earlier would make the client
///register the subscription itself and resend it on connect, producing a
///duplicate next to ours.
class DartNatsConnection implements NatsConnection {
  DartNatsConnection(
    this.server, {
    NatsConnectionOptions options = const NatsConnectionOptions(),
    this.pingInterval = const Duration(seconds: 5),
    this.connectTimeout = const Duration(seconds: 5),
    this.reconnect = const NatsReconnectPolicy(),
    this.originId,
    nats.ConnectOption? connectOption,
  }) : _options = options,
       _connectOption = connectOption ?? _optionFrom(options);

  final Uri server;
  final Duration pingInterval;
  final Duration connectTimeout;
  final NatsReconnectPolicy reconnect;

  ///Identifies this connection in the origin header. When null, self-echo is
  ///not filtered.
  final String? originId;

  final NatsConnectionOptions _options;
  final nats.ConnectOption _connectOption;

  final _statusController = StreamController<NatsConnectionStatus>.broadcast();
  final _errorController = StreamController<Object>.broadcast();

  final Map<int, _Registration> _registrations = {};
  final Map<int, nats.Subscription<dynamic>> _clientSubscriptions = {};
  final Map<int, StreamSubscription<nats.Message<dynamic>>> _listeners = {};

  nats.Client? _client;
  StreamSubscription<nats.Status>? _clientStatusSubscription;
  Timer? _reconnectTimer;

  NatsConnectionStatus _status = NatsConnectionStatus.disconnected;
  bool _started = false;
  bool _disposed = false;
  bool _connecting = false;
  int _attempt = 0;
  int _nextId = 0;

  static nats.ConnectOption _optionFrom(NatsConnectionOptions options) {
    return nats.ConnectOption(
      user: options.user,
      pass: options.password,
      authToken: options.token,
      headers: options.useHeaders,
    );
  }

  @override
  bool get isConnected => _status == NatsConnectionStatus.connected;

  @override
  NatsConnectionStatus get status => _status;

  @override
  Stream<NatsConnectionStatus> get statusStream => _statusController.stream;

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
  }) {
    if (_disposed) {
      throw NatsConnectionException('connection is closed');
    }
    final client = _client;
    if (!isConnected || client == null) {
      throw NatsServerUnavailableException(subject);
    }
    final maxPayload = client.info?.maxPayload;
    if (maxPayload != null && data.length > maxPayload) {
      throw NatsPublishException(
        'payload is ${data.length} bytes, server max is $maxPayload',
        subject: subject,
      );
    }
    final header = _header(arguments, originId);
    unawaited(() async {
      try {
        final sent = await client.pub(
          subject,
          data,
          buffer: false,
          header: header,
        );
        if (!sent) {
          _reportError(
            NatsPublishException('message was not sent', subject: subject),
          );
        }
      } catch (error, stackTrace) {
        _reportError(error, stackTrace);
      }
    }());
  }

  @override
  NatsSubscription subscribe(
    String subject,
    void Function(NatsMessage message) onMessage,
  ) {
    if (_disposed) {
      throw NatsConnectionException('connection is closed');
    }
    final registration = _Registration(_nextId++, subject, onMessage);
    _registrations[registration.id] = registration;
    if (isConnected) {
      _subscribeClient(registration);
    }
    return _NatsSubscriptionImpl(this, registration.id);
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
    for (final listener in _listeners.values) {
      await listener.cancel();
    }
    _listeners.clear();
    _clientSubscriptions.clear();
    await _clientStatusSubscription?.cancel();
    _clientStatusSubscription = null;

    final client = _client;
    _client = null;
    if (client != null) {
      try {
        await client.forceClose();
      } catch (_) {
        // The connection is being torn down; a close error changes nothing.
      }
    }

    _setStatus(NatsConnectionStatus.closed);
    await _statusController.close();
    await _errorController.close();
  }

  nats.Header? _header(Map<String, String>? arguments, String? originId) {
    if (!_options.useHeaders) return null;
    final hasOrigin = originId != null;
    final hasArguments = arguments != null && arguments.isNotEmpty;
    if (!hasOrigin && !hasArguments) return null;

    final header = nats.Header();
    if (hasOrigin) {
      header.add(NatsHeaderNames.origin, originId);
    }
    if (hasArguments) {
      header.add(NatsHeaderNames.arguments, jsonEncode(arguments));
    }
    return header;
  }

  Future<void> _connectOnce() async {
    if (_disposed || _connecting || isConnected) return;
    _connecting = true;
    _setStatus(
      _attempt == 0
          ? NatsConnectionStatus.connecting
          : NatsConnectionStatus.reconnecting,
    );

    final client = nats.Client();
    _client = client;
    _clientStatusSubscription = client.statusStream.listen(_onClientStatus);

    try {
      await client.connect(
        server,
        connectOption: _connectOption,
        securityContext: _options.securityContext as dynamic,
        pingInterval: pingInterval,
        timeout: connectTimeout.inSeconds < 1 ? 1 : connectTimeout.inSeconds,
        retry: false,
      );
      if (_disposed || !client.connected) {
        await _detachClient();
        if (!_disposed) {
          _setStatus(NatsConnectionStatus.disconnected);
          _scheduleReconnect();
        }
        return;
      }
      _attempt = 0;
      _setStatus(NatsConnectionStatus.connected);
      _resubscribeAll();
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
      await _detachClient();
      if (!_disposed) {
        _setStatus(NatsConnectionStatus.disconnected);
        _scheduleReconnect();
      }
    } finally {
      _connecting = false;
    }
  }

  void _onClientStatus(nats.Status status) {
    if (_disposed) return;
    switch (status) {
      case nats.Status.reconnecting:
        _setStatus(NatsConnectionStatus.reconnecting);
        break;
      case nats.Status.disconnected:
      case nats.Status.closed:
        // An established connection dropped. A disconnect during the initial
        // handshake is handled by _connectOnce's catch.
        if (isConnected) _handleDrop();
        break;
      default:
        break;
    }
  }

  void _handleDrop() {
    _setStatus(NatsConnectionStatus.disconnected);
    unawaited(
      _detachClient().then((_) {
        if (!_disposed) _scheduleReconnect();
      }),
    );
  }

  Future<void> _detachClient() async {
    await _clientStatusSubscription?.cancel();
    _clientStatusSubscription = null;

    for (final listener in _listeners.values) {
      await listener.cancel();
    }
    _listeners.clear();
    _clientSubscriptions.clear();

    final client = _client;
    _client = null;
    if (client != null) {
      try {
        await client.forceClose();
      } catch (_) {
        // The old client is already unusable; its close error is irrelevant.
      }
    }
  }

  void _scheduleReconnect() {
    if (_disposed || isConnected || _reconnectTimer != null) return;
    if (reconnect.exhausted(_attempt)) {
      _setStatus(NatsConnectionStatus.closed);
      _reportError(NatsConnectionException('reconnect attempts exhausted'));
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

  void _subscribeClient(_Registration registration) {
    final client = _client;
    if (client == null || !isConnected || registration.cancelled) return;
    if (_clientSubscriptions.containsKey(registration.id)) return;

    final subscription = client.sub<dynamic>(registration.subject);
    _clientSubscriptions[registration.id] = subscription;
    _listeners[registration.id] = subscription.stream.listen(
      (message) => _onMessage(registration, message),
      onError: (Object error, StackTrace stackTrace) =>
          _reportError(error, stackTrace),
      cancelOnError: false,
    );
  }

  Future<void> _cancelRegistration(int id) async {
    final registration = _registrations.remove(id);
    if (registration == null) return;
    registration.cancelled = true;

    final listener = _listeners.remove(id);
    await listener?.cancel();

    final subscription = _clientSubscriptions.remove(id);
    final client = _client;
    if (subscription != null && client != null) {
      try {
        client.unSub(subscription);
      } catch (error, stackTrace) {
        _reportError(error, stackTrace);
      }
    }
  }

  void _onMessage(_Registration registration, nats.Message<dynamic> message) {
    if (registration.cancelled || _disposed) return;

    final headers = message.header?.headers;
    final origin = headers?[NatsHeaderNames.origin];
    if (_options.useHeaders && originId != null && origin == originId) {
      return;
    }

    Map<String, String>? arguments;
    final rawArguments = headers?[NatsHeaderNames.arguments];
    if (rawArguments != null) {
      try {
        final decoded = jsonDecode(rawArguments);
        if (decoded is! Map) {
          throw const FormatException('arguments header is not a map');
        }
        arguments = decoded.map<String, String>(
          (key, value) => MapEntry(key.toString(), value.toString()),
        );
      } catch (error, stackTrace) {
        _reportError(error, stackTrace);
        return;
      }
    }

    final subject = message.subject;
    if (subject == null) return;
    try {
      registration.onMessage(
        NatsMessage(
          subject: subject,
          data: message.byte,
          arguments: arguments,
          replyTo: message.replyTo,
        ),
      );
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
    }
  }

  void _setStatus(NatsConnectionStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  void _reportError(Object error, [StackTrace? stackTrace]) {
    if (!_errorController.isClosed) {
      _errorController.add(error);
    }
  }
}

class _Registration {
  _Registration(this.id, this.subject, this.onMessage);

  final int id;
  final String subject;
  final void Function(NatsMessage message) onMessage;
  bool cancelled = false;
}

class _NatsSubscriptionImpl implements NatsSubscription {
  _NatsSubscriptionImpl(this._connection, this._id);

  final DartNatsConnection _connection;
  final int _id;
  bool _cancelled = false;

  @override
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    await _connection._cancelRegistration(_id);
  }
}
