#!/bin/sh
set -e

git add .
sleep 1
git commit -m "$1"
sleep 1
dart pubspec_changer.dart c "$1"
sleep 1
dart pubspec_changer.dart v
sleep 1
git add .
git commit --amend
sleep 1
dart pub upgrade
sleep 1

