import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import '../core/native.dart' as l2native;
import '../core/traits.dart';
import '../fs/io.dart' as fs;

export '../core/errors.dart';
export '../core/pipe.dart';
export '../core/traits.dart';

/// Up to this many stderr bytes are kept for [ProcessException.err].
const _errCap = 64 * 1024;

/// A child process, started on the first call. Its stdout is a Source and its stdin a
/// Target, so readings (`text`, `lines`, `json` …) and `pipe` work on it.
///
/// ```dart
/// final branch = await Process('git', ['rev-parse', '--abbrev-ref', 'HEAD']).text();
/// final proc = Process('ping', ['127.0.0.1']);
/// await for (final line in proc.lines()) {
///   Cli.print(line);
///   break;
/// }
/// await proc.close();
/// ```
///
/// A process starts on its first call. Readings throw a [ProcessException] on
/// a non-zero exit; [check] answers yes or no. [close] kills the whole tree;
/// [wait] with a timeout throws [TimeoutException] after one.
final class Process implements Source, Target {
  final String cmd;
  final List<String> args;
  final fs.Dir? dir;
  final Map<String, String>? env;

  /// Stdin content, written and closed right after starting: a `String` or
  /// `List<int>`, anything else an [ArgumentError] on first use.
  final Object? input;

  Future<io.Process>? _started;
  final List<int> _buf = [];
  var _stdoutDone = false;
  Object? _pumpError;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  final List<int> _errTail = [];
  StreamController<List<int>>? _errLive;
  var _errorsTaken = false;
  var _stdinClosed = false;
  var _closed = false;

  /// Names the child, nothing more: it starts on the first call.
  Process(this.cmd, this.args, {this.dir, this.env, this.input});

  Future<io.Process> get _proc => _started ??= _spawn();

  /// Starts the child, writes [input] when there is any, and pumps both
  /// streams. A child that cannot start is a [ProcessException] (code 127).
  Future<io.Process> _spawn() async {
    io.Process proc;
    try {
      proc = await io.Process.start(cmd, args, workingDirectory: dir?.path, environment: env);
    } on io.ProcessException catch (e) {
      throw ProcessException(cmd, 127, e.message);
    }
    if (input != null) {
      final List<int> bytes;
      if (input is String) {
        bytes = utf8.encode(input as String);
      } else if (input is List<int>) {
        bytes = input as List<int>;
      } else {
        throw ArgumentError.value(input, 'input', 'Must be String or List<int>');
      }
      proc.stdin.add(bytes);
      await proc.stdin.close();
      _stdinClosed = true;
    }
    _pumpStdout(proc);
    _pumpStderr(proc);
    return proc;
  }

  Future<void> _pumpStdout(io.Process proc) async {
    try {
      await for (final chunk in proc.stdout) {
        _buf.addAll(chunk);
        _wake();
      }
    } catch (e) {
      _pumpError = e;
      _wake();
      return;
    }
    _stdoutDone = true;
    _wake();
  }

  Future<void> _pumpStderr(io.Process proc) async {
    try {
      await for (final chunk in proc.stderr) {
        if (_errorsTaken) {
          _errLive?.add(chunk);
        } else {
          _errTail.addAll(chunk);
          if (_errTail.length > _errCap) _errTail.removeRange(0, _errTail.length - _errCap);
        }
      }
    } catch (_) {
      // Stderr ends with the child; nothing is lost that matters.
    } finally {
      await _errLive?.close();
    }
  }

