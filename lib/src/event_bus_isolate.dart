part of event_arch;

class _SendEventDTO extends EventDTOImpl {
  _SendEventDTO(super.topic, super.data);
}

class _CallEventDTO extends EventDTOImpl {
  _CallEventDTO(super.topic, super.data);
}

class EventBusIsolate {
  ///this func call from other isolate
  EventBus Function() onInit;
  Isolate? _isolate;
  SendPort? _toEBSender;
  ReceivePort? _receivePort;
  bool get isInit => _toEBSender != null;
  EventBusIsolate({required this.onInit}) {
    _init();
  }
  void dispose() {
    _receivePort?.close();
    Future.delayed(Duration(milliseconds: 100));
    _isolate?.kill();
    _isolate!.pause();
  }

  void _init() async {
    _receivePort = ReceivePort();
    _isolate = await Isolate.spawn(_worker, _receivePort!.sendPort);
    _toEBSender = await _receivePort!.first;
  }

  void _worker(SendPort sendPort) async {
    ReceivePort innerReceivePort = ReceivePort();
    sendPort.send(innerReceivePort.sendPort);
    var eventBus = onInit();

    var listenerSend = eventBus.streamSend.listen((event) {
      sendPort.send(event);
    });
    var listenerCall = eventBus.streamCall.listen((event) {
      sendPort.send(event);
    });

    await for (var message in innerReceivePort) {
      if (message is _CallEventDTO) {
        eventBus.sinkToCall.add(message);
      } else if (message is _SendEventDTO) {
        eventBus.sinkToSend.add(message);
      }
    }
    listenerSend.cancel();
    listenerCall.cancel();
    innerReceivePort.close();
  }
}
