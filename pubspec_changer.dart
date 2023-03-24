import 'dart:io';

void main(List<String> args) async {
  var r = await Process.run('git', ['describe', '--tags'], runInShell: false);
  var str = r.stdout.toString();
  str = str.replaceAll('\n', '');
  var l = str.split('');
  var result = '';
  //v0.8.0-10-g12160cd
  if (l[0] == 'v') {
    result = str.substring(1);
    result = result.replaceFirst('-', '+');
  }
  // #autoVersion
  File f = File('pubspec.yaml');
  var lStr = f.readAsLinesSync();
  for (var i = 0; i < lStr.length; i++) {
    if (lStr[i].contains('version:')) {
      lStr[i] = 'version: $result';
    }
  }
  //version: 0.8.0+10-g12160cd
  f.writeAsStringSync(lStr.join('\n'));
}
