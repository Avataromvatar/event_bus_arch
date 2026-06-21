
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

class TestData
{
  final int count;
  TestData(this.count);
}

///MIDDLE layer. In WORKER ISOLATE
class TestMiddleIsolateController
{
  Layer layer;
  late StreamSubscription<TestData> subscriptionTop;
  late StreamSubscription<TestData> subscriptionBottom;
  TestMiddleIsolateController(this.layer){
    //Wait event from top layer
    subscriptionTop = layer.top!.subscribe<TestData>(onData: (e) {
      //send new data to 
      layer.bottom!.send(TestData(e.count+1));
      print('FROM MIDDLE TO BOTTOM ${e.count}->${e.count+1}');
    },);
    subscriptionBottom = layer.bottom!.subscribe(onData: (e) {
       layer.top!.send(TestData(e.count+1));
      print('FROM MIDDLE TO TOP ${e.count}->${e.count+1}');
    },);
  }
  void dispose()
  {
    subscriptionTop.cancel();
    subscriptionBottom.cancel();
  }
}


///Bottom layer. In WORKER ISOLATE
class TestBottomIsolateController
{
  Layer layer;
  late StreamSubscription<TestData> subscriptionTop;
  
  TestBottomIsolateController(this.layer){
    //Wait event from top layer
    subscriptionTop = layer.top!.subscribe<TestData>(onData: (e) {
      //send new data to 
      layer.top!.send(TestData(e.count+1));
      print('FROM BOTTOM TO MIDDLE ${e.count}->${e.count+1}');
    },);
    
  }
  void dispose()
  {
    subscriptionTop.cancel();
    
  }
}
///Top layer. ON MAIN ISOLATE
class TestIsolateProvider
{
  late Layer layer;
  Completer _completer = Completer();
  Future<void> get wait =>_completer.future;
  TestIsolateProvider()
  {
    ///Create Layer with deep 2  
    ///top layer <-> isolate <-> middle layer <-> isolate <-> bottom layer
    Layers.createLayers([(_initMiddleLayers,null,true),(_initBottomLayers,null,true)]).then((value) {
      layer = value;
      layer.bottom!.subscribe<TestData>(onData: (e) {
        print('Get from middle ${e.count}');
      },);
      _completer.complete();

    },);
  }
  Future<int> send(int data)async
  {
    print('SEND $data');
    layer.bottom!.send(TestData(data));
    var ret = (await layer.bottom!.listen<TestData>().first).count;
    
    return ret;
  }
}

Future<void> main()async
{
  var providerIsolate = TestIsolateProvider();
  await providerIsolate.wait;
  print('GET ${await providerIsolate.send(0)}');
  await providerIsolate.layer.close();
}

//This function run in middle Isolate
void _initMiddleLayers(Layer layer,Object? initalData)async
{
    print('Hello From Middle ${Isolate.current.hashCode}');
    
    // await (layer.bottom as EventBusIsolate).waitInit;
    var controller = TestMiddleIsolateController(layer);
    //create closure for controller
    layer.top!.allEventStream.doOnDone(() {
      controller.dispose();
    },);
}
void _initBottomLayers(Layer layer,Object? initalData) async
{
  print('Hello From Bottom ${Isolate.current.hashCode}');
    var controller = TestBottomIsolateController(layer);
    //create closure for controller
    layer.top!.allEventStream.doOnDone(() {
      controller.dispose();
    },);
}
