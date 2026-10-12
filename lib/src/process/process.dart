import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import '../core/native.dart' as l2native;
import '../core/traits.dart';

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
  final String command;
  final List<String> args;
  final Located? dir;
  final Map<String, String>? env;

  /// Stdin content, written and closed right after starting: a `String` or
  /// `List<int>`, anything else an [ArgumentError] on first use.
  final Object? input;

  Future<io.Process>? _started;
  // Stdout as a queue of chunks with a head offset: consuming never moves the
  // bytes behind it, and the newline search resumes where it stopped.
  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _head = 0; // consumed offset into the first chunk
  int _buffered = 0; // total unconsumed bytes
  int _scanned = 0; // unconsumed prefix already searched for '\n'
  var _stdoutDone = false;
  var _stderrDone = false;
  Object? _pumpError;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  final List<int> _errTail = [];
  StreamController<List<int>>? _errLive;
  var _errorsTaken = false;
  var _stdinClosed = false;
  var _writerTaken = false;
  var _sawExit = false;
  var _closed = false;

  /// Names the child, nothing more: it starts on the first call.
  Process(this.command, this.args, {this.dir, this.env, this.input});

  Future<io.Process> get _proc => _started ??= _spawn();

  /// Starts the child, pumps both streams, then writes [input] when there is
  /// any. The pumps start first, so input larger than the pipe buffer streams
  /// while the child runs instead of deadlocking it. A child that cannot start
  /// is a [ProcessException] (code 127). A child that stops reading early ends
  /// the input with a broken pipe, which is not an error.
  Future<io.Process> _spawn() async {
    io.Process proc;
    try {
      proc = await io.Process.start(command, args, workingDirectory: dir?.path, environment: env);
    } on io.ProcessException catch (e) {
      throw ProcessException(command, 127, e.message);
    }
    unawaited(
      proc.exitCode.then((_) {
        _sawExit = true;
      }),
    );
    _pumpStdout(proc);
    _pumpStderr(proc);
    if (input != null) {
      final List<int> bytes;
      if (input is String) {
        bytes = utf8.encode(input as String);
      } else if (input is List<int>) {
        bytes = input as List<int>;
      } else {
        throw ArgumentError.value(input, 'input', 'Must be String or List<int>');
      }
      try {
        proc.stdin.add(bytes);
        await proc.stdin.flush();
        await proc.stdin.close();
      } on io.SocketException catch (e) {
        if (!_isBrokenPipe(e)) rethrow;
        // The child stopped reading: its output (or exit) is what matters now.
        try {
          await proc.stdin.close();
        } catch (_) {
          // Closing a dead pipe never hides the child's outcome.
        }
      } finally {
        _stdinClosed = true;
      }
    }
    return proc;
  }

  Future<void> _pumpStdout(io.Process proc) async {
    try {
      await for (final chunk in proc.stdout) {
        if (chunk.isNotEmpty) {
          _chunks.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
          _buffered += chunk.length;
        }
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
      _stderrDone = true;
      try {
        await _errLive?.close();
      } catch (_) {
        // Taken late and closed already: nothing left to deliver.
      }
    }
  }

  void _wake() {
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    }
  }

  /// Waits for *new* stdout past [seen] bytes buffered, unless stdout is done
  /// or the pump failed: returning at once on a non-empty buffer spins the
  /// caller at 100% CPU when the child ends a line never (e.g. `printf abc`).
  Future<void> _more(int seen) {
    if (_pumpError != null) throw _pumpError!;
    if (_stdoutDone || _buffered != seen) return Future.value();
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  /// Drops the first [n] unconsumed bytes (advancing the head, never moving
  /// the bytes behind it).
  void _consume(int n) {
    var left = n;
    while (left > 0) {
      final first = _chunks.first;
      final avail = first.length - _head;
      if (avail > left) {
        _head += left;
        _buffered -= left;
        left = 0;
      } else {
        left -= avail;
        _buffered -= avail;
        _chunks.removeFirst();
        _head = 0;
      }
    }
    _scanned = _scanned <= n ? 0 : _scanned - n;
  }

  /// Copies the first [n] unconsumed bytes into [dst] at [off].
  void _copyInto(Uint8List dst, int off, int n) {
    var done = 0;
    var first = true;
    for (final c in _chunks) {
      if (done >= n) break;
      final start = first ? _head : 0;
      first = false;
      var m = c.length - start;
      if (m > n - done) m = n - done;
      dst.setRange(off + done, off + done + m, c, start);
      done += m;
    }
  }

  /// The first [n] unconsumed bytes, copied out (for decoding one line).
  Uint8List _prefixBytes(int n) {
    final out = Uint8List(n);
    _copyInto(out, 0, n);
    return out;
  }

  /// The offset of the next `\n` in the unconsumed bytes (from its start), or
  /// -1. Bytes before [_scanned] were searched already and are skipped.
  int _indexOfNewline() {
    var abs = 0;
    var first = true;
    for (final c in _chunks) {
      final start = first ? _head : 0;
      first = false;
      var j = start;
      if (abs < _scanned) j = start + (_scanned - abs);
      for (; j < c.length; j++) {
        if (c[j] == 10) return abs + (j - start);
      }
      abs += c.length - start;
    }
    return -1;
  }

  String _errString() => utf8.decode(_errTail, allowMalformed: true);

  /// Closes stdin for a one-shot reading, unless the caller took a writer and
  /// still owns stdin (a `pipe` into this process, an interactive session).
  Future<void> _closeStdinUnlessWriter() async {
    if (_writerTaken) return;
    await _closeStdin();
  }

  /// Reads up to [buf.length] stdout bytes; `0` means the child's stdout
  /// ended. Never touches stderr: read it with [errors]. A one-shot read
  /// closes stdin first (unless a writer was taken), so `cat` sees EOF.
  Future<int> read(Uint8List buf) async {
    await _proc;
    await _closeStdinUnlessWriter();
    while (true) {
      if (_pumpError != null) throw _pumpError!;
      if (_buffered > 0) {
        final n = buf.length < _buffered ? buf.length : _buffered;
        _copyInto(buf, 0, n);
        _consume(n);
        return n;
      }
      if (_stdoutDone) return 0;
      await _more(0);
    }
  }

  /// Reads a single stdout line without buffering the rest, so a child that
  /// never exits still yields lines as produced. The line ending (`\n`, with
  /// a preceding `\r` stripped) is not included. Answers `null` once stdout
  /// ends (and any trailing bytes without a newline are one last line).
  /// A one-shot read closes stdin first, unless a writer was taken.
  Future<String?> line() async {
    await _proc;
    await _closeStdinUnlessWriter();
    while (true) {
      if (_pumpError != null) throw _pumpError!;
      final nl = _indexOfNewline();
      if (nl != -1) {
        final raw = _prefixBytes(nl);
        _consume(nl + 1);
        // A preceding `\r` is stripped without copying the line again.
        final end = nl > 0 && raw[nl - 1] == 13 ? nl - 1 : nl;
        return utf8.decode(Uint8List.sublistView(raw, 0, end));
      }
      if (_stdoutDone) {
        if (_buffered == 0) return null;
        final raw = _prefixBytes(_buffered);
        _consume(_buffered);
        return utf8.decode(raw);
      }
      _scanned = _buffered;
      await _more(_buffered);
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
    if (code != 0) throw ProcessException(command, code, _errString());
  }

  /// A stream of the child's stderr lines: the bytes buffered so far, then the
  /// live stream. Once called, stderr is not kept for the exception: call
  /// [errors] or rely on [ProcessException.err]. Taken after stderr ended,
  /// it yields the buffered tail and ends instead of hanging.
  Stream<String> errors() async* {
    await _proc;
    _errorsTaken = true;
    final buffered = Uint8List.fromList(_errTail);
    _errTail.clear();
    final live = _errLive ??= StreamController<List<int>>.broadcast();
    if (buffered.isNotEmpty) {
      yield* Stream<List<int>>.value(buffered).transform(utf8.decoder).transform(const LineSplitter());
    }
    if (_stderrDone) {
      await live.close();
      return;
    }
    yield* live.stream.transform(utf8.decoder).transform(const LineSplitter());
  }

  /// Stdout as text; a non-zero exit throws ProcessException(command, code, err).
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
    if (code != 0) throw ProcessException(command, code, _errString());
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
  /// after stdin closed is a [StateError]. The bytes are copied: the caller
  /// may reuse [data] once the future completes.
  Future<int> write(Object data) async {
    final List<int> bytes;
    if (data is String) {
      bytes = utf8.encode(data);
    } else if (data is Uint8List) {
      bytes = Uint8List.fromList(data);
    } else if (data is List<int>) {
      bytes = List<int>.from(data, growable: false);
    } else {
      throw ArgumentError.value(data, 'data', 'Must be String, List<int> or Uint8List');
    }
    await _proc;
    if (_stdinClosed) throw StateError('Cannot write: stdin is closed');
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
      if (code != 0) throw ProcessException(command, code, _errString());
      return;
    }
    try {
      final code = await proc.exitCode.timeout(timeout);
      if (code != 0) throw ProcessException(command, code, _errString());
    } on TimeoutException {
      await close();
      throw TimeoutException('Process timed out after $timeout', timeout);
    }
  }

  /// Kills the whole tree if still running and waits until it is reaped.
  /// Idempotent; never leaves a zombie, never starts a process just to kill
  /// it. Once the exit code has completed the child is already reaped, so no
  /// kill runs on a pid the OS may have reused.
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
      if (!_sawExit) {
        await _killTree(proc.pid);
        try {
          proc.kill();
        } catch (_) {
          // Already gone: the wait below reaps it.
        }
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

  /// Kills the child and everything under it (children first found), through
  /// `tk_process_kill_tree` (`taskkill /T /F` on Windows, stop-and-reap
  /// depth-first elsewhere). Without the library it is an [UnsupportedError]
  /// (rule 42: no Dart fallback). Never throws for a child already gone.
  Future<void> _killTree(int pid) async {
    // Only ever a real child: 0 is our process group, 1 launchd/init, and a pid that
    // doesn't fit an i32 reads as -1 (every process the user owns) on the native side.
    if (pid <= 1 || pid > 0x7fffffff || pid == io.pid) return;
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
  /// false: a process stdin cannot resume. Taking a writer keeps stdin open
  /// for readings (they close it only when no writer was taken).
  @override
  Future<Writer> writer({bool resume = false}) async {
    if (resume) throw ArgumentError.value(resume, 'resume', 'A process stdin cannot resume');
    await _proc;
    _writerTaken = true;
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
    if (code != 0) throw ProcessException(_proc.command, code, _proc._errString());
  }
}

/// Stdin as a [Writer]: closing it signals end-of-input; the child keeps
/// running. Each write copies [data] (the caller reuses its chunk once the
/// future completes) and flushes every 1 MiB for backpressure.
final class _ProcessStdinWriter implements Writer {
  final Process _proc;
  var _closed = false;
  var _sinceFlush = 0;

  _ProcessStdinWriter(this._proc);

  @override
  Future<int> write(Uint8List data) async {
    final copy = Uint8List.fromList(data);
    await _proc.write(copy);
    _sinceFlush += copy.length;
    if (_sinceFlush >= 1024 * 1024) {
      _sinceFlush = 0;
      await flush();
    }
    return copy.length;
  }

  @override
  Future<void> flush() async => (await _proc._proc).stdin.flush();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _proc._closeStdin();
  }

  @override
  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    try {
      await _proc._closeStdin();
    } catch (_) {
      // Aborting stdin never hides the write failure.
    }
  }
}

/// Whether [e] is a broken pipe: the child stopped reading stdin (exited, or
/// closed it). Writing on is pointless; its output or exit is what matters.
bool _isBrokenPipe(io.SocketException e) {
  if (e.osError?.errorCode == 32) return true;
  final m = e.message.toLowerCase();
  return m.contains('broken pipe') || m.contains('pipe has been ended') || m.contains('epipe');
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
