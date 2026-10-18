import 'package:event_bus_nats/event_bus_nats.dart';
import 'package:test/test.dart';

void main() {
  test('the public types are exported', () {
    expect(EventBusNats, isNotNull);
    expect(EventNodeNatsImpl, isNotNull);
  });
}
