import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Why a pty test cannot run here (Windows, or no python3 for the pty
/// driver), or null: pass it as a group's `skip:`.
final String? noPty = Platform.isWindows
    ? 'needs a POSIX pty'
    : _python()
    ? null
    : 'needs python3 for the pty driver';

bool _python() {
  try {
    return Process.runSync('python3', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Run [source] as a child Dart script with this package's dependencies,
/// for tests that check a process exits, owns its stdio or needs its own
/// working directory. The script lives in a fresh temp dir (never the repo);
/// [cwd] defaults to that dir. A child still running after [timeout] is
/// killed and reports exit code -1. [stdin] is written piece by piece, each
/// after its delay, then closed.
Future<ProcessResult> runDart(
  String source, {
  List<String> args = const [],
  List<(Duration, String)> stdin = const [],
  String? cwd,
  Map<String, String>? env,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final p = await startDart(source, args: args, cwd: cwd, env: env);
  unawaited(
    () async {
      for (final (delay, text) in stdin) {
        await Future<void>.delayed(delay);
        p.stdin.write(text);
      }
      await p.stdin.close();
    }().catchError((_) {}),
  );
  final out = p.stdout.transform(utf8.decoder).join();
  final err = p.stderr.transform(utf8.decoder).join();
  final code = await p.exitCode.timeout(
    timeout,
    onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  return ProcessResult(p.pid, code, await out, await err);
}

/// Start [source] as a child Dart script (see [runDart]) and return the
/// process, for tests that talk to it while it runs. Wait for a line it
/// prints, never a fixed delay, before acting on it.
Future<Process> startDart(String source, {List<String> args = const [], String? cwd, Map<String, String>? env}) async {
  final dir = await Directory.systemTemp.createTemp('child');
  addTearDown(() => dir.delete(recursive: true));
  final script = File('${dir.path}/main.dart');
  await script.writeAsString(source);
  return Process.start(
    Platform.resolvedExecutable,
    ['--packages=${Directory.current.path}/.dart_tool/package_config.json', script.path, ...args],
    workingDirectory: cwd ?? dir.path,
    environment: env,
  );
}

/// The lines [p] prints on stdout, for waiting on one with `firstWhere`.
Stream<String> linesOf(Process p) => p.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();

/// Run [body] as `main` of a child script whose working directory is [dir].
/// The working directory is per process, so a test that needs one must not
/// change it under the other suites. [body] throws to fail.
Future<void> runInDir(String dir, String imports, String body) async {
  final r = await runDart('$imports\nFuture<void> main() async {\n$body\n}\n', cwd: dir);
  expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
}
