import 'dart:async';

import 'package:test/test.dart';

void main() async {
  // StreamController<int> s = StreamController.broadcast();
  print(await generate().last);
  Future.delayed(Duration(microseconds: 1000));
}

Stream<int> generate() async* {
  Future.delayed(Duration(microseconds: 100));
  yield 1;
  Future.delayed(Duration(microseconds: 100));
  yield 2;
  Future.delayed(Duration(microseconds: 100));
  yield 3;
  Future.delayed(Duration(microseconds: 100));
  yield 4;
}
