/// Run programs, read one as it prints, or use one as a filter. Thin
/// facade over `dart:io`.
///
/// ```dart
/// final head = await Shell.run(['git', 'rev-parse', 'HEAD']).check().text();
/// if (!await Shell.run(['git', 'diff', '--quiet']).ok()) print('dirty');
/// await (Shell.run(['make', '-j8']) & Console.bar('build'));            // a spinner
/// await (Fs.file('big.log') | Shell.filter(['grep', 'ERROR']) > Fs.file('errors.log'));
/// await (Shell.read(['make']) > Console.out());                         // live
/// await Shell.run(['git', 'commit'], terminal: true).check();           // our tty
/// await for (final line in Shell.read(['yt-dlp', url]).lines()) { … }
/// ```
///
/// Public surface is exactly: [Shell], [Output], [ExitException].
/// - `Shell.run()` runs a program to the end (a [Task] of its [Output]),
///   `Shell.read()` reads one's stdout as it prints, `Shell.filter()` makes
///   a process a [Pipe]. Finding an installed program and opening a URL
///   with the OS are `ShellUtils.which`/`open` in `utils`.
/// - [Output] supports `code` `ok` `err` `check` (plus [Reader] over stdout).
/// - [ExitException]: a program that ran and exited non-zero (`check()`, a
///   read, a filter); a program that cannot start is a plain `ProcessException`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'core.dart';

import 'src/exit.dart' as exit;
import 'src/names.dart' as names;
import 'src/progress.dart' show task;
import 'src/quiet.dart';
import 'src/time.dart' show SpanUtils;
import 'src/timeout.dart';
export 'core.dart';

/// A program that ran and exited non-zero: [errorCode] is its exit code and
/// [message] ends with the last 64 KB of its stderr. A [io.ProcessException],
/// so an existing `on ProcessException` keeps catching it; one that cannot
/// start stays a plain [io.ProcessException].
final class ExitException extends io.ProcessException implements ToolkitException {
  /// [executable] ran with [arguments] and exited with [errorCode].
  ExitException(super.executable, super.arguments, super.message, super.errorCode);

  @override
  Object? get cause => null;
}

/// Entry point: run a program, read one as it prints, or make one a filter.
abstract final class Shell {
  /// Run [command] directly (no shell), with stdin closed, to its exit: a
  /// [Task] of its [Output] (watch it with `& Console.bar('build')`). A
  /// program that can't start throws [io.ProcessException]. A non-zero
  /// exit is an [Output], never a throw: `.check()` makes it one. Ctrl-C
  /// kills the tree and throws [InterruptedException], as does a child
  /// that died of the Ctrl-C of a terminal we share.
  ///
  /// [env] overlays the parent environment; a null value unsets the
  /// variable for the child. With [timeout] a run that takes longer is
  /// killed with everything it started and throws [TimeoutException]
  /// naming the command. When [cancel] completes first (with a value or an
  /// error), the program and everything it started are killed and the run
  /// returns what was captured, as an [Output] with the kill's exit code
  /// (`-9` on POSIX): the caller asked, so nothing throws.
  ///
  /// With [terminal] the program gets our terminal (stdin, stdout and
  /// stderr: `git commit` opens `$EDITOR`, `ssh` asks for a password,
  /// tools print in colour) and its [Output] has an empty text and stderr,
  /// only the exit code; [timeout], [cancel] and the kill of its tree on
  /// Ctrl-C work as without it.
  ///
  /// To see the output while it runs, read it instead: `Shell.read`.
  static Task<Output> run(
    List<String> command, {
    String? dir,
    Map<String, String?>? env,
    Duration? timeout,
    Future<void>? cancel,
    bool terminal = false,
  }) {
    _checkCommand(command);
    // Listened to now, before the task starts: an error-completed cancel
    // is a cancel, never an unhandled error.
    final cancelled = cancel?.then((_) {}, onError: (Object _) {});
    return task((_) => _run(command, dir, env, timeout, cancelled, terminal));
  }

