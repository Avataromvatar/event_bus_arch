import 'package:test/test.dart';

import '../tool/migrate_3_to_4.dart';

void main() {
  test('the handler call is found and manual findings are reported', () {
    const source = '''
final sub = bus.handlers.setHandler<int>(handler: (dto, last) async => 1);
bus.handlers.removeHandler<int>();
bus.handlers.addAllHandlerFromOtherBus(other);
final EventBusHandlers? handlers;
import 'package:rxdart/rxdart.dart';
''';

    final report = migrateSource(source, 'sample.dart');

    expect(report.handlersChanged, 1);
    expect(report.removalsFound, 1);
    expect(report.crossBusFound, 1);
    expect(report.handlerTypeFound, 1);
    expect(
        report.rxdartFound, 2); // 'package:rxdart/rxdart.dart' has two matches
  });

  test('a clean file has no changes or warnings', () {
    const source = '''
void main() {
  final bus = EventBus();
  bus.subscribe<int>(handler: (dto, last) async => 1);
}
''';

    final report = migrateSource(source, 'clean.dart');

    expect(report.hasChanges, isFalse);
    expect(report.hasWarnings, isFalse);
    expect(report.changed, isEmpty);
  });

  test('paths, topics and legacy transports are reported with line numbers',
      () {
    const source = r"""
void main() {
  bus.fire<int>(1, paths: ['sensor', 'temp']);
  bus.subscribeEvents<int>(paths: ['sensor', '*']);
  bus.removeTopic<int>(paths: ['sensor']);
  final topic = Topic('sensor');
  bus.serializers = {'int.sensor': encode};
}
""";

    final report = migrateSource(source, 'sample.dart');

    expect(report.pathCallsFound, 3);
    expect(report.topicTypeFound, 1);
    expect(report.removeTopicFound, 1);
    expect(report.legacyTransportFound, 1);
    expect(report.findings, hasLength(7));
    expect(report.hasWarnings, isTrue);
    expect(report.changed, isEmpty,
        reason: 'an address cannot be invented by the tool');
    expect(report.findings.every((finding) => finding.line >= 2), isTrue);
  });
}
