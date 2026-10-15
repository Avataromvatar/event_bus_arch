part of event_arch;

///The exception type of the package: an invalid topic, an uninitialized
///Scope/Command, an isolate exchange failure.
class EventBusException implements Exception {
  final dynamic message;
  EventBusException([this.message]);
  @override
  String toString() {
    Object? message = this.message;
    if (message == null) return "EventBusException";
    return "EventBusException: $message";
  }
}
