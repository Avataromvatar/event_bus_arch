#!/bin/sh
set -e


sleep 1
dart pubspec_changer.dart
sleep 1
dart pub upgrade
sleep 1

