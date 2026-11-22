import 'dart:async';
import 'dart:isolate';

import 'package:event_bus_arch/event_bus_arch.dart';

/// Create 2 isolate in middle and bottom layer
///
// Hello From Bottom 1069531225
// Hello From Middle 693680537
// SEND 0
// FROM MIDDLE TO BOTTOM 0->1
// FROM BOTTOM TO MIDDLE 1->2
// FROM MIDDLE TO TOP 2->3
// Get from middle 3
// GET 3

class TestData {
  final int count;
  TestData(this.count);
}

///The same address on every layer: routing is explicit, the type is part of
///the key and never appears in the address string.
final chainKey = EventKey<TestData>('chain');

///MIDDLE layer. In WORKER ISOLATE
class TestMiddleIsolateController {
  Layer layer;
  late EventSubscription<TestData> subscriptionTop;
  late EventSubscription<TestData> subscriptionBottom;
  TestMiddleIsolateController(this.layer) {
    //Wait event from top layer
    subscriptionTop = layer.top!.subscribe(chainKey, onEvent: (e) {
      //send new data to
      layer.bottom!.fire(chainKey, TestData(e.count + 1));
      print('FROM MIDDLE TO BOTTOM ${e.count}->${e.count + 1}');
    });
    subscriptionBottom = layer.bottom!.subscribe(chainKey, onEvent: (e) {
      layer.top!.fire(chainKey, TestData(e.count + 1));
      print('FROM MIDDLE TO TOP ${e.count}->${e.count + 1}');
    });
  }
  void dispose() {
    subscriptionTop.cancel();
    subscriptionBottom.cancel();
  }
}

///Bottom layer. In WORKER ISOLATE
class TestBottomIsolateController {
  Layer layer;
  late EventSubscription<TestData> subscriptionTop;

  TestBottomIsolateController(this.layer) {
    //Wait event from top layer
    subscriptionTop = layer.top!.subscribe(chainKey, onEvent: (e) {
      //send new data to
      layer.top!.fire(chainKey, TestData(e.count + 1));
      print('FROM BOTTOM TO MIDDLE ${e.count}->${e.count + 1}');
    });
  }
  void dispose() {
    subscriptionTop.cancel();
  }
}

///Top layer. ON MAIN ISOLATE
class TestIsolateProvider {
  late Layer layer;
  final Completer _completer = Completer();
  Future<void> get wait => _completer.future;
  TestIsolateProvider() {
    ///Create Layer with deep 2
    ///top layer <-> isolate <-> middle layer <-> isolate <-> bottom layer
    Layers.createLayers(
            [LayerSpec(init: _initMiddleLayers, isModelBus: true), LayerSpec(init: _initBottomLayers, isModelBus: true)])
        .then(
      (value) {
        layer = value;
        layer.bottom!.subscribe(chainKey, onEvent: (e) {
          print('Get from middle ${e.count}');
        });
        _completer.complete();
      },
    );
  }
  Future<int> send(int data) async {
    print('SEND $data');
    layer.bottom!.fire(chainKey, TestData(data));
    var ret = (await layer.bottom!.listen(chainKey).first).count;

    return ret;
  }
}

Future<void> main() async {
  var providerIsolate = TestIsolateProvider();
  await providerIsolate.wait;
  print('GET ${await providerIsolate.send(0)}');
  await providerIsolate.layer.close();
}

//This function run in middle Isolate
void _initMiddleLayers(Layer layer, Object? initialData) async {
  print('Hello From Middle ${Isolate.current.hashCode}');

  // await (layer.bottom as EventBusIsolate).waitInit;
  var controller = TestMiddleIsolateController(layer);
  //create closure for controller
  layer.top!.allEventStream.listen(
    null,
    onDone: () {
      controller.dispose();
    },
  );
}

//This function run in bottom Isolate
void _initBottomLayers(Layer layer, Object? initialData) async {
  print('Hello From Bottom ${Isolate.current.hashCode}');
  var controller = TestBottomIsolateController(layer);
  //create closure for controller
  layer.top!.allEventStream.listen(
    null,
    onDone: () {
      controller.dispose();
    },
  );
}
