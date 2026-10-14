import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Run [source] as a child Dart script with this package's dependencies,
/// for tests that check a process exits, owns its stdio or needs its own
/// working directory. The script lives in a fresh temp dir (never the repo);
/// [cwd] defaults to that dir. A child still running after [timeout] is
/// killed and reports exit code -1.
Future<ProcessResult> runDart(
  String source, {
  List<String> args = const [],
  String? cwd,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final dir = await Directory.systemTemp.createTemp('child');
  addTearDown(() => dir.delete(recursive: true));
  final script = File('${dir.path}/main.dart');
  await script.writeAsString(source);
  final p = await Process.start(
    Platform.resolvedExecutable,
    ['--packages=${Directory.current.path}/.dart_tool/package_config.json', script.path, ...args],
    workingDirectory: cwd ?? dir.path,
  );
  final out = p.stdout.transform(utf8.decoder).join();
  final err = p.stderr.transform(utf8.decoder).join();
  final code = await p.exitCode.timeout(timeout, onTimeout: () {
    p.kill(ProcessSignal.sigkill);
    return -1;
  });
  return ProcessResult(p.pid, code, await out, await err);
}

/// Run [body] as `main` of a child script whose working directory is [dir].
/// The working directory is per process, so a test that needs one must not
/// change it under the other suites. [body] throws to fail.
Future<void> runInDir(String dir, String imports, String body) async {
  final r = await runDart('$imports\nFuture<void> main() async {\n$body\n}\n', cwd: dir);
  expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
}
