part of event_arch;

///Compile-time platform capabilities of the package.
///
///The isolate APIs are VM-only. On a JS or Wasm target the library still
///compiles and the local bus works, but constructing an isolate API throws
///[UnsupportedError] instead of failing inside `dart:isolate`.
abstract final class EventBusCapabilities {
  ///True on a JavaScript or Wasm target.
  static const bool isWeb = bool.fromEnvironment('dart.library.js_interop');

  ///Whether [EventBusIsolate], [Layers] and [WorkerPool] are available.
  static const bool isolateSupported = !isWeb;

  ///The transport seam and [TransportEventBus] are platform-neutral. A
  ///concrete broker connection may still be VM-only; see the adapter docs.
  static const bool transportSupported = true;
}

///Throws when an isolate API is constructed on the web.
void _requireIsolates(String api) {
  if (!EventBusCapabilities.isolateSupported) {
    throw UnsupportedError(
        '$api is not supported on the web: dart:isolate is unavailable. '
        'Use EventBus for local pub/sub and a transport for cross-process '
        'events.');
  }
}