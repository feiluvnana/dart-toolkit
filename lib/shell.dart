/// Run programs, or use one as a filter. Thin facade over `dart:io`.
///
/// ```dart
/// final head = (await Shell.run(['git', 'rev-parse', 'HEAD']).text()).trim();
/// if (await Shell.run(['git', 'diff', '--quiet']).exitCode() != 0) print('dirty');
/// await (Fs.file('big.log') | Shell.filter(['grep', 'ERROR']) > Fs.file('errors.log'));
/// ```
///
/// Public surface is exactly: [Shell], [Output].
/// - `Shell.run()` runs a program, `Shell.filter()` makes a process a [Pipe].
/// - [Output] supports `exitCode` `errorText` (plus [Reader] over stdout).
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'core.dart';
export 'core.dart';

/// Entry point: run a program, make one a filter, or open with the OS.
abstract final class Shell {
  /// Run [command] directly (no shell), with stdin closed. Waits for the exit
  /// and returns an [Output]. A program that can't start throws
  /// [io.ProcessException]. A non-zero exit is an [Output], never a throw.
  static Future<Output> run(
    List<String> command, {
    String? workingDir,
    Map<String, String>? env,
  }) async {
    _checkCommand(command);
    io.ProcessResult r;
    try {
      r = await io.Process.run(
        command[0],
        command.sublist(1),
        workingDirectory: workingDir,
        environment:
            env == null ? null : {...io.Platform.environment, ...env},
        stdoutEncoding: null,
        stderrEncoding: null,
      );
    } on io.ProcessException catch (e) {
      throw io.ProcessException(
        command[0],
        command.sublist(1),
        'cannot start ${command[0]}: ${e.message}',
        e.errorCode,
      );
    }
    return Output._(
      r.exitCode,
      _resultBytes(r.stdout),
      _resultText(r.stderr),
    );
  }

  /// A process as a [Pipe]: the stream goes to its stdin, stdout comes out.
  /// stderr is collected; a non-zero exit fails the run with a
  /// [io.ProcessException] carrying the code and stderr.
  static Pipe filter(
    List<String> command, {
    String? workingDir,
    Map<String, String>? env,
  }) {
    _checkCommand(command);
    return _Filter(command, workingDir: workingDir, env: env);
  }

  /// Open [target] (a URL or path) in the default app: `open` on macOS,
  /// `xdg-open` on Linux, `start` on Windows. Returns once launched
  /// (it does not wait for the app to close). An empty [target] is an
  /// [ArgumentError]; a launcher that cannot start or exits non-zero throws
  /// [io.ProcessException].
  static Future<void> open(String target) async {
    if (target.isEmpty) {
      throw ArgumentError.value(target, 'target', 'must not be empty');
    }
    final List<String> cmd;
    if (io.Platform.isMacOS) {
      cmd = ['open', target];
    } else if (io.Platform.isWindows) {
      cmd = ['cmd', '/c', 'start', '', target];
    } else {
      cmd = ['xdg-open', target];
    }
    io.Process proc;
    try {
      proc = await io.Process.start(cmd[0], cmd.sublist(1));
    } on io.ProcessException catch (e) {
      throw io.ProcessException(
        cmd[0],
        cmd.sublist(1),
        'cannot open $target: ${e.message}',
        e.errorCode,
      );
    }
    try {
      await proc.stdin.close();
    } catch (_) {}
    // A launcher should exit quickly (it hands off to the app). Wait briefly
    // so `xdg-open` failures are visible instead of zombieing; the target app
    // itself is not waited on.
    bool exited = false;
    int code = 0;
    try {
      code = await proc.exitCode.timeout(const Duration(seconds: 10));
      exited = true;
    } on TimeoutException {
      // Still running: assumed handed off; leave it (no zombie: outputs
      // drained below, exitCode future kept by the VM until it exits).
    }
    unawaited(proc.stdout.drain<void>().catchError((_) {}));
    unawaited(proc.stderr.drain<void>().catchError((_) {}));
    if (exited && code != 0) {
      String err = '';
      try {
        // Best-effort: stderr was drained above; report the code.
      } catch (_) {}
      throw io.ProcessException(cmd[0], cmd.sublist(1),
          'cannot open $target: exit $code $err', code);
    }
  }

  static void _checkCommand(List<String> command) {
    if (command.isEmpty) {
      throw ArgumentError.value(command, 'command', 'must not be empty');
    }
  }

  static List<int> _resultBytes(Object? out) {
    if (out is List<int>) return out;
    if (out is String) return utf8.encode(out);
    return const [];
  }

  static String _resultText(Object? out) {
    if (out is String) return out;
    if (out is List<int>) return utf8.decode(out, allowMalformed: true);
    return '';
  }
}

/// A finished program: a [Reader] of stdout.
final class Output with Reader {
  Output._(this._exitCode, this._out, this._err);

  final int _exitCode;
  final List<int> _out;
  final String _err;

  /// The exit code. Never throws.
  int exitCode() => _exitCode;

  /// Stderr, decoded as UTF-8.
  String errorText() => _err;

  @override
  Stream<List<int>> stream() => Stream.value(_out);

