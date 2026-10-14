import 'dart:io';

import 'package:test/test.dart';

/// Run [body] as `main` of a child Dart script whose working directory is
/// [dir]. The working directory is per process, so a test that needs one
/// must not change it under the other suites. [body] throws to fail.
Future<void> runInDir(String dir, String imports, String body) async {
  final script = File('${Directory(dir).parent.path}/_in_dir_${dir.hashCode}.dart')
    ..writeAsStringSync('$imports\nFuture<void> main() async {\n$body\n}\n');
  final r = await Process.run(
    Platform.resolvedExecutable,
    ['--packages=${Directory.current.path}/.dart_tool/package_config.json', script.path],
    workingDirectory: dir,
  );
  expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
}
