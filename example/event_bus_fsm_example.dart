
import 'package:event_bus_arch/event_bus_arch.dart';

enum FSMTeststate
{
  state0,
  state1,
  state2,
  state3
}
class FSMTest with FSM<FSMTeststate>
{
  final EventBus bus;
  FSMTest(this.bus)
  {
    initFSM(bus, FSMTeststate.state0);
    addFSMTransition<int>(FSMTeststate.state0, FSMTeststate.state1,filter: (currentState, lastState, event) { return event==1;},handler:(currentState, lastState, event, ignoredEvents) async{
      print('$lastState -> $currentState with $event');
      return null;
    }, );
    addFSMTransition<int>(FSMTeststate.state1, FSMTeststate.state2,filter: (currentState, lastState, event) { return event==2;},handler:(currentState, lastState, event, ignoredEvents) async{
      print('$lastState -> $currentState with $event');
      return null;
    },);
    addFSMTransition<String>(FSMTeststate.state2, FSMTeststate.state3,handler: (currentState, lastState, event, ignoredEvents) async{
      print('$lastState -> $currentState with $event');
      return null;
    },);
  }

}
Future<void> main()async
{
  var fsm = FSMTest(EventBus());
  await fsm.bus.send(1);
  await fsm.bus.send(2);
  await fsm.bus.send('Test');

}