  static Future<Output> _run(
    List<String> command,
    String? dir,
    Map<String, String?>? env,
    Duration? timeout,
    Future<void>? cancelled,
    bool terminal,
  ) async {
    if (exit.interrupted) throw const InterruptedException();
    _checkBatchArgs(command[0], command.sublist(1));
    io.Process proc;
    try {
      proc = await io.Process.start(
        command[0],
        command.sublist(1),
        workingDirectory: dir,
        environment: _resolveEnv(env),
        includeParentEnvironment: env == null,
        mode: terminal ? io.ProcessStartMode.inheritStdio : io.ProcessStartMode.normal,
      );
    } on io.ProcessException catch (e) {
      throw io.ProcessException(
        command[0],
        command.sublist(1),
        'cannot start ${command[0]}: ${e.message}',
        e.errorCode,
      );
    }
    _watch(proc);
    // A SIGINT/SIGTERM/SIGHUP that ends this script ends the child and
    // its descendants too, instead of leaving them orphaned under init.
    final token = exit.onExit(() => _killTree(proc, io.ProcessSignal.sigterm));
    // Ctrl-C fails the run (the tree is killed below), so `finally` runs.
    final ctrlC = Completer<void>();
    final stopToken = exit.onInterrupt(ctrlC.complete);
    if (exit.interrupted) ctrlC.complete(); // during the start
    var exited = false;
    unawaited(proc.exitCode.then((_) => exited = true));
    try {
      if (!terminal) {
        try {
          await proc.stdin.close();
        } catch (_) {}
      }
      final out = BytesBuilder(copy: false);
      final err = BytesBuilder(copy: false);
      // Subscriptions, not `await for`: a timeout cancels them, so a
      // descendant that still holds the pipes cannot keep the VM alive.
      final subs = <StreamSubscription<List<int>>>[];
      try {
        // On our terminal there are no pipes: the exit is the end.
        final work = terminal
            ? proc.exitCode
            : Future.wait([
                _collect(proc.stdout, out, subs),
                _collect(proc.stderr, err, subs),
                proc.exitCode,
              ], eagerError: true);
        // A cancel kills the tree, then lets the pipes drain briefly: a
        // descendant that escaped the tree must not hold the run open.
        Future<void> stop(Future<void> cancelled) async {
          await cancelled;
          if (!exited) {
            await _killTree(proc, io.ProcessSignal.sigkill);
            await proc.exitCode;
          }
          try {
            await work.timeout(const Duration(milliseconds: 200));
          } catch (_) {
            for (final sub in subs) {
              await sub.cancel();
            }
          }
        }

        final halted = ctrlC.future.then<void>((_) => throw const InterruptedException())..ignore();
        final ended = Future.any<void>([work, halted, if (cancelled != null) stop(cancelled)]);
        if (timeout == null) {
          await ended;
        } else {
          await ended.timeout(
            timeout,
            onTimeout: () async {
              await _killTree(proc, io.ProcessSignal.sigkill);
              for (final sub in subs) {
                await sub.cancel();
              }
              throw Timeout('${_shown(command).join(' ')} ran over ${timeout.human()}', timeout);
            },
          );
        }
      } catch (_) {
        await _killTree(proc, io.ProcessSignal.sigkill);
        for (final sub in subs) {
          unawaited(sub.cancel());
        }
        rethrow;
      }
      final code = await proc.exitCode;
      if (_diedOfCtrlC(code)) throw const InterruptedException();
      final stderr = utf8.decode(err.takeBytes(), allowMalformed: true);
      return Output._(command, code, out.takeBytes(), stderr);
    } finally {
      exit.offInterrupt(stopToken);
      exit.offExit(token);
    }
  }

