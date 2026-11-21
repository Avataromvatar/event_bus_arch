import 'package:test/test.dart';

import '../tool/migrate_3_to_4.dart';

void main() {
  test('the handler call is rewritten and manual findings are reported', () {
    const source = '''
final sub = bus.handlers.setHandler<int>(handler: (dto, last) async => 1);
bus.handlers.removeHandler<int>();
bus.handlers.addAllHandlerFromOtherBus(other);
final EventBusHandlers? handlers;
import 'package:rxdart/rxdart.dart';
''';

    final report = migrateSource(source, 'sample.dart');

    expect(report.handlersChanged, 1);
    expect(report.changed, contains('bus.subscribeEvents<int>'));
    expect(report.changed, isNot(contains('.handlers.setHandler')));
    expect(report.removalsFound, 1);
    expect(report.crossBusFound, 1);
    expect(report.handlerTypeFound, 1);
    expect(report.rxdartFound, 2); // 'package:rxdart/rxdart.dart' has two matches
  });

  test('a clean file has no changes or warnings', () {
    const source = '''
void main() {
  final bus = EventBus();
  bus.subscribeEvents<int>(handler: (dto, last) async => 1);
}
''';

    final report = migrateSource(source, 'clean.dart');

    expect(report.hasChanges, isFalse);
    expect(report.hasWarnings, isFalse);
    expect(report.changed, isEmpty);
  });
}
