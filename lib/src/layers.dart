
part of event_arch;

typedef fnInitLayer = void Function(Layer,Object? initalData);
class _LayerInitDto
{
  final List<(fnInitLayer,Object?,bool)> data;
  int index;
  // final fnInitLayer onInit;

  _LayerInitDto({required this.data, this.index=0});
}

class Layer{
  ///For send/recive event from top layer
  EventBus? top;
  ///eventbus for local layer use
  EventBus current;
  ///For send/recive event from bottom layer
  EventBus? bottom;

  Layer({this.top, required this.current, this.bottom});

  Future<void> close()async
  {
    if(bottom!=null)
    {
      (bottom as EventBusIsolate).dispose();
      bottom= null;
    }
    if(top!=null)
    {
      (top as EventBusIsolate).dispose();
      top =null;
    }
  }

}


class Layers {
  ///Layers create layer what split by isolate. Top layer have current and bottom eventbus, bottom eventbus this is EventBusIsolate,
  /// middle layer have top eventbus for connect to top layer and bottom eventbus for cnnect bottom layer if they present  
  ///
  ///(fnInitLayer,Object?,bool) - inital function, inital data, flag what create model current bus in isolate/
  static Future<Layer> createLayers(List<(fnInitLayer,Object?,bool)> layers,{currentIsModelBus=true})async{

    _LayerInitDto storage = _LayerInitDto(data: layers,index: 0);
    
    Layer l=Layer(current: EventBus(isModelBus: currentIsModelBus), bottom: EventBusIsolate(onInit: _initLayer,initalData: storage)); 
    await (l.bottom as EventBusIsolate).waitInit; 
    return l;
  }
}

void _initLayer(EventBus bus , Object? initData)async
{
  
  if(initData!=null)
  {
    _LayerInitDto dto = initData as _LayerInitDto;
    int index = dto.index;
    dto.index++;
    Layer l=Layer(current: EventBus(isModelBus: dto.data[index].$3), top:bus,bottom:dto.index<dto.data.length?EventBusIsolate(onInit: _initLayer,initalData: dto):null ); 
    if(l.bottom!=null)
    {
      await (l.bottom as EventBusIsolate).waitInit;
      // l.top!.allEventStream.doOnDone((){
      //   (l.bottom as EventBusIsolate).dispose();
      // });
    }
    dto.data[index].$1.call(l,dto.data[index].$2);
  }
}