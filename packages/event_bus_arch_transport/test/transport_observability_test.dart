import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';
import 'package:event_bus_arch_transport/testing.dart';
import 'package:test/test.dart';

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

EventCodec _intCodec() => EventCodec(
      encode: (dto) => (null, Uint8List.fromList(utf8.encode('${dto.data}'))),
      decode: (data, address, {arguments}) => EventDTO<int>.withKey(
        EventKey<int>(address.value),
        int.parse(utf8.decode(data)),
      ),
    );

void main() {
  test('correlation id and metrics cross the transport seam', () async {
    final connection = FakeTransportConnection();
    final bus = TransportEventBus.keys(
      connection: connection,
      addresses: EventAddressMapper(grammar: const _TestGrammar()),
      codecs: EventCodecRegistry(exact: {
        EventAddress('int.a'): _intCodec(),
        EventAddress('int.b'): _intCodec(),
      }),
      originId: 'origin',
      observability: const ObservabilityConfig(enabled: true),
    );
    await bus.waitConnected();

    String? seen;
    final sub =
        bus.subscribe(EventKey<int>('int.a'), handler: (dto, lastData) async {
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
    final response = connection.publishes
        .singleWhere((publish) => publish.subject == '_INBOX.1');
    expect(response.correlationId, 'corr-in');

    expect(bus.fire(EventKey<int>('int.a'), 5, correlationId: 'corr-fire'),
        isTrue);
    final published = connection.publishes
        .where((publish) => publish.subject == 'int.a')
        .toList();
    expect(published, hasLength(1));
    expect(published.single.correlationId, 'corr-fire');

    final pending = bus.request(EventKey<int>('int.b'), 6,
        correlationId: 'corr-req', timeout: const Duration(milliseconds: 20));
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
