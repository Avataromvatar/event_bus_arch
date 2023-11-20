part of event_arch;

///Atention The result of calling the event can be received later than the events called in the event handler on the isolate side
///
///EventBusIsolate it consists of two Event bus, one on the side of the main isolate and the other in the working isolate.
///They exchange EventDTO and the results of the handlers' work among themselves.
class EventBusIsolate extends EventBusImpl {
  Map<int, List<Completer>> _request = {};
  void Function(EventBus isolateBus) onInit;
  Isolate? _isolate;

  /// this port for send event to isolate
  SendPort? _toEBSender;

  /// this port listen data from isolate
  /// type of response for request (sended event) = (int, dynamic)
  ReceivePort? _receivePort;
  Completer<bool> _completerInit = Completer();
  Future<bool> get waitInit => _completerInit.future;
  bool get isInit => _toEBSender != null;

  EventBusIsolate({
    required this.onInit,
  }) : super(false) {
    _init();
  }

  @override
  Future? send<T>(T data, {String? path, String? fragment, String? target, Map<String, String>? arguments}) async {
    if (_toEBSender != null) {
      var c = Completer();
      var dto =
          EventDTO<T>(data, path: path, fragment: fragment, arguments: arguments, target: target, completer: null);

      ///We send EventDTO to Isolate and wait return
      if (_request.containsKey(dto.hashCode)) {
        _request[dto.hashCode]!.add(c);
      } else {
        _request[dto.hashCode] = [];
        _request[dto.hashCode]!.add(c);
      }

      _toEBSender!.send(dto);
      return c.future;
      // }
      // var node = _map[dto.topic];
      // if (node != null && node is EventNode<T>) {
      //   node._streamController.add(dto);
      //   return dto.completer?.future;
      // }
      // _allEventStream.add(dto);
      // return null;
      // return super.send(data, path, fragment, target, arguments);
    }
  }

  ///Send to main thread from isolate
  Future? _send(EventDTO dto) async {
    var c = Completer();
    var dtoCopy = EventDTOImpl(dto.topic, dto.data, completer: c);
    var node = _map[dtoCopy.topic];
    if (node != null) {
      node.send(dtoCopy);
      _allEventStream.add((dtoCopy, true));
      return dtoCopy.completer?.future;
    }
    _allEventStream.add((dtoCopy, false));
    return null;
  }

  void dispose() {
    _receivePort?.close();
    Future.delayed(Duration(milliseconds: 100));
    _isolate?.kill();
    _isolate!.pause();
  }

  void _init() async {
    _receivePort = ReceivePort();
    _isolate = await Isolate.spawn(_worker, [_receivePort!.sendPort, onInit]);

    _receivePort!.listen(
      (message) {
        if (message is SendPort) {
          _toEBSender = message;
          // print('EventBusIsolate get send port');
          _completerInit.complete(true);
        }
        if (message is (int, dynamic)) {
          var m = _request[message.$1];
          if (m != null && m.isNotEmpty) {
            var c = m.removeAt(0);
            c.complete(message.$2);
          } else {
            if (m?.isEmpty ?? false) {
              throw Exception('Discrepancy between created events (requests) and received responses from the Isolate');
            }
          }
        } else if (message is EventDTO) {
          _send(message)?.then((value) => _toEBSender?.send((message.hashCode, value)));
        }
      },
      onDone: () {
        dispose();
      },
    );
  }
}

void _worker(dynamic data) async {
  void Function(EventBus) onInit = data[1];

  ReceivePort innerReceivePort = ReceivePort();
  var s = innerReceivePort.asBroadcastStream();
  SendPort sendPort = data[0];
  sendPort.send(innerReceivePort.sendPort);

  var eventBus = _EventBusForIsolate(false, s, sendPort);

  onInit(eventBus);

  // var listenerSend = eventBus.al.listen((event) {
  //   sendPort.send(event);
  // });
  // var listenerCall = eventBus.streamCall.listen((event) {
  //   sendPort.send(event);
  // });

  // ignore: unused_local_variable
  await for (var message in s) {
    // // if (message is _CallEventDTO) {
    // // if (message is EventDTO) {
    // //   eventBus.sinkToCall.add(message);
    // // } else
    // if (message is EventDTO) {
    //   //if (message is _SendEventDTO) {
    //   eventBus.sink.add(message);
    // }
  }
  // listenerSend.cancel();
  //listenerCall.cancel();
  innerReceivePort.close();
}

class _EventBusForIsolate extends EventBusImpl {
  Map<int, List<Completer>> _request = {};
  Stream<dynamic> _receivePort;
  SendPort _sendPort;
  _EventBusForIsolate(super.isModelBus, this._receivePort, this._sendPort) {
    _receivePort.listen((message) {
      if (message is (int, dynamic)) {
        //--- This is completer message
        var m = _request[message.$1];
        if (m != null && m.isNotEmpty) {
          var c = m.removeAt(0);
          c.complete(message.$2);
        } else {
          if (m?.isEmpty ?? false) {
            throw Exception('Discrepancy between created events (requests) and received responses from the Isolate');
          }
        }
      } else if (message is EventDTO) {
        _send(message)?.then((value) => _sendPort.send((message.hashCode, value)));
      }
    });
  }

  ///This func send event from _receivePort to isolate bus
  ///dto come without completer and we add new completer for send result back to main thread
  Future? _send(EventDTO dto) async {
    var c = Completer();
    var dtoCopy = EventDTOImpl(dto.topic, dto.data, completer: c);
    var node = _map[dtoCopy.topic];

    if (node != null) {
      node.send(dtoCopy);
      _allEventStream.add((dtoCopy, true));
      return dtoCopy.completer?.future;
    }
    _allEventStream.add((dtoCopy, false));
    return null;
  }

  @override
  Future? send<T>(T data, {String? path, String? fragment, String? target, Map<String, String>? arguments}) {
    var c = Completer();
    var dto = EventDTO<T>(data, path: path, fragment: fragment, arguments: arguments, target: target, completer: null);

    ///We send EventDTO to Isolate and wait return
    if (_request.containsKey(dto.hashCode)) {
      _request[dto.hashCode]!.add(c);
    } else {
      _request[dto.hashCode] = [];
      _request[dto.hashCode]!.add(c);
    }

    _sendPort.send(dto);
    return c.future;
  }
}
