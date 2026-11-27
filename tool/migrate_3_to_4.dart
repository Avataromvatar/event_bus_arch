// Review-first 3.x -> 4.x migration helper.
//
// Usage:
//   dart run tool/migrate_3_to_4.dart [--write] [path ...]
//
// Without --write it prints what it would change and writes nothing. Paths may
// be files or directories; the default is the current directory, skipping
// .dart_tool, build and .git. Every migration finding needs a human review: the
// address model changed, so a 3.x path cannot be converted to an EventKey
// without choosing the application address.

// ignore_for_file: avoid_print

import 'dart:io';

///One line that needs a manual migration decision.
class MigrationFinding {
  const MigrationFinding(this.line, this.message);

  final int line;
  final String message;

  @override
  String toString() => 'line $line: $message';
}

///What one source file needs.
class MigrationReport {
  const MigrationReport({
    required this.path,
    required this.changed,
    required this.handlersChanged,
    required this.removalsFound,
    required this.crossBusFound,
    required this.handlerTypeFound,
    required this.rxdartFound,
    required this.findings,
    required this.pathCallsFound,
    required this.topicTypeFound,
    required this.subscribeEventsFound,
    required this.removeTopicFound,
    required this.legacyTransportFound,
  });

  final String path;
  final String changed;
  final int handlersChanged;
  final int removalsFound;
  final int crossBusFound;
  final int handlerTypeFound;
  final int rxdartFound;

  ///Path, topic, subscribeEvents, removeTopic and legacy transport findings.
  final List<MigrationFinding> findings;
  final int pathCallsFound;
  final int topicTypeFound;
  final int subscribeEventsFound;
  final int removeTopicFound;
  final int legacyTransportFound;

  bool get hasChanges => changed != _unchanged;
  bool get hasWarnings =>
      removalsFound > 0 ||
      crossBusFound > 0 ||
      handlerTypeFound > 0 ||
      rxdartFound > 0 ||
      findings.isNotEmpty;

  static const String _unchanged = '';
}

///Rewrites the known safe handler surface in [source] and reports the rest.
///
///The only automatic rewrite is `x.handlers.setHandler(...)` ->
///`x.subscribe(...)`. Addresses, `paths:` and transport codecs need a human
///decision because the 3.x type-prefixed topic is not a 4.x address.
MigrationReport migrateSource(String source, String path) {
  var text = source;
  var handlersChanged = 0;
  text = text.replaceAllMapped(
    RegExp(r'\.handlers\.setHandler\b'),
    (_) {
      handlersChanged++;
      return '.subscribe';
    },
  );

  int count(String pattern) => RegExp(pattern).allMatches(source).length;

  final findings = <MigrationFinding>[];
  final pathPattern = RegExp(r'\b(paths|separator)\s*:');
  final topicPattern = RegExp(r'\bTopic(Pattern)?\b');
  final subscribeEventsPattern = RegExp(r'\bsubscribeEvents\b');
  final removeTopicPattern = RegExp(r'\bremoveTopic\b');
  final legacyTransportPattern = RegExp(
      r'\b(serializers|deserializers|typeTags|TopicSubjectMapper|TransportEventNode|TopicRegistryIndex)\b');

  void collect(RegExp pattern, String message) {
    for (final match in pattern.allMatches(source)) {
      findings.add(MigrationFinding(_lineOf(source, match.start), message));
    }
  }

  collect(pathPattern,
      'paths:/separator: — replace with an EventKey/EventPatternKey address');
  collect(topicPattern,
      'Topic/TopicPattern — replace with EventAddress/EventPattern');
  collect(subscribeEventsPattern,
      'subscribeEvents — replace with subscribe(selector, ...)');
  collect(removeTopicPattern,
      'removeTopic — replace with remove(selector) or removeAddress(address)');
  collect(legacyTransportPattern,
      'legacy transport registry — replace with EventCodec/EventCodecRegistry');

  return MigrationReport(
    path: path,
    changed: handlersChanged == 0 ? '' : text,
    handlersChanged: handlersChanged,
    removalsFound: count(r'\.handlers\.removeHandler\b'),
    crossBusFound: count(
        r'\b(addAllHandlerFromOtherBus|removeAllHandlerPresentInOtherBus)\b'),
    handlerTypeFound: count(r'\bEventBusHandlers\b'),
    rxdartFound: count(r'\brxdart\b'),
    findings: findings,
    pathCallsFound: pathPattern.allMatches(source).length,
    topicTypeFound: topicPattern.allMatches(source).length,
    subscribeEventsFound: subscribeEventsPattern.allMatches(source).length,
    removeTopicFound: removeTopicPattern.allMatches(source).length,
    legacyTransportFound: legacyTransportPattern.allMatches(source).length,
  );
}

