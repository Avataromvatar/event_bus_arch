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
