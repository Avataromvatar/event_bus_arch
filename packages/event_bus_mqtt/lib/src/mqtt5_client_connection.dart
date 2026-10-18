import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:event_bus_transport/event_bus_transport.dart';
import 'package:mqtt5_client/mqtt5_client.dart' as mqtt;
import 'package:mqtt5_client/mqtt5_server_client.dart' as mqtt_server;
import 'package:typed_data/typed_data.dart' as typed;

import 'mqtt_connection.dart';
import 'mqtt_exception.dart';
import 'mqtt_reconnect_policy.dart';

///The real [MqttConnection], backed by `mqtt5_client`.
///
///The adapter owns one client per connection attempt. The client's own
///auto-reconnect is disabled: reconnection is driven by
///[ReconnectingTransportConnection] with [ReconnectPolicy], so there is only
///one owner of the lifecycle.
///
///Subscriptions are remembered by the shared base and are created only after a
///client reports `connected`. Self-echo is suppressed twice: the subscription
///sets MQTT 5 `noLocal`, and the origin user property is checked by the base.
class MqttServerConnection extends ReconnectingTransportConnection {
  MqttServerConnection(
    this.broker, {
    this.options = const MqttConnectionOptions(),
    super.reconnect = const MqttReconnectPolicy(),
    super.originId,
  });

  ///`mqtt://`, `mqtts://`, `ws://` or `wss://` address of the broker.
  final Uri broker;

  final MqttConnectionOptions options;

  final Map<int, String> _subscriptions = {};

  mqtt_server.MqttServerClient? _client;
  StreamSubscription<List<mqtt.MqttReceivedMessage<mqtt.MqttMessage>>>?
  _updatesSubscription;

  ///Whether the current client completed a successful handshake.
  bool _established = false;

  bool get _secure => broker.scheme == 'mqtts' || broker.scheme == 'wss';
  bool get _webSocket => broker.scheme == 'ws' || broker.scheme == 'wss';

  int get _defaultPort => switch (broker.scheme) {
    'mqtt' => 1883,
    'mqtts' => 8883,
    'ws' => 80,
    'wss' => 443,
    _ => 1883,
  };

  mqtt.MqttQos get _qos => switch (options.qos) {
    MqttQosLevel.atMostOnce => mqtt.MqttQos.atMostOnce,
    MqttQosLevel.atLeastOnce => mqtt.MqttQos.atLeastOnce,
    MqttQosLevel.exactlyOnce => mqtt.MqttQos.exactlyOnce,
  };

  String get _clientId =>
      options.clientId ?? 'event_bus_${originId ?? _randomSuffix()}';

  @override
  Future<void> connectClient() async {
    final client = mqtt_server.MqttServerClient.withPort(
      broker.host,
      _clientId,
      broker.hasPort ? broker.port : _defaultPort,
      maxConnectionAttempts: 1,
    );
    _client = client;
    client.secure = _secure;
    client.useWebSocket = _webSocket;
    client.autoReconnect = false;
    client.resubscribeOnAutoReconnect = false;
    client.keepAlivePeriod = options.keepAlive.inSeconds;
    client.socketTimeout = options.connectTimeout.inMilliseconds;
    client.logging(on: false);
    client.onDisconnected = _onDisconnected;

    final connectMessage = mqtt.MqttConnectMessage()
        .withClientIdentifier(_clientId)
        .keepAliveFor(options.keepAlive.inSeconds)
        .authenticateAs(options.username, options.password);
    if (options.cleanStart) {
      connectMessage.startClean();
    } else {
      connectMessage.startSession(
        sessionExpiryInterval: options.sessionExpiryInterval,
      );
    }
    client.connectionMessage = connectMessage;

    final status = await client.connect();
    _established =
        status?.state == mqtt.MqttConnectionState.connected &&
        client.connectionStatus?.state == mqtt.MqttConnectionState.connected;
    if (_established) {
      _updatesSubscription = client.updates?.listen(
        _onUpdates,
        onError: (Object error, StackTrace stackTrace) =>
            reportError(error, stackTrace),
      );
    }
  }

  @override
  bool get isClientConnected =>
      _client?.connectionStatus?.state == mqtt.MqttConnectionState.connected;

  @override
  Future<void> disconnectClient() async {
    _established = false;
    await _updatesSubscription?.cancel();
    _updatesSubscription = null;
    _subscriptions.clear();

    final client = _client;
    _client = null;
    if (client != null) {
      // The solicited disconnect must not start the reconnect cycle.
      client.onDisconnected = null;
      try {
        client.disconnect();
      } catch (_) {
        // The client is being torn down; its close error is irrelevant.
      }
    }
  }

