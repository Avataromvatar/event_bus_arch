part of event_arch;

// class _SendEventDTO extends EventDTOImpl {
//   _SendEventDTO(super.topic, super.data);
// }

// class _CallEventDTO extends EventDTOImpl {
//   _CallEventDTO(super.topic, super.data);
// }

class EventBusIsolate extends EventBusImpl {
  // final StreamController<EventDTO> _toEBStreamController = StreamController.broadcast();
  // final StreamController<EventDTO> _fromEBStreamController = StreamController.broadcast();
  // @override
  // // TODO: implement sinkToCall
  // Sink<EventDTO> get sinkToCall => throw UnimplementedError();

  // @override
  // // TODO: implement sinkToSend
  // Sink<EventDTO> get sinkToSend => _toEBStreamController.sink;

  // @override
  // // TODO: implement streamCall
  // Stream<(EventDTO, dynamic)> get streamCall => throw UnimplementedError();

  // @override
  // // TODO: implement streamSend
  // Stream<EventDTO> get streamSend => _fromEBStreamController.stream;

  ///this func call from other isolate
  EventBus Function() onInit;
  Isolate? _isolate;
  SendPort? _toEBSender;
  ReceivePort? _receivePort;
  Completer<bool> _completerInit = Completer();
  Future<bool> get waitInit => _completerInit.future;
  bool get isInit => _toEBSender != null;
  EventBusIsolate({required this.onInit, required super.name, super.addToMaster}) {
    _init();
  }
  void dispose() {
    _receivePort?.close();
    Future.delayed(Duration(milliseconds: 100));
    _isolate?.kill();
    _isolate!.pause();
  }

  void _init() async {
    // print('Begin Inital EventBusIsolate');
    _receivePort = ReceivePort();

    _isolate = await Isolate.spawn(_worker, [_receivePort!.sendPort, onInit]);
    // print('Isolate create');
    // _toEBSender = await _receivePort!.first;
    //from isolate eb to stream eb
    _receivePort!.listen((message) {
      if (message is SendPort) {
        _toEBSender = message;
        // print('EventBusIsolate get send port');
        _completerInit.complete(true);
      }
      // if (message is (EventDTO<dynamic>, dynamic)) {
      //   //call result TODO:
      //   // print('get call result');
      // } else
      if (message is EventDTO) {
        sink.add(message);
      }
    });
    //from stream eb to isolate eb
    stream.listen((event) {
      _toEBSender!.send(event);
    });
  }
}

void _worker(dynamic data) async {
  EventBus Function() onInit = data[1];

  ReceivePort innerReceivePort = ReceivePort();
  SendPort sendPort = data[0];
  sendPort.send(innerReceivePort.sendPort);
  var eventBus = onInit();

  var listenerSend = eventBus.stream.listen((event) {
    sendPort.send(event);
  });
  // var listenerCall = eventBus.streamCall.listen((event) {
  //   sendPort.send(event);
  // });

  await for (var message in innerReceivePort) {
    // if (message is _CallEventDTO) {
    // if (message is EventDTO) {
    //   eventBus.sinkToCall.add(message);
    // } else
    if (message is EventDTO) {
      //if (message is _SendEventDTO) {
      eventBus.sink.add(message);
    }
  }
  listenerSend.cancel();
  //listenerCall.cancel();
  innerReceivePort.close();
}