  /// The child environment: null inherits as-is; otherwise the parent
  /// overlaid with [env], where a null value unsets the variable. (The
  /// `includeParentEnvironment` default already merges, but offers no unset,
  /// so a provided map is resolved exactly and passed with
  /// `includeParentEnvironment: false`.)
  static Map<String, String>? _resolveEnv(Map<String, String?>? env) {
    if (env == null) return null;
    final merged = Map<String, String>.of(io.Platform.environment);
    final windows = io.Platform.isWindows;
    env.forEach((key, value) {
      if (windows) {
        final upper = key.toUpperCase();
        merged.removeWhere((k, _) => k.toUpperCase() == upper);
      } else {
        merged.remove(key);
      }
      if (value != null) {
        merged[key] = value;
      }
    });
    return merged;
  }

  /// [command]'s stdout as it prints: a [Reader], so it flows
  /// (`Shell.read(cmd) > Console.out()`) and reads (`.lines()`) like any
  /// other. Nothing starts until it is read. Its stderr passes through to
  /// ours, as in a shell pipeline; a non-zero exit fails the read with an
  /// [ExitException] carrying the last 64 KB of it. Stdin is closed.
  static Reader read(List<String> command, {String? dir, Map<String, String?>? env}) {
    _checkCommand(command);
    return _Program(command, dir, env);
  }

  /// A process as a [Pipe]: the stream goes to its stdin, stdout comes out.
  /// stderr is collected; a non-zero exit fails the run with an
  /// [ExitException] carrying the code and stderr. [env] overlays the
  /// parent environment; a null value unsets the variable for the child.
  static Pipe filter(List<String> command, {String? dir, Map<String, String?>? env}) {
    _checkCommand(command);
    return _Filter(command, dir: dir, env: env);
  }

  static void _checkCommand(List<String> command) {
    if (command.isEmpty) {
      throw ArgumentError.value(command, 'command', 'must not be empty');
    }
  }
}

/// A finished program: a [Reader] of stdout.
final class Output with Reader {
  Output._(this._command, this._code, this._out, this._err);

  final List<String> _command;
  final int _code;
  final Uint8List _out;
  final String _err;

  /// The exit code. Never throws.
  int code() => _code;

  /// Whether the exit code is 0.
  bool ok() => _code == 0;

  /// Stderr, decoded as UTF-8.
  String err() => _err;

  /// This output when the exit code is 0; otherwise throws [ExitException]
  /// with the code and the last 64 KB of stderr (as `Response.check()`
  /// does for a non-2xx answer).
  Output check() {
    if (_code == 0) return this;
    throw ExitException(_command[0], _shown(_command).sublist(1), 'exit $_code: ${_tail(_err).trim()}', _code);
  }

  @override
  Origin origin() => Origin(size: _out.length);

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

/// Future mirrors (rule 4). The extension name is import-only; never reference it.
extension OutputFuture on Future<Output> {
  Future<int> code() async => (await this).code();
  Future<bool> ok() async => (await this).ok();
  Future<String> err() async => (await this).err();
  Future<Output> check() async => (await this).check();
}

/// Gather [src] into [buf]; the subscription joins [subs] so a timeout or
/// cancel can drop it. Completes when [src] ends; fails with its error.
Future<void> _collect(Stream<List<int>> src, BytesBuilder buf, List<StreamSubscription<List<int>>> subs) {
  final done = Completer<void>();
  subs.add(src.listen(buf.add, onError: done.completeError, onDone: done.complete, cancelOnError: true));
  return done.future;
}

/// `Shell.read`: a program as a source, run when read; its stderr shows
/// unless the toolkit marked the reader [quiet].
final class _Program with Reader {
  _Program(this._command, this._dir, this._env);

  final List<String> _command;
  final String? _dir;
  final Map<String, String?>? _env;

