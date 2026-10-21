import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_nats/dart_nats.dart' as nats;
import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';

import 'nats_connection.dart';
import 'nats_reconnect_policy.dart';

///The real [NatsConnection], backed by `dart_nats`.
///
///The adapter owns one [nats.Client] per connection attempt. The client's own
///retry loop is disabled (`retry: false`): reconnection is driven by
///[ReconnectingTransportConnection] with [ReconnectPolicy], so there is only
///one owner of the lifecycle.
///
///Subscriptions are remembered by the shared base and are created only after
///a client reports `connected`. Calling `sub()` earlier would make the client
///register the subscription itself and resend it on connect, producing a
///duplicate next to ours.
class DartNatsConnection extends ReconnectingTransportConnection {
  DartNatsConnection(
    this.server, {
    NatsConnectionOptions options = const NatsConnectionOptions(),
    this.pingInterval = const Duration(seconds: 5),
    this.connectTimeout = const Duration(seconds: 5),
    super.reconnect = const NatsReconnectPolicy(),
    super.originId,
    nats.ConnectOption? connectOption,
  }) : _options = options,
       _connectOption = connectOption ?? _optionFrom(options);

  final Uri server;
  final Duration pingInterval;
  final Duration connectTimeout;

  final NatsConnectionOptions _options;
  final nats.ConnectOption _connectOption;

  final Map<int, nats.Subscription<dynamic>> _clientSubscriptions = {};
  final Map<int, StreamSubscription<nats.Message<dynamic>>> _listeners = {};

  nats.Client? _client;
  StreamSubscription<nats.Status>? _clientStatusSubscription;

  ///Whether the current client completed a successful handshake. Status
  ///events before that point are part of the connect attempt, which the base
  ///handles itself.
  bool _established = false;

  static nats.ConnectOption _optionFrom(NatsConnectionOptions options) {
    return nats.ConnectOption(
      user: options.user,
      pass: options.password,
      authToken: options.token,
      headers: options.useHeaders,
    );
  }

  @override
  Future<void> connectClient() async {
    final client = nats.Client();
    _client = client;
    _clientStatusSubscription = client.statusStream.listen(_onClientStatus);

    await client.connect(
      server,
      connectOption: _connectOption,
      securityContext: _options.securityContext as dynamic,
      pingInterval: pingInterval,
      timeout: connectTimeout.inSeconds < 1 ? 1 : connectTimeout.inSeconds,
      retry: false,
    );
    _established = client.connected;
  }

  @override
  bool get isClientConnected => _client?.connected ?? false;

  @override
  Future<void> disconnectClient() async {
    _established = false;
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

  @override
  String newReplySubject() {
    final salt = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return '_INBOX.$time$salt';
  }

  @override
  void publishRaw(
    String subject,
    Uint8List data, {
    Map<String, String>? arguments,
    String? originId,
    String? replyTo,
  }) {
    final client = _client;
    if (client == null || !isClientConnected) {
      throw TransportServerUnavailableException(subject);
    }
    final maxPayload = client.info?.maxPayload;
    if (maxPayload != null && data.length > maxPayload) {
      throw TransportPublishException(
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
          replyTo: replyTo,
          buffer: false,
          header: header,
        );
        if (!sent) {
          reportError(
            TransportPublishException('message was not sent', subject: subject),
          );
        }
      } catch (error, stackTrace) {
        reportError(error, stackTrace);
      }
    }());
  }

  @override
  void subscribeRaw(int id, String subject) {
    final client = _client;
    if (client == null || !isClientConnected) return;
    if (_clientSubscriptions.containsKey(id)) return;

    final subscription = client.sub<dynamic>(subject);
    _clientSubscriptions[id] = subscription;
    _listeners[id] = subscription.stream.listen(
      (message) => _onMessage(id, message),
      onError: (Object error, StackTrace stackTrace) =>
          reportError(error, stackTrace),
      cancelOnError: false,
    );
  }

  @override
  Future<void> unsubscribeRaw(int id) async {
    final listener = _listeners.remove(id);
    await listener?.cancel();

    final subscription = _clientSubscriptions.remove(id);
    final client = _client;
    if (subscription != null && client != null) {
      try {
        client.unSub(subscription);
      } catch (error, stackTrace) {
        reportError(error, stackTrace);
      }
    }
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

  void _onClientStatus(nats.Status status) {
    if (!_established) return;
    switch (status) {
      case nats.Status.disconnected:
      case nats.Status.closed:
        handleDrop();
        break;
      default:
        break;
    }
  }

  void _onMessage(int id, nats.Message<dynamic> message) {
    final subject = message.subject;
    if (subject == null) return;

    final headers = _options.useHeaders ? message.header?.headers : null;
    final origin = headers?[NatsHeaderNames.origin];

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
        reportError(error, stackTrace);
        return;
      }
    }

    dispatchMessage(
      id,
      TransportMessage(
        subject: subject,
        data: message.byte,
        arguments: arguments,
        replyTo: message.replyTo,
      ),
      origin: origin,
    );
  }
}
