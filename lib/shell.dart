/// Run programs, or use one as a filter. Thin facade over `dart:io`.
///
/// ```dart
/// final head = (await Shell.run(['git', 'rev-parse', 'HEAD']).text()).trim();
/// if (await Shell.run(['git', 'diff', '--quiet']).code() != 0) print('dirty');
/// await (Fs.file('big.log') | Shell.filter(['grep', 'ERROR']) > Fs.file('errors.log'));
/// ```
///
/// Public surface is exactly: [Shell], [Output].
/// - `Shell.run()` runs a program, `Shell.filter()` makes a process a [Pipe],
///   `Shell.open()` opens a URL or path with the OS.
/// - [Output] supports `code` `ok` `err` (plus [Reader] over stdout).
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'core.dart';
export 'core.dart';

/// Entry point: run a program, make one a filter, or open with the OS.
/// The only OS branch in this facade is which launcher [open]
/// uses; launching itself is per-OS by nature.
abstract final class Shell {
  /// Run [command] directly (no shell), with stdin closed. Waits for the exit
  /// and returns an [Output]. A program that can't start throws
  /// [io.ProcessException]. A non-zero exit is an [Output], never a throw.
  ///
  /// With [live], the child's stdout/stderr tee to ours while it runs (for
  /// build steps a human watches); the output is still captured and returned
  /// as the [Output]. [env] overlays the parent environment; a null value
  /// unsets the variable for the child.
  static Future<Output> run(
    List<String> command, {
    String? dir,
    Map<String, String?>? env,
    bool live = false,
  }) async {
    _checkCommand(command);
    if (live) return _runLive(command, dir: dir, env: env);
    io.ProcessResult r;
    try {
      r = await io.Process.run(
        command[0],
        command.sublist(1),
        workingDirectory: dir,
        environment: _resolveEnv(env),
        includeParentEnvironment: env == null,
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

  /// [run] with `live: true`: `Process.start` plus a stdout/stderr tee.
  static Future<Output> _runLive(
    List<String> command, {
    String? dir,
    Map<String, String?>? env,
  }) async {
    io.Process proc;
    try {
      proc = await io.Process.start(
        command[0],
        command.sublist(1),
        workingDirectory: dir,
        environment: _resolveEnv(env),
        includeParentEnvironment: env == null,
      );
    } on io.ProcessException catch (e) {
      throw io.ProcessException(
        command[0],
        command.sublist(1),
        'cannot start ${command[0]}: ${e.message}',
        e.errorCode,
      );
    }
    try {
      await proc.stdin.close();
    } catch (_) {}
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    Future<void> tee(
        Stream<List<int>> src, BytesBuilder buf, io.IOSink dst) async {
      await for (final chunk in src) {
        buf.add(chunk);
        dst.add(chunk);
      }
    }

    try {
      await Future.wait([
        tee(proc.stdout, out, io.stdout),
        tee(proc.stderr, err, io.stderr),
      ]);
    } catch (_) {
      proc.kill(io.ProcessSignal.sigkill);
      rethrow;
    } finally {
      try {
        await io.stdout.flush();
      } catch (_) {}
      try {
        await io.stderr.flush();
      } catch (_) {}
    }
    final code = await proc.exitCode;
    return Output._(
      code,
      out.takeBytes(),
      utf8.decode(err.takeBytes(), allowMalformed: true),
    );
  }

  /// The child environment: null inherits as-is; otherwise the parent
  /// overlaid with [env], where a null value unsets the variable. (The
  /// `includeParentEnvironment` default already merges, but offers no unset,
  /// so a provided map is resolved exactly and passed with
  /// `includeParentEnvironment: false`.)
  static Map<String, String>? _resolveEnv(Map<String, String?>? env) {
    if (env == null) return null;
    final merged = Map<String, String>.of(io.Platform.environment);
    env.forEach((key, value) {
      if (value == null) {
        merged.remove(key);
      } else {
        merged[key] = value;
      }
    });
    return merged;
  }

  /// A process as a [Pipe]: the stream goes to its stdin, stdout comes out.
  /// stderr is collected; a non-zero exit fails the run with a
  /// [io.ProcessException] carrying the code and stderr. [env] overlays the
  /// parent environment; a null value unsets the variable for the child.
  static Pipe filter(
    List<String> command, {
    String? dir,
    Map<String, String?>? env,
  }) {
    _checkCommand(command);
    return _Filter(command, dir: dir, env: env);
  }

  /// Open [target] (a URL or path) in the default app: `open` on macOS,
  /// `xdg-open` on Linux, `rundll32 url.dll,FileProtocolHandler` on Windows
  /// (no shell parsing, so `&`, `|` and `^` in a URL can't inject commands).
  /// Returns once launched (it does not wait for the app to close). An empty
  /// [target] is an [ArgumentError]; a launcher that cannot start or exits
  /// non-zero throws [io.ProcessException] carrying the first 4 KB of stderr.
  static Future<void> open(String target) async {
    if (target.isEmpty) {
      throw ArgumentError.value(target, 'target', 'must not be empty');
    }
    final List<String> cmd;
    if (io.Platform.isMacOS) {
      cmd = ['open', target];
    } else if (io.Platform.isWindows) {
      cmd = ['rundll32', 'url.dll,FileProtocolHandler', target];
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
      throw io.ProcessException(cmd[0], cmd.sublist(1),
          'cannot open $target: exit $code${err.isEmpty ? '' : ' $err'}',
          code);
    }
  }

  /// A launcher that never started: "not found" (missing `xdg-open` on a
  /// headless box) as opposed to "started but failed".
  static bool _isMissing(io.ProcessException e) {
    if (e.errorCode == 2) return true;
    return e.message.toLowerCase().contains('no such file');
  }

  static void _checkCommand(List<String> command) {
    if (command.isEmpty) {
      throw ArgumentError.value(command, 'command', 'must not be empty');
    }
  }

  static Uint8List _resultBytes(Object? out) {
    if (out is Uint8List) return out;
    if (out is List<int>) return Uint8List.fromList(out);
    if (out is String) return Uint8List.fromList(utf8.encode(out));
    return Uint8List(0);
  }

  static String _resultText(Object? out) {
    if (out is String) return out;
    if (out is List<int>) return utf8.decode(out, allowMalformed: true);
    return '';
  }
}

/// A finished program: a [Reader] of stdout.
final class Output with Reader {
  Output._(this._code, this._out, this._err);

  final int _code;
  final Uint8List _out;
  final String _err;

  /// The exit code. Never throws.
  int code() => _code;

  /// Whether the exit code is 0.
  bool ok() => _code == 0;

  /// Stderr, decoded as UTF-8.
  String err() => _err;

  @override
  Stream<List<int>> stream() => Stream.value(_out.asUnmodifiableView());

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

  /// Stdout as bytes: an unmodifiable view, O(1), no copy.
  @override
  Future<List<int>> bytes() async => _out.asUnmodifiableView();
}

/// Future mirrors (rule 6). The extension name is import-only; never reference it.
extension OutputFuture on Future<Output> {
  Future<int> code() async => (await this).code();
  Future<bool> ok() async => (await this).ok();
  Future<String> err() async => (await this).err();
}

final class _Filter implements Pipe {
  _Filter(this._command, {this._dir, this._env});

  final List<String> _command;
  final String? _dir;
  final Map<String, String?>? _env;

  @override
  void abort(Object error) {
    // Nothing started yet (Reader.to aborts without listening), so
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
        workingDirectory: _dir,
        environment: Shell._resolveEnv(_env),
        includeParentEnvironment: _env == null,
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

  /// EPIPE / broken pipe on the child's stdin: errno 32 (`EPIPE`), 109
  /// (`ERROR_BROKEN_PIPE`) or 232 (`ERROR_NO_DATA`, Windows). Only
  /// Socket/OSError codes count — an upstream `StateError('broken pipe')`
  /// is a real error, not early-close.
  static bool _isEpipe(Object e) {
    if (e is io.SocketException) {
      final code = e.osError?.errorCode;
      return code == 32 || code == 109 || code == 232;
    }
    if (e is io.OSError) {
      final code = e.errorCode;
      return code == 32 || code == 109 || code == 232;
    }
    return false;
  }
}
