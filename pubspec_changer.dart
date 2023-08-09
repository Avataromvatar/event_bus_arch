import 'dart:io';

void main(List<String> args) async {
  if (args.isNotEmpty) {
    if (args[0] == 'v') {
      var result = await getVersion();
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
    } else if (args[0] == 'c' && args.length >= 2) {
      var result = await getVersion();
      // #auto CHANGELOG
      File cf = File('CHANGELOG.md');
      var lStr1 = cf.readAsLinesSync();
      List<String> changeList = [];
      if (args.isNotEmpty) {
        changeList.add('## $result  ');
        changeList.add('-  ${args[1]}  ');
      }
      changeList.addAll(lStr1);
      cf.writeAsStringSync(changeList.join('\n'));
    } else {
      print(
          'Please use first arg "c" or "v" \n"c" - CHANGELOG.md add new version and args[1]!\n"v" - change version in pubspec ');
    }
  }
}

Future<String> getVersion() async {
  var r = await Process.run('git', ['describe', '--tags'], runInShell: false);
  var str = r.stdout.toString();
  str = str.replaceAll('\n', '');
  var l = str.split('');
  var result = '';
  //v0.8.0-10-g12160cd
  if (l[0] == 'v') {
    result = str.substring(1);
    result = result.replaceFirst('-', '+');
    // result = result.substring(0, result.indexOf('-'));
  }
  return result;
}