  @override
  Stream<List<int>> stream() =>
      _Filter(_command, dir: _dir, env: _env, showErr: !(quiet[this] ?? false)).transform(const Stream.empty());
}

/// A child that died of `SIGINT` while we share its terminal took the
/// terminal's Ctrl-C, which may reach our watcher only after the run ended:
/// interrupt the script now, as the signal would.
bool _diedOfCtrlC(int code) {
  // On POSIX, SIGINT exit is -2; on Windows, STATUS_CONTROL_C_EXIT is -1073741510 (0xC000013A).
  final match = io.Platform.isWindows ? code == -1073741510 : code == -2;
  if (!match || !exit.onTerminal) return false;
  exit.interrupt();
  return true;
}

void _checkBatchArgs(String exe, List<String> args) {
  if (!io.Platform.isWindows) return;
  final lower = exe.toLowerCase();
  if (lower.endsWith('.bat') || lower.endsWith('.cmd')) {
    final bad = RegExp(r'["&|<>\^%!\r\n]');
    for (final a in args) {
      if (bad.hasMatch(a)) {
        throw ArgumentError('argument "$a" contains unsafe shell characters for batch script $exe');
      }
    }
  }
}

/// Which started processes have exited (and been reaped), for [_killTree].
final _reaped = Expando<bool>();

void _watch(io.Process proc) => unawaited(proc.exitCode.then((_) => _reaped[proc] = true));

/// Signal [proc] and every process below it, deepest first, so a `sh -c`
/// or a build tool cannot leave grandchildren running under init. The tree
/// is read before anything dies (an orphan loses its parent link). On Windows,
/// taskkill /F /T terminates the whole process tree.
Future<void> _killTree(io.Process proc, io.ProcessSignal signal) async {
  // Once reaped, its pid may belong to someone else: never signal it then.
  if (_reaped[proc] ?? false) return;
  if (io.Platform.isWindows) {
    try {
      await io.Process.run('taskkill', ['/F', '/T', '/PID', '${proc.pid}']);
    } catch (_) {
      proc.kill(signal);
    }
    return;
  }
  final below = <int>[];
  try {
    final ps = await io.Process.run('ps', ['-A', '-o', 'pid=,ppid=']);
    final kids = <int, List<int>>{};
    for (final line in (ps.stdout as String).split('\n')) {
      final f = line.trim().split(RegExp(r'\s+'));
      if (f.length != 2) continue;
      final pid = int.tryParse(f[0]), parent = int.tryParse(f[1]);
      if (pid != null && parent != null) (kids[parent] ??= []).add(pid);
    }
    void walk(int pid) {
      for (final k in kids[pid] ?? const <int>[]) {
        walk(k);
        below.add(k);
      }
    }

    walk(proc.pid);
  } catch (_) {}
  for (final pid in below) {
    if (pid > 1 && pid != io.pid) io.Process.killPid(pid, signal);
  }
  proc.kill(signal);
}

final class _Filter implements Pipe {
  _Filter(this._command, {this._dir, this._env, this._showErr = false});

  final List<String> _command;
  final String? _dir;
  final Map<String, String?>? _env;

  /// Pass stderr through to ours as it arrives (`Shell.read`); it is kept
  /// for the error either way.
  final bool _showErr;

  @override
  void abort(Object error) {
    // Nothing started yet (`Reader >` aborts without listening), so
    // there is no child to kill. A mid-run failure tears the generator down
    // via its finally, which already kills the child.
  }

  /// Guarded: Ctrl-C fails the read, and the cancel kills the child.
  @override
  Stream<List<int>> transform(Stream<List<int>> input) => exit.guard(_transform(input), outside: true);

