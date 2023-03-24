#!/bin/sh
set -e

git add .
sleep 1
git commit -m "$1"
sleep 1
dart pubspec_changer.dart
sleep 1
dart pub upgrade
sleep 1

