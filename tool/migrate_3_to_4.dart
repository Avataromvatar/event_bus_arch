// Mechanical 3.x -> 4.0 migration helper.
//
// Usage:
//   dart run tool/migrate_3_to_4.dart [--write] [path ...]
//
// Without --write it prints what it would change and writes nothing. Paths may
// be files or directories; the default is the current directory, skipping
// .dart_tool, build and .git. Every change still needs a human review: the
// script is regex-based and cannot invent a variable name for a subscription
// that must be cancelled later.

// ignore_for_file: avoid_print

import 'dart:io';

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
  });

  final String path;
  final String changed;
  final int handlersChanged;
  final int removalsFound;
  final int crossBusFound;
  final int handlerTypeFound;
  final int rxdartFound;

  bool get hasChanges => changed != _unchanged;
  bool get hasWarnings =>
      removalsFound > 0 ||
      crossBusFound > 0 ||
      handlerTypeFound > 0 ||
      rxdartFound > 0;

  static const String _unchanged = '';
}

///Rewrites the known 3.x handler surface in [source].
///
///The only automatic rewrite is `x.handlers.setHandler(...)` ->
///`x.subscribeEvents(...)`. Everything else is reported, because removing a
///handler now means cancelling the `EventSubscription` that replaced it.
MigrationReport migrateSource(String source, String path) {
  var text = source;
  var handlersChanged = 0;
  text = text.replaceAllMapped(
    RegExp(r'\.handlers\.setHandler\b'),
    (_) {
      handlersChanged++;
      return '.subscribeEvents';
    },
  );

  int count(String pattern) =>
      RegExp(pattern).allMatches(source).length;

  return MigrationReport(
    path: path,
    changed: handlersChanged == 0 ? '' : text,
    handlersChanged: handlersChanged,
    removalsFound: count(r'\.handlers\.removeHandler\b'),
    crossBusFound: count(r'\b(addAllHandlerFromOtherBus|removeAllHandlerPresentInOtherBus)\b'),
    handlerTypeFound: count(r'\bEventBusHandlers\b'),
    rxdartFound: count(r'\brxdart\b'),
  );
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
  for (final file in files) {
    final source = await file.readAsString();
    final report = migrateSource(source, file.path);
    totalHandlers += report.handlersChanged;
    final warnings = report.removalsFound +
        report.crossBusFound +
        report.handlerTypeFound +
        report.rxdartFound;
    totalWarnings += warnings;
    if (!report.hasChanges && !report.hasWarnings) continue;
    changedFiles++;
    print('${report.path}:');
    if (report.handlersChanged > 0) {
      print('  setHandler -> subscribeEvents: ${report.handlersChanged}');
    }
    if (report.removalsFound > 0) {
      print('  removeHandler: ${report.removalsFound} — store the subscription and cancel it');
    }
    if (report.crossBusFound > 0) {
      print('  cross-bus handler copy: ${report.crossBusFound} — recreate subscriptions manually');
    }
    if (report.handlerTypeFound > 0) {
      print('  EventBusHandlers: ${report.handlerTypeFound} — use EventSubscription');
    }
    if (report.rxdartFound > 0) {
      print('  rxdart: ${report.rxdartFound} — add it to your own dependencies');
    }
    if (write && report.hasChanges) {
      await file.writeAsString(report.changed);
    }
  }

  print('');
  print('Files touched: $changedFiles, automatic handler rewrites: $totalHandlers, '
      'manual findings: $totalWarnings');
  if (!write && totalHandlers > 0) {
    print('Dry run. Re-run with --write to apply the automatic handler rewrite.');
  }
  if (totalWarnings > 0) {
    print('Review every finding; the script does not rewrite them.');
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