  /// Stdout as text, dropping ONE trailing newline (`\n` or `\r\n`), as
  /// `$(…)` does in a shell. [bytes]/[stream] stay verbatim.
  @override
  Future<String> text() async {
    var s = utf8.decode(_out, allowMalformed: true);
    if (s.endsWith('\r\n')) {
      s = s.substring(0, s.length - 2);
    } else if (s.endsWith('\n')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  @override
  Future<List<int>> bytes() async => List<int>.from(_out);
}

/// Future mirrors (rule 6). The extension name is import-only; never reference it.
extension OutputFuture on Future<Output> {
  Future<int> exitCode() async => (await this).exitCode();
  Future<String> errorText() async => (await this).errorText();
}

final class _Filter implements Pipe {
  _Filter(this._command, {this._workingDir, this._env});

  final List<String> _command;
  final String? _workingDir;
  final Map<String, String>? _env;

  @override
  void abort(Object error) {
    // Nothing started yet (Reader.writeTo aborts without listening), so
    // there is no child to kill. A mid-run failure tears the generator down
    // via its finally, which already kills the child.
  }

  @override
  Stream<List<int>> transform(Stream<List<int>> input) async* {
    io.Process proc;
    try {
      proc = await io.Process.start(
        _command[0],
        _command.sublist(1),
        workingDirectory: _workingDir,
        environment:
            _env == null ? null : {...io.Platform.environment, ..._env},
      );
    } on io.ProcessException catch (e) {
      throw io.ProcessException(
        _command[0],
        _command.sublist(1),
        'cannot start ${_command[0]}: ${e.message}',
        e.errorCode,
      );
    }
    // A downstream cancel tears this generator down without an error, so
    // track normal completion and kill in the finally: without this the
    // child outlives a failed run.
    var ok = false;
    // Cap stderr (256 KB): the spec wants the full text for the exception,
    // but GBs would OOM; beyond the cap the middle is dropped.
    final stderrBuf = BytesBuilder(copy: false);
    var stderrCapped = false;
    // Drain stderr until the process exits (F12): cancelling when stdout
    // ends would drop late stderr from the exception.
    final stderrDone = () async {
      try {
        await for (final chunk in proc.stderr) {
          if (stderrBuf.length < 262144) {
            stderrBuf.add(chunk);
          } else {
            stderrCapped = true;
          }
        }
      } catch (_) {}
    }();
    Object? inputError;
    StackTrace? inputStack;
    final stdinDone = () async {
      try {
        await proc.stdin.addStream(input);
        await proc.stdin.close();
      } catch (e, st) {
        if (_isEpipe(e)) {
          // The child stopped reading early (head, grep -m): not an error.
          // Stop feeding, cancel the upstream quietly; the exit code
          // decides success.
          try {
            await proc.stdin.close();
          } catch (_) {}
          return;
        }
        inputError = e;
        inputStack = st;
        try {
          await proc.stdin.close();
        } catch (_) {}
        proc.kill(io.ProcessSignal.sigkill);
      }
    }();
    try {
      await for (final chunk in proc.stdout) {
        yield chunk;
      }
      ok = true;
    } catch (_) {
      proc.kill(io.ProcessSignal.sigkill);
      rethrow;
    } finally {
      if (!ok) proc.kill(io.ProcessSignal.sigkill);
      try {
        await proc.stdin.close();
      } catch (_) {}
      try {
        await stdinDone.timeout(const Duration(seconds: 2));
      } catch (_) {
        proc.kill(io.ProcessSignal.sigkill);
      }
      // On the cancel path (!ok) don't block tearing down on stderr;
      // the late-stderr drain below still runs on the success path.
      if (!ok) {
        try {
          await stderrDone.timeout(const Duration(seconds: 2));
        } catch (_) {}
        try {
          await proc.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    }
    if (inputError != null) {
      // The upstream failed: don't mask it behind the exit code. Drain
      // stderr best-effort so the child cannot linger, then rethrow.
      try {
        await stderrDone.timeout(const Duration(seconds: 2));
      } catch (_) {}
      try {
        await proc.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
      await Future<void>.error(inputError!, inputStack);
    }
    final code = await proc.exitCode;
    try {
      await stderrDone;
    } catch (_) {}
    if (code != 0) {
      final err = utf8.decode(stderrBuf.takeBytes(), allowMalformed: true);
      throw io.ProcessException(
        _command[0],
        _command.sublist(1),
        'exit $code: $err${stderrCapped ? '…[stderr truncated at 256 KB]' : ''}',
        code,
      );
    }
  }

  /// EPIPE / broken pipe on the child's stdin: SocketException errno 32,
  /// or an OSError naming the broken pipe. Only Socket/OSError counts —
  /// an upstream `StateError('broken pipe')` is a real error, not early-close.
  static bool _isEpipe(Object e) {
    if (e is io.SocketException) {
      final code = e.osError?.errorCode;
      if (code == 32 || code == 109) return true;
      final m = e.message.toLowerCase();
      if (m.contains('broken pipe') ||
          m.contains('epipe') ||
          m.contains('pipe has been ended') ||
          m.contains('pipe is being closed')) {
        return true;
      }
      final os = e.osError?.message.toLowerCase() ?? '';
      if (os.contains('broken pipe') ||
          os.contains('epipe') ||
          os.contains('pipe has been ended') ||
          os.contains('pipe is being closed')) {
        return true;
      }
      return false;
    }
    if (e is io.OSError) {
      if (e.errorCode == 32 || e.errorCode == 109) return true;
      final m = e.message.toLowerCase();
      if (m.contains('broken pipe') ||
          m.contains('epipe') ||
          m.contains('pipe has been ended') ||
          m.contains('pipe is being closed')) {
        return true;
      }
      return false;
    }
    return false;
  }
}
