import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';

///Encodes an event for the server.
///
///Returns the subject to publish to and the payload. A null subject means
///“derive it from [EventDTO.topic]”; a non-null subject is used as is and must
///already be a full wire subject.
typedef EventDTOSerialization = (String?, Uint8List) Function(EventDTO dto);

///Builds an event from a payload received from the server.
///
///[topic] is the local topic parsed from the message subject, with the
///configured prefix already removed. [arguments] are the call arguments that
///travelled in the message headers.
typedef EventDTODeserialization =
    EventDTO Function(
      Uint8List data,
      String topic, {
      Map<String, String>? arguments,
    });
