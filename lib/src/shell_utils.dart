/// [ShellUtils] (exported by `utils`): find an installed program, open a
/// URL or path with the OS. Kept apart from `shell`, whose job is running
/// programs.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'which.dart' as paths;

/// Helpers beside `Shell`: [which] finds an installed program, [open] hands
/// a URL or path to the OS.
abstract final class ShellUtils {
  /// Where [program] resolves on `PATH` (with `PATHEXT` on Windows), or
  /// null when it is not installed. Starts no process. A name with a path
  /// separator is checked as that path.
  static Future<String?> which(String program) => paths.which([program]);

  /// Open [target] (a URL or path) in the default app: `open` on macOS,
  /// `xdg-open` on Linux, `rundll32 url.dll,FileProtocolHandler` on Windows
  /// (no shell parsing, so `&`, `|` and `^` in a URL can't inject commands).
  /// Returns once launched (it does not wait for the app to close). An empty
  /// [target] is an [ArgumentError]; a launcher that cannot start or exits
  /// non-zero throws [io.ProcessException] carrying the first 4 KB of stderr.
  /// A [target] starting with `-` opens as the path `./-…`, never an option.
  /// Any scheme the OS knows opens (`file:`, app links): check a target that
  /// comes from untrusted text first.
  static Future<void> open(String target) async {
    if (target.isEmpty) {
      throw ArgumentError.value(target, 'target', 'must not be empty');
    }
    // A leading '-' would be read as a launcher option (`open -a App`);
    // no URL starts with one, so it is a relative path. xdg-open has no `--`.
    if (target.startsWith('-')) target = './$target';
    final List<String> cmd;
    if (io.Platform.isMacOS) {
      cmd = ['open', target];
    } else if (io.Platform.isWindows) {
      final sysRoot = io.Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final String winTarget;
      final uri = Uri.tryParse(target);
      if (uri != null && uri.hasScheme && uri.scheme.length > 1) {
        winTarget = Uri.encodeFull(target);
      } else {
        winTarget = Uri.file(io.File(target).absolute.path).toString();
      }
      cmd = ['$sysRoot\\System32\\rundll32.exe', 'url.dll,FileProtocolHandler', winTarget];
    } else {
      cmd = ['xdg-open', target];
    }
    io.Process proc;
    try {
      proc = await io.Process.start(cmd[0], cmd.sublist(1));
    } on io.ProcessException catch (e) {
      if (cmd[0] == 'xdg-open' && _isMissing(e)) {
        throw io.ProcessException(
          cmd[0],
          cmd.sublist(1),
          'cannot open $target: xdg-open is not installed '
          '(install the xdg-utils package)',
          e.errorCode,
        );
      }
      throw io.ProcessException(cmd[0], cmd.sublist(1), 'cannot open $target: ${e.message}', e.errorCode);
    }
    try {
      await proc.stdin.close();
    } catch (_) {}
    // A launcher should exit quickly (it hands off to the app). Wait briefly
    // so `xdg-open` failures are visible instead of zombieing; the target app
    // itself is not waited on.
    // Subscriptions, not drains: a launcher that hands its stdio to the app
    // it starts must not keep this script alive until that app exits.
    final outSub = proc.stdout.listen(null, onError: (_) {});
    // Keep the first 4 KB of stderr for the exception below; keep reading
    // past the cap so a chatty launcher can never block on a full pipe.
    final errBuf = BytesBuilder(copy: false);
    final errDone = Completer<void>();
    final errSub = proc.stderr.listen(
      (chunk) {
        final room = 4096 - errBuf.length;
        if (room > 0) errBuf.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
      },
      onError: (_) {},
      onDone: errDone.complete,
    );
    bool exited = false;
    int code = 0;
    try {
      code = await proc.exitCode.timeout(const Duration(seconds: 10));
      exited = true;
    } on TimeoutException {
      // Still running: assumed handed off; leave it.
    }
    if (exited && code != 0) {
      // A failing launcher's message is worth a short wait.
      try {
        await errDone.future.timeout(const Duration(milliseconds: 500));
      } catch (_) {}
    }
    await outSub.cancel();
    await errSub.cancel();
    if (exited && code != 0) {
      final err = utf8.decode(errBuf.takeBytes(), allowMalformed: true);
      throw io.ProcessException(
        cmd[0],
        cmd.sublist(1),
        'cannot open $target: exit $code${err.isEmpty ? '' : ' $err'}',
        code,
      );
    }
  }

  /// A launcher that never started: "not found" (missing `xdg-open` on a
  /// headless box) as opposed to "started but failed".
  static bool _isMissing(io.ProcessException e) {
    if (e.errorCode == 2) return true;
    return e.message.toLowerCase().contains('no such file');
  }
}