int _lineOf(String source, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < source.length; i++) {
    if (source.codeUnitAt(i) == 10) line++;
  }
  return line;
}

Future<void> main(List<String> args) async {
  var write = false;
  final paths = <String>[];
  for (final arg in args) {
    if (arg == '--write') {
      write = true;
    } else if (arg == '--help' || arg == '-h') {
      _usage();
      return;
    } else {
      paths.add(arg);
    }
  }
  if (paths.isEmpty) paths.add('.');

  final files = <File>[];
  for (final path in paths) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.file && path.endsWith('.dart')) {
      files.add(File(path));
    } else if (type == FileSystemEntityType.directory) {
      await for (final entity in Directory(path).list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (_isSkipped(entity.path)) continue;
        files.add(entity);
      }
    } else {
      print('skip: $path is not a Dart file or directory');
    }
  }

  var changedFiles = 0;
  var totalHandlers = 0;
  var totalWarnings = 0;
  var totalFindings = 0;
  for (final file in files) {
    final source = await file.readAsString();
    final report = migrateSource(source, file.path);
    totalHandlers += report.handlersChanged;
    final warnings = report.removalsFound +
        report.crossBusFound +
        report.handlerTypeFound +
        report.rxdartFound;
    totalWarnings += warnings;
    totalFindings += report.findings.length;
    if (!report.hasChanges && !report.hasWarnings) continue;
    changedFiles++;
    print('${report.path}:');
    if (report.handlersChanged > 0) {
      print(
          '  setHandler: ${report.handlersChanged} — replace with subscribe(selector, handler: ...)');
    }
    if (report.removalsFound > 0) {
      print(
          '  removeHandler: ${report.removalsFound} — store the subscription and cancel it');
    }
    if (report.crossBusFound > 0) {
      print(
          '  cross-bus handler copy: ${report.crossBusFound} — recreate subscriptions manually');
    }
    if (report.handlerTypeFound > 0) {
      print(
          '  EventBusHandlers: ${report.handlerTypeFound} — use EventSubscription');
    }
    if (report.rxdartFound > 0) {
      print(
          '  rxdart: ${report.rxdartFound} — add it to your own dependencies');
    }
    for (final finding in report.findings) {
      print('  $finding');
    }
    if (write && report.hasChanges) {
      await file.writeAsString(report.changed);
    }
  }

  print('');
  print(
      'Files touched: $changedFiles, automatic handler rewrites: $totalHandlers, '
      'manual findings: $totalWarnings + $totalFindings address/topic/transport');
  if (!write && totalHandlers > 0) {
    print(
        'Dry run. Re-run with --write to apply the automatic handler rewrite.');
  }
  if (totalWarnings > 0 || totalFindings > 0) {
    print(
        'Review every finding; the script does not rewrite addresses or codecs.');
  }
}

bool _isSkipped(String path) {
  final normalized = path.replaceAll('\\', '/');
  // The script itself contains the patterns it searches for; never rewrite it.
  if (normalized.endsWith('/migrate_3_to_4.dart') ||
      normalized == 'migrate_3_to_4.dart') {
    return true;
  }
  return normalized.contains('/.dart_tool/') ||
      normalized.contains('/build/') ||
      normalized.contains('/.git/');
}

void _usage() {
  print('Usage: dart run tool/migrate_3_to_4.dart [--write] [path ...]\n'
      '  --write   apply the automatic handler rewrite (default: dry run)\n'
      '  path      Dart file or directory (default: current directory)');
}