  void _wake() {
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    }
  }

  Future<void> _more() {
    if (_pumpError != null) throw _pumpError!;
    if (_buf.isNotEmpty || _stdoutDone) return Future.value();
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  String _errString() => utf8.decode(_errTail, allowMalformed: true);

  /// The process id, once started.
  Future<int> get pid async => (await _proc).pid;

  /// The child's exit code, once it exits.
  Future<int> get exitCode async => (await _proc).exitCode;

  /// Reads up to [buf.length] stdout bytes; `0` means the child's stdout
  /// ended. Never touches stderr: read it with [errors].
  Future<int> read(Uint8List buf) async {
    await _proc;
    while (true) {
      if (_pumpError != null) throw _pumpError!;
      if (_buf.isNotEmpty) {
        final n = buf.length < _buf.length ? buf.length : _buf.length;
        buf.setRange(0, n, _buf);
        _buf.removeRange(0, n);
        return n;
      }
      if (_stdoutDone) return 0;
      await _more();
    }
  }

  /// Reads a single stdout line without buffering the rest, so a child that
  /// never exits still yields lines as produced. The line ending (`\n`, with
  /// a preceding `\r` stripped) is not included. Answers `null` once stdout
  /// ends (and any trailing bytes without a newline are one last line).
  Future<String?> line() async {
    await _proc;
    while (true) {
      if (_pumpError != null) throw _pumpError!;
      final nl = _buf.indexOf(10);
      if (nl != -1) {
        var end = nl;
        if (end > 0 && _buf[end - 1] == 13) end--;
        final line = utf8.decode(_buf.sublist(0, end));
        _buf.removeRange(0, nl + 1);
        return line;
      }
      if (_stdoutDone) {
        if (_buf.isEmpty) return null;
        final line = utf8.decode(_buf);
        _buf.clear();
        return line;
      }
      await _more();
    }
  }

  /// The child's stdout lines, each read with [line] and yielded as it
  /// arrives — true streaming, not a buffer drained at exit. A non-zero exit
  /// throws a [ProcessException] at the end.
  Stream<String> lines() async* {
    await _proc;
    while (true) {
      final next = await line();
      if (next == null) break;
      yield next;
    }
    final code = await (await _proc).exitCode;
    if (code != 0) throw ProcessException(cmd, code, _errString());
  }

  /// A stream of the child's stderr lines. Once called, stderr is not kept
  /// for the exception: call [errors] or rely on [ProcessException.err].
  Stream<String> errors() async* {
    await _proc;
    _errorsTaken = true;
    _errTail.clear();
    _errLive ??= StreamController<List<int>>.broadcast();
    yield* _errLive!.stream.transform(utf8.decoder).transform(const LineSplitter());
  }

  /// Stdout as text; a non-zero exit throws ProcessException(cmd, code, err).
  Future<String> text() async {
    await _proc;
    final out = BytesBuilder(copy: false);
    final chunk = Uint8List(64 * 1024);
    while (true) {
      final n = await read(chunk);
      if (n <= 0) break;
      out.add(Uint8List.fromList(Uint8List.sublistView(chunk, 0, n)));
    }
    final code = await (await _proc).exitCode;
    if (code != 0) throw ProcessException(cmd, code, _errString());
    return utf8.decode(out.takeBytes());
  }

  /// Runs to the end; answers whether the exit was 0. Never throws on the exit
  /// code; a command that can't start is ProcessException(code: 127).
  Future<bool> check() async {
    final proc = await _proc;
    await _closeStdin();
    final chunk = Uint8List(64 * 1024);
    while (true) {
      final n = await read(chunk);
      if (n <= 0) break;
    }
    return await proc.exitCode == 0;
  }

  /// Writes [data] (`String` UTF-8, bytes verbatim) to the child's stdin and
  /// answers the bytes accepted. Anything else is an [ArgumentError]; writing
  /// after stdin closed is a [StateError].
  Future<int> write(Object data) async {
    await _proc;
    if (_stdinClosed) throw StateError('Cannot write: stdin is closed');
    final List<int> bytes;
    if (data is String) {
      bytes = utf8.encode(data);
    } else if (data is List<int>) {
      bytes = data;
    } else {
      throw ArgumentError.value(data, 'data', 'Must be String, List<int> or Uint8List');
    }
    (await _proc).stdin.add(bytes);
    return bytes.length;
  }

  /// Closes stdin and waits for the child to exit. A non-zero exit throws a
  /// [ProcessException]; with [timeout], the whole tree is killed on expiry
  /// and a [TimeoutException] is thrown once it is reaped.
  Future<void> wait({Duration? timeout}) async {
    final proc = await _proc;
    await _closeStdin();
    if (timeout == null) {
      final code = await proc.exitCode;
      if (code != 0) throw ProcessException(cmd, code, _errString());
      return;
    }
    try {
      final code = await proc.exitCode.timeout(timeout);
      if (code != 0) throw ProcessException(cmd, code, _errString());
    } on TimeoutException {
      await close();
      throw TimeoutException('Process timed out after $timeout', timeout);
    }
  }

  /// Kills the whole tree if still running and waits until it is reaped.
  /// Idempotent; never leaves a zombie, never starts a process just to kill
  /// it.
  Future<void> close() async {
    final started = _started;
    if (started == null || _closed) {
      _closed = true;
      if (started != null) {
        try {
          await started;
        } catch (_) {
          // Never started: there is nothing to reap.
        }
      }
      return;
    }
    _closed = true;
    try {
      final proc = await started;
      await _killTree(proc.pid);
      try {
        proc.kill();
      } catch (_) {
        // Already gone: the wait below reaps it.
      }
      await proc.exitCode;
    } catch (_) {
      // Spawn failed or already reaped: nothing runs.
    }
  }

  /// Closes the child's stdin, signalling end-of-input (a `sort` then
  /// finishes). The child itself keeps running.
  Future<void> _closeStdin() async {
    if (_stdinClosed) return;
    _stdinClosed = true;
    await (await _proc).stdin.close();
  }

  /// Sends [signal] to the direct child.
  Future<void> kill([io.ProcessSignal signal = io.ProcessSignal.sigterm]) async => (await _proc).kill(signal);

  /// Kills the child and everything under it (children first found), through
  /// `tk_process_kill_tree` (`taskkill /T /F` on Windows, stop-and-reap
  /// depth-first elsewhere). Without the library it is an [UnsupportedError]
  /// (rule 42: no Dart fallback). Never throws for a child already gone.
  Future<void> _killTree(int pid) async {
    final rc = _ProcessNative.killTree(pid);
    if (rc < 0) throw l2native.NativeException('kill process tree', l2native.lastError());
  }

  /// Stdout as a [Reader]: [from] must be 0; this reader's [Reader.close]
  /// awaits the exit and throws on a non-zero one.
  @override
  Future<Reader> reader({int from = 0}) async {
    if (from != 0) throw ArgumentError.value(from, 'from', 'Only 0: a process cannot seek');
    await _proc;
    return _ProcessStdoutReader(this);
  }

  /// Stdin as a [Writer]: closing it signals end-of-input. [resume] must be
  /// false: a process stdin cannot resume.
  @override
  Future<Writer> writer({bool resume = false}) async {
    if (resume) throw ArgumentError.value(resume, 'resume', 'A process stdin cannot resume');
    await _proc;
    return _ProcessStdinWriter(this);
  }

  /// Processes have no size; answers 0.
  @override
  Future<int> size() async => 0;

  /// A process stream has no known length.
  @override
  int? get lengthHint => null;
}

