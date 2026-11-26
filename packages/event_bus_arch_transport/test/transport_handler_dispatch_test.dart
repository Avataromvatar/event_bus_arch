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
  test('overlapping exact and pattern handlers answer a request once',
      () async {
    final connection = FakeTransportConnection();
    final bus = TransportEventBus.keys(
      connection: connection,
      addresses: EventAddressMapper(grammar: const _TestGrammar()),
      codecs: EventCodecRegistry(exact: {EventAddress('int.a'): _intCodec()}),
      originId: 'origin',
    );
    await bus.waitConnected();

    final exact = bus.subscribe(EventKey<int>('int.a'),
        handler: (dto, lastData) async => 1);
    final pattern = bus.subscribe(EventPatternKey<int>('int.*'),
        handler: (dto, lastData) async => 2);

    connection.deliver(TransportMessage(
      subject: 'int.a',
      data: Uint8List.fromList(utf8.encode('7')),
      replyTo: '_INBOX.1',
    ));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final responses = connection.publishes
        .where((publish) => publish.subject == '_INBOX.1')
        .toList();
    expect(responses, hasLength(1));
    expect(int.parse(utf8.decode(responses.single.data)), 1);

    await exact.cancel();
    await pattern.cancel();
    await bus.dispose();
  });
}