  Stream<List<int>> _transform(Stream<List<int>> input) async* {
    _checkBatchArgs(_command[0], _command.sublist(1));
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
    _watch(proc);
    // A signal that ends this script ends the child too; the hook goes
    // when the child exits.
    final token = exit.onExit(() => _killTree(proc, io.ProcessSignal.sigterm));
    unawaited(proc.exitCode.then((_) => exit.offExit(token)));
    // A downstream cancel tears this generator down without an error, so
    // track normal completion and kill in the finally: without this the
    // child outlives a failed run.
    var ok = false;
    // Only the last 64 KB of stderr is kept for the exception: errors come
    // last, and GBs would OOM. Compacted whenever it doubles.
    var stderrBuf = BytesBuilder(copy: false);
    // Drain stderr until the process exits: cancelling when stdout
    // ends would drop late stderr from the exception.
    final stderrDone = () async {
      try {
        await for (final chunk in proc.stderr) {
          if (_showErr) io.stderr.add(chunk);
          stderrBuf.add(chunk);
          if (stderrBuf.length > 2 * _errCap) {
            final all = stderrBuf.takeBytes();
            stderrBuf = BytesBuilder(copy: false)..add(Uint8List.sublistView(all, all.length - _errCap));
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
      await _killTree(proc, io.ProcessSignal.sigkill);
      rethrow;
    } finally {
      if (!ok) await _killTree(proc, io.ProcessSignal.sigkill);
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
      Error.throwWithStackTrace(inputError!, inputStack ?? StackTrace.current);
    }
    final code = await proc.exitCode;
    try {
      await stderrDone;
    } catch (_) {}
    if (code != 0) {
      if (_diedOfCtrlC(code)) throw const InterruptedException();
      final err = utf8.decode(stderrBuf.takeBytes(), allowMalformed: true);
      throw ExitException(_command[0], _shown(_command).sublist(1), 'exit $code: ${_tail(err)}', code);
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

/// How much stderr a failure message keeps: the last 64 KB.
const _errCap = 65536;

/// The last [_errCap] characters of [err], from a line start, led by `…`
/// when cut: a chatty failing tool must not put megabytes in a message.
String _tail(String err) {
  if (err.length <= _errCap) return err;
  var from = err.length - _errCap;
  final nl = err.indexOf('\n', from);
  if (nl != -1 && nl + 1 < err.length) from = nl + 1;
  return '…${err.substring(from)}';
}

/// [args] fit for an error message: URL credentials and token values,
/// secret header values (`-H 'Authorization: …'`) and secret options
/// (`--token=…`, `--password …`) shown as `***`.
List<String> _shown(List<String> command) {
  // 7-Zip takes its password stuck to the flag: `-pSECRET`.
  final sevenZip = command.isNotEmpty && _sevenZip.hasMatch(command.first);
  return [
    for (var i = 0; i < command.length; i++)
      if (i > 0 && (command[i - 1] == '-H' || command[i - 1] == '--header'))
        _header(command[i])
      else if (i > 0 && _secretFlag.hasMatch(command[i - 1]) && !command[i - 1].contains('='))
        '***'
      else if (sevenZip && i > 0 && command[i].length > 2 && command[i].startsWith('-p'))
        '-p***'
      else
        _arg(command[i]),
  ];
}

final _sevenZip = RegExp(r'(^|[/\\])7z[a-z]?(\.exe)?$', caseSensitive: false);

String _arg(String a) {
  final flag = _secretFlag.firstMatch(a);
  if (flag != null && a.contains('=')) return '${a.substring(0, a.indexOf('='))}=***';
  if (a.startsWith('-H') && a.length > 2) return '-H${_header(a.substring(2))}';
  return a.contains('://') ? names.redact(a) : a;
}

String _header(String h) {
  final colon = h.indexOf(':');
  if (colon < 0) return h;
  final name = h.substring(0, colon).trim().toLowerCase();
  final secret =
      name == 'authorization' ||
      name == 'proxy-authorization' ||
      name == 'cookie' ||
      name.contains('token') ||
      name.contains('api-key') ||
      name.contains('secret');
  return secret ? '${h.substring(0, colon)}: ***' : h;
}

final _secretFlag = RegExp(r'^--?(token|password|passwd|secret|api-?key|access-?key|auth)(=|$)', caseSensitive: false);
