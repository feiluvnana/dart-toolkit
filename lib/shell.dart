/// Run programs, or use one as a filter. Thin facade over `dart:io`.
///
/// ```dart
/// final head = await Shell.run(['git', 'rev-parse', 'HEAD'], check: true).text();
/// if (!await Shell.run(['git', 'diff', '--quiet']).ok()) print('dirty');
/// await (Fs.file('big.log') | Shell.filter(['grep', 'ERROR']) > Fs.file('errors.log'));
/// // A long-running program, line by line as it prints:
/// await for (final line in (Reader.of(const []) | Shell.filter(['yt-dlp', url])).lines()) { … }
/// ```
///
/// Public surface is exactly: [Shell], [Output].
/// - `Shell.run()` runs a program, `Shell.filter()` makes a process a [Pipe],
///   `Shell.open()` opens a URL or path with the OS, `Shell.which()` finds an
///   installed program.
/// - [Output] supports `code` `ok` `err` (plus [Reader] over stdout).
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'core.dart';

import 'src/exit.dart' as exit;
import 'src/names.dart' as names;
import 'src/timeout.dart';
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
  /// unsets the variable for the child. [onLine] gets each line of stdout
  /// and stderr as it arrives (a dashboard pane, a log), and the [Output]
  /// still holds both. With [check] a non-zero exit throws
  /// [io.ProcessException] carrying the exit code and the last 64 KB of
  /// stderr (as `check:` does for a non-2xx response). With [timeout] a
  /// run that takes longer is killed with everything it started and throws
  /// [TimeoutException] naming the command. When [cancel] completes first
  /// (with a value or an error), the program and everything it started are
  /// killed and the run returns what was captured, as an [Output] with the
  /// kill's exit code (`-9` on POSIX): the caller asked, so nothing throws
  /// unless [check] does.
  static Future<Output> run(
    List<String> command, {
    String? dir,
    Map<String, String?>? env,
    bool live = false,
    bool check = false,
    Duration? timeout,
    Future<void>? cancel,
    void Function(String line)? onLine,
  }) async {
    _checkCommand(command);
    // Listened to before the first await, so an error-completed cancel is
    // a cancel, never an unhandled error.
    final cancelled = cancel?.then((_) {}, onError: (Object _) {});
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
    _watch(proc);
    // A SIGINT/SIGTERM/SIGHUP that ends this script ends the child and
    // its descendants too, instead of leaving them orphaned under init.
    final token = exit.onExit(() => _killTree(proc, io.ProcessSignal.sigterm));
    var exited = false;
    unawaited(proc.exitCode.then((_) => exited = true));
    try {
      try {
        await proc.stdin.close();
      } catch (_) {}
      final out = BytesBuilder(copy: false);
      final err = BytesBuilder(copy: false);
      // With [live] each chunk also tees to our stdout/stderr.
      // Subscriptions, not `await for`: a timeout cancels them, so a
      // descendant that still holds the pipes cannot keep the VM alive.
      final subs = <StreamSubscription<List<int>>>[];
      Future<void> collect(Stream<List<int>> src, BytesBuilder buf, io.IOSink? tee) {
        final lines = onLine == null
            ? null
            : const Utf8Decoder(allowMalformed: true)
                  .startChunkedConversion(const LineSplitter().startChunkedConversion(_LineSink(onLine)));
        final done = Completer<void>();
        late final StreamSubscription<List<int>> sub;
        subs.add(
          sub = src.listen(
            (chunk) {
              buf.add(chunk);
              tee?.add(chunk);
              try {
                lines?.add(chunk);
              } catch (e, st) {
                // [onLine] threw: the run fails with its error (the tree is
                // killed below), never an uncaught error in this listener.
                unawaited(sub.cancel());
                if (!done.isCompleted) done.completeError(e, st);
              }
            },
            onError: done.completeError,
            onDone: () {
              lines?.close();
              done.complete();
            },
            cancelOnError: true,
          ),
        );
        return done.future;
      }

      try {
        final work = Future.wait([
          collect(proc.stdout, out, live ? io.stdout : null),
          collect(proc.stderr, err, live ? io.stderr : null),
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

        final ended = Future.any<void>([work, if (cancelled != null) stop(cancelled)]);
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
        rethrow;
      } finally {
        if (live) {
          try {
            await io.stdout.flush();
          } catch (_) {}
          try {
            await io.stderr.flush();
          } catch (_) {}
        }
      }
      final code = await proc.exitCode;
      final stderr = utf8.decode(err.takeBytes(), allowMalformed: true);
      if (check && code != 0) {
        throw io.ProcessException(command[0], _shown(command.sublist(1)), 'exit $code: ${_tail(stderr).trim()}', code);
      }
      return Output._(code, out.takeBytes(), stderr);
    } finally {
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
  static Pipe filter(List<String> command, {String? dir, Map<String, String?>? env}) {
    _checkCommand(command);
    return _Filter(command, dir: dir, env: env);
  }

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

  /// Where [program] resolves on `PATH` (with `PATHEXT` on Windows), or
  /// null when it is not installed. Starts no process. A name with a path
  /// separator is checked as that path.
  static Future<String?> which(String program) async {
    final windows = io.Platform.isWindows;
    final exts = windows
        ? ['', ...(io.Platform.environment['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD').split(';').where((e) => e.isNotEmpty)]
        : const [''];
    Future<String?> probe(String base) async {
      for (final ext in exts) {
        final path = '$base$ext';
        final st = await io.FileStat.stat(path);
        if (st.type != io.FileSystemEntityType.file) continue;
        if (windows || st.mode & 0x49 != 0) return path; // any execute bit (0o111)
      }
      return null;
    }

    if (program.contains('/') || (windows && program.contains(r'\'))) return probe(program);
    final sep = windows ? ';' : ':';
    for (final dir in (io.Platform.environment['PATH'] ?? '').split(sep)) {
      if (dir.isEmpty) continue;
      final hit = await probe('$dir${windows ? r'\' : '/'}$program');
      if (hit != null) return hit;
    }
    return null;
  }

  static void _checkCommand(List<String> command) {
    if (command.isEmpty) {
      throw ArgumentError.value(command, 'command', 'must not be empty');
    }
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

/// Future mirrors (rule 4). The extension name is import-only; never reference it.
extension OutputFuture on Future<Output> {
  Future<int> code() async => (await this).code();
  Future<bool> ok() async => (await this).ok();
  Future<String> err() async => (await this).err();
}

/// Which started processes have exited (and been reaped), for [_killTree].
final _reaped = Expando<bool>();

void _watch(io.Process proc) => unawaited(proc.exitCode.then((_) => _reaped[proc] = true));

/// Signal [proc] and every process below it, deepest first, so a `sh -c`
/// or a build tool cannot leave grandchildren running under init. The tree
/// is read before anything dies (an orphan loses its parent link). Windows
/// has no `ps`: only [proc] is signalled there.
Future<void> _killTree(io.Process proc, io.ProcessSignal signal) async {
  // Once reaped, its pid may belong to someone else: never signal it then.
  if (_reaped[proc] ?? false) return;
  final below = <int>[];
  if (!io.Platform.isWindows) {
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
  }
  for (final pid in below) {
    if (pid > 1 && pid != io.pid) io.Process.killPid(pid, signal);
  }
  proc.kill(signal);
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
      final err = utf8.decode(stderrBuf.takeBytes(), allowMalformed: true);
      throw io.ProcessException(_command[0], _shown(_command.sublist(1)), 'exit $code: ${_tail(err)}', code);
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

final class _LineSink implements Sink<String> {
  _LineSink(this._onLine);
  final void Function(String line) _onLine;
  @override
  void add(String line) => _onLine(line);
  @override
  void close() {}
}

/// [args] fit for an error message: URL credentials and token values,
/// secret header values (`-H 'Authorization: …'`) and secret options
/// (`--token=…`, `--password …`) shown as `***`.
List<String> _shown(List<String> args) => [
  for (var i = 0; i < args.length; i++)
    if (i > 0 && (args[i - 1] == '-H' || args[i - 1] == '--header'))
      _header(args[i])
    else if (i > 0 && _secretFlag.hasMatch(args[i - 1]) && !args[i - 1].contains('='))
      '***'
    else
      _arg(args[i]),
];

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