/// Stdout as a [Reader]: shares the process's one stdout buffer with
/// [Process.line] and [Process.text].
final class _ProcessStdoutReader implements Reader {
  final Process _proc;
  var _closed = false;

  _ProcessStdoutReader(this._proc);

  @override
  Future<int> read(Uint8List buf) => _proc.read(buf);

  /// Closes stdin, awaits the exit, and throws on a non-zero one.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _proc._closeStdin();
    final code = await (await _proc._proc).exitCode;
    if (code != 0) throw ProcessException(_proc.cmd, code, _proc._errString());
  }
}

/// Stdin as a [Writer]: closing it signals end-of-input; the child keeps
/// running.
final class _ProcessStdinWriter implements Writer {
  final Process _proc;
  var _closed = false;

  _ProcessStdinWriter(this._proc);

  @override
  Future<int> write(Uint8List data) => _proc.write(data);

  @override
  Future<void> flush() async => (await _proc._proc).stdin.flush();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _proc._closeStdin();
  }
}

/// The native `tk_process_kill_tree` call behind [Process._killTree] (cutover).
abstract final class _ProcessNative {
  static ffi.DynamicLibrary get _lib => l2native.require();

  static final killTree = _lib.lookupFunction<ffi.Int32 Function(ffi.Uint32), int Function(int)>(
    'tk_process_kill_tree',
  );
}

/// A child that failed, with up to the last 64 KiB of stderr.
final class ProcessException implements Exception {
  /// The command that was started.
  final String command;

  /// The exit code (127: the command could not start).
  final int code;

  /// The last 64 KiB of stderr.
  final String err;

  const ProcessException(this.command, this.code, this.err);

  @override
  String toString() => 'ProcessException: `$command` exited $code: ${err.trim()}';
}