  @override
  String newReplySubject() => '_INBOX/${_randomSuffix()}';

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
      throw MqttServerUnavailableException(subject);
    }

    final message = mqtt.MqttPublishMessage()
      ..toTopic(subject)
      ..withQos(_qos)
      ..publishData(typed.Uint8Buffer()..addAll(data));
    if (replyTo != null) {
      message.withResponseTopic(replyTo);
    }

    final properties = <mqtt.MqttUserProperty>[];
    if (options.useUserProperties) {
      if (originId != null) {
        properties.add(_userProperty(TransportHeaderNames.origin, originId));
      }
      if (arguments != null && arguments.isNotEmpty) {
        properties.add(
          _userProperty(TransportHeaderNames.arguments, jsonEncode(arguments)),
        );
      }
    }
    if (properties.isNotEmpty) {
      message.withUserProperties(properties);
    }

    try {
      client.publishUserMessage(message);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        MqttPublishException(
          'publish to "$subject" failed: $error',
          subject: subject,
        ),
        stackTrace,
      );
    }
  }

  @override
  void subscribeRaw(int id, String subject) {
    _subscriptions[id] = subject;
    final client = _client;
    if (client == null || !isClientConnected) return;

    final option = mqtt.MqttSubscriptionOption()
      ..maximumQos = _qos
      ..noLocal = options.noLocal;
    client.subscribeWithSubscription(
      mqtt.MqttSubscription(mqtt.MqttSubscriptionTopic(subject), option),
    );
  }

  @override
  Future<void> unsubscribeRaw(int id) async {
    final subject = _subscriptions.remove(id);
    final client = _client;
    if (subject == null || client == null || !isClientConnected) return;
    try {
      client.unsubscribeStringTopic(subject);
    } catch (error, stackTrace) {
      reportError(error, stackTrace);
    }
  }

  void _onDisconnected() {
    if (!_established) return;
    handleDrop();
  }

  void _onUpdates(List<mqtt.MqttReceivedMessage<mqtt.MqttMessage>> updates) {
    for (final update in updates) {
      final message = update.payload;
      if (message is! mqtt.MqttPublishMessage) continue;

      final header = message.variableHeader;
      final subject = header?.topicName ?? update.topic;
      if (subject == null || subject.isEmpty) continue;

      final payload = message.payload.message;
      final data = payload == null ? Uint8List(0) : Uint8List.fromList(payload);

      final responseTopic = header?.responseTopic;
      final replyTo = responseTopic == null || responseTopic.isEmpty
          ? null
          : responseTopic;

      final properties = header?.userProperty ?? const [];
      final origin = _userPropertyValue(
        properties,
        TransportHeaderNames.origin,
      );

      Map<String, String>? arguments;
      final rawArguments = _userPropertyValue(
        properties,
        TransportHeaderNames.arguments,
      );
      if (rawArguments != null) {
        try {
          final decoded = jsonDecode(rawArguments);
          if (decoded is! Map) {
            throw const FormatException('arguments property is not a map');
          }
          arguments = decoded.map<String, String>(
            (key, value) => MapEntry(key.toString(), value.toString()),
          );
        } catch (error, stackTrace) {
          reportError(error, stackTrace);
          continue;
        }
      }

      final transportMessage = TransportMessage(
        subject: subject,
        data: data,
        arguments: arguments,
        replyTo: replyTo,
      );
      for (final entry in _subscriptions.entries) {
        if (_matches(entry.value, subject)) {
          dispatchMessage(entry.key, transportMessage, origin: origin);
        }
      }
    }
  }

  ///MQTT topic-filter matching. `+` matches one level, `#` matches zero or
  ///more trailing levels.
  static bool _matches(String filter, String subject) {
    final pattern = filter.split('/');
    final topic = subject.split('/');
    for (var i = 0; i < pattern.length; i++) {
      final token = pattern[i];
      if (token == '#') return true;
      if (i >= topic.length) return false;
      if (token == '+') continue;
      if (token != topic[i]) return false;
    }
    return pattern.length == topic.length;
  }

  static mqtt.MqttUserProperty _userProperty(String name, String value) {
    return mqtt.MqttUserProperty()
      ..pairName = name
      ..pairValue = value;
  }

  static String? _userPropertyValue(
    List<mqtt.MqttUserProperty> properties,
    String name,
  ) {
    for (final property in properties) {
      if (property.pairName == name) return property.pairValue;
    }
    return null;
  }

  static String _randomSuffix() {
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final salt = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    return '$time$salt';
  }
}
