import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';
import 'package:event_bus_arch_transport/testing.dart';
import 'package:test/test.dart';
import '../../../test/legacy_compat.dart';

class _TestGrammar extends SubjectGrammar {
  const _TestGrammar();

  @override
  String get separator => '.';

  @override
  String get singleWildcard => '*';

  @override
  String get tailWildcard => '>';

  @override
  void validatePublishToken(String token, {required bool isFirst}) {}

  @override
  void validateSubscriptionToken(String token,
      {required bool isFirst, required bool isLast}) {}
}

(String?, Uint8List) _encode(EventDTO dto) =>
    (null, Uint8List.fromList(utf8.encode('${dto.data}')));

EventDTO _decode(Uint8List data, String topic,
        {Map<String, String>? arguments}) =>
    EventDTO<int>(int.parse(utf8.decode(data)), topic: Topic.parse(topic));

void main() {
  test('correlation id and metrics cross the transport seam', () async {
    final connection = FakeTransportConnection();
    final bus = TransportEventBus(
      connection: connection,
      subjects: TopicSubjectMapper(grammar: const _TestGrammar()),
      serializers: {'int': _encode},
      deserializers: {'int': _decode},
      originId: 'origin',
      observability: const ObservabilityConfig(enabled: true),
    );
    await bus.waitConnected();

    String? seen;
    final sub = bus.subscribeEventsLegacy<int>(
        paths: ['a'], handler: (dto, lastData) async {
      seen = dto.correlationId;
      return 7;
    });

    connection.deliver(TransportMessage(
      subject: 'int.a',
      data: Uint8List.fromList(utf8.encode('1')),
      correlationId: 'corr-in',
      replyTo: '_INBOX.1',
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(seen, 'corr-in');
    final response =
        connection.publishes.singleWhere((publish) => publish.subject == '_INBOX.1');
    expect(response.correlationId, 'corr-in');

    expect(bus.fireLegacy<int>(5, paths: ['a'], correlationId: 'corr-fire'), isTrue);
    final published = connection.publishes
        .where((publish) => publish.subject == 'int.a')
        .toList();
    expect(published, hasLength(1));
    expect(published.single.correlationId, 'corr-fire');

    final pending = bus.requestLegacy<int>(6,
        paths: ['b'],
        correlationId: 'corr-req',
        timeout: const Duration(milliseconds: 20));
    expect(connection.requests, hasLength(1));
    expect(connection.requests.single.correlationId, 'corr-req');
    await expectLater(pending, throwsA(isA<TimeoutException>()));

    final snapshot = bus.metrics.snapshot();
    final firedTopic =
        snapshot.topics.firstWhere((metrics) => metrics.key == 'int.a');
    expect(firedTopic.fired, 1);
    // one incoming request from the broker on int.a
    expect(firedTopic.requestsStarted, 1);
    expect(firedTopic.requestsCompleted, 1);

    final remoteTopic =
        snapshot.topics.firstWhere((metrics) => metrics.key == 'int.b');
    // one outgoing remote request on int.b
    expect(remoteTopic.requestsStarted, 1);
    expect(remoteTopic.requestsTimeout, 1);

    await sub.cancel();
    await bus.dispose();
  });
}
