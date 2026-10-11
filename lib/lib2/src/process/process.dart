import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import '../core/native.dart' as l2native;
import '../core/traits.dart';

/// Spawn a child process and capture or stream its output.
///
/// The running child is a [Reader] over its stdout and a [Writer] into its
/// stdin, so processes pipe into each other and files:
///
/// ```dart
/// final p1 = Process('cat', ['data.log']);
/// final p2 = Process('grep', ['ERROR']);
/// await p1.pipe(p2);
/// await p2.closeStdin();
/// print(await p2.text());
///
/// final proc = Process('ping', ['8.8.8.8']);
/// await for (final line in proc.lines()) { print(line); }
/// ```
///
/// Cancelling kills the whole process tree (children the child spawned
/// itself included: `taskkill /T /F` on Windows, stop-and-reap depth-first
/// elsewhere — the `tk_kill_tree` semantics, PLAN.md §4). [wait] with a
/// [timeout] sends SIGTERM, waits a 4 s grace, then SIGKILLs, and throws
/// [TimeoutException] once the child is reaped.
final class Process implements Reader, Writer, Closer {
  final Future<io.Process> _proc;

  final List<int> _buf = [];
  var _stdoutDone = false;
  Object? _error;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  var _stdinClosed = false;
  var _cancelled = false;

  /// Starts [cmd] with [args] immediately; output is consumed by [line]/[text].
  Process(Object cmd, [List<Object>? args])
    : _proc = _start(cmd.toString(), [for (final a in args ?? const []) a.toString()]) {
    _pump();
  }

  static Future<io.Process> _start(String cmd, List<String> args) async {
    try {
      return await io.Process.start(cmd, args);
    } on io.ProcessException catch (e) {
      throw ProcessException(cmd, '', e.message, 127);
    }
  }

  Future<void> _pump() async {
    final io.Process p;
    try {
      p = await _proc;
    } catch (e) {
      _fail(e);
      return;
    }
    try {
      await for (final chunk in p.stdout) {
        _buf.addAll(chunk);
        _wake();
      }
    } catch (e) {
      _fail(e);
      return;
    }
    _stdoutDone = true;
    _wake();
  }

  void _fail(Object e) {
    _error = e;
    _wake();
  }

  void _wake() {
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    }
  }

  Future<void> _more() {
    if (_error != null) throw _error!;
    if (_buf.isNotEmpty || _stdoutDone) return Future.value();
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  /// The process id.
  Future<int> get pid async => (await _proc).pid;

  /// Reads up to [buf.length] stdout bytes; `0` means the child's stdout
  /// ended. Never touches stderr: read it with [errors].
  @override
  Future<int> read(Uint8List buf) async {
    while (true) {
      if (_error != null) throw _error!;
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
    while (true) {
      if (_error != null) throw _error!;
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
  /// arrives — true streaming, not a buffer drained at exit.
  Stream<String> lines() async* {
    while (true) {
      final next = await line();
      if (next == null) return;
      yield next;
    }
  }

  /// A stream of the child's stderr lines.
  Stream<String> errors() async* {
    final p = await _proc;
    yield* p.stderr.transform(utf8.decoder).transform(const LineSplitter());
  }

  /// The rest of the child's stdout, decoded as UTF-8, once it ends.
  Future<String> text() async {
    final out = BytesBuilder(copy: false);
    final chunk = Uint8List(64 * 1024);
    while (true) {
      final n = await read(chunk);
      if (n <= 0) break;
      out.add(chunk.sublist(0, n));
    }
    return utf8.decode(out.takeBytes());
  }

  /// Writes [data] (`String` UTF-8, bytes verbatim) to the child's stdin and
  /// answers the bytes accepted. Anything else is an [ArgumentError]; writing
  /// after stdin closed is a [StateError].
  @override
  Future<int> write(Object data) async {
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

  @override
  Future<void> flush() async => (await _proc).stdin.flush();

  /// Closes the child's stdin, signalling end-of-input (a `sort` then
  /// finishes). The child itself keeps running; [close] or [cancel] ends it.
  Future<void> closeStdin() async {
    if (_stdinClosed) return;
    _stdinClosed = true;
    await (await _proc).stdin.close();
  }

  /// Closes stdin and waits for the child to exit, answering its code. A
  /// child that never exits on EOF needs [cancel] first.
  @override
  Future<void> close() async {
    await closeStdin();
    await wait();
  }

  /// Waits for the child to exit and answers its code. With [timeout], the
  /// whole tree is sent SIGTERM on expiry, SIGKILL after a 4 s grace, and a
  /// [TimeoutException] is thrown once it is reaped.
  Future<int> wait({Duration? timeout}) async {
    final p = await _proc;
    if (timeout == null) return p.exitCode;
    try {
      return await p.exitCode.timeout(timeout);
    } on TimeoutException {
      await killTree();
      try {
        await p.exitCode.timeout(const Duration(seconds: 4));
      } on TimeoutException {
        try {
          (await _proc).kill(io.ProcessSignal.sigkill);
        } catch (_) {
          // Already gone: the wait below reaps it.
        }
        await killTree();
        await p.exitCode;
      }
      throw TimeoutException('Process timed out after $timeout', timeout);
    }
  }

  /// Whether stdout has ended.
  Future<void> get eof async {
    while (true) {
      if (_error != null) throw _error!;
      if (_stdoutDone && _buf.isEmpty) return;
      await _more();
    }
  }

  /// The child's exit code, once it exits.
  Future<int> get exitCode async => (await _proc).exitCode;

  /// Sends [signal] to the direct child.
  Future<void> kill([io.ProcessSignal signal = io.ProcessSignal.sigterm]) async => (await _proc).kill(signal);

  /// Kills the child and everything under it (children first found), through
  /// `tk_process_kill_tree` (`taskkill /T /F` on Windows, stop-and-reap
  /// depth-first elsewhere). Without the library it is an [UnsupportedError]
  /// (r50: no Dart fallback). Never throws for a child already gone.
  Future<void> killTree() async {
    final pid = await this.pid;
    final rc = _ProcessNative.killTree(pid);
    if (rc < 0) throw l2native.NativeException('kill process tree', l2native.Lib2Native.lastError());
  }

  /// Kills the whole tree if still running and waits until it is reaped.
  /// Idempotent; never leaves a zombie.
  Future<void> cancel() async {
    if (_cancelled) {
      await (await _proc).exitCode;
      return;
    }
    _cancelled = true;
    final p = await _proc;
    await killTree();
    try {
      p.kill();
    } catch (_) {
      // Already gone: the wait below reaps it.
    }
    await p.exitCode;
  }

  /// Runs [cmd] to completion, capturing output.
  static Future<ProcessResult> run(Object cmd, [List<Object>? args]) => exec(cmd, args);

  /// Runs [cmd] with full control over working [dir], [env], stdin [input] and [check].
  static Future<ProcessResult> exec(
    Object cmd, [
    List<Object>? args,
    Object? dir,
    Map<String, String>? env,
    Object? input,
    bool check = false,
  ]) async {
    final argList = [for (final a in args ?? const []) a.toString()];
    String outText;
    String errText;
    int exit;
    if (input != null) {
      final p = await io.Process.start(cmd.toString(), argList, workingDirectory: dir?.toString(), environment: env);
      p.stdin.write(input is String ? input : input.toString());
      await p.stdin.close();
      outText = await utf8.decodeStream(p.stdout);
      errText = await utf8.decodeStream(p.stderr);
      exit = await p.exitCode;
    } else {
      final result = await io.Process.run(
        cmd.toString(),
        argList,
        workingDirectory: dir?.toString(),
        environment: env,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      outText = result.stdout is String ? result.stdout as String : utf8.decode(result.stdout as List<int>);
      errText = result.stderr is String ? result.stderr as String : utf8.decode(result.stderr as List<int>);
      exit = result.exitCode;
    }
    final res = ProcessResult(exit, outText, errText);
    if (check && !res.ok) throw ProcessException(cmd.toString(), outText, errText, res.code);
    return res;
  }

  /// Runs [cmd] to completion and answers its exit code.
  static Future<int> code(Object cmd, [List<Object>? args]) async => (await run(cmd, args)).code;
}

/// The captured result of [Process.run].
final class ProcessResult {
  /// The exit status; `0` means success.
  final int code;

  /// Captured stdout.
  final String out;

  /// Captured stderr.
  final String err;

  const ProcessResult(this.code, this.out, this.err);

  /// Whether the process succeeded (`exitCode == 0`).
  bool get ok => code == 0;

  /// The exit status (alias for [code]).
  int get exitCode => code;

  /// The full stdout.
  String text() => out;

  /// The stdout split into lines (empty lines removed from the end).
  List<String> get lines => const LineSplitter().convert(out);

  @override
  String toString() => 'ProcessResult(code: $code, out: ${out.length} bytes, err: ${err.length} bytes)';
}

/// The native `tk_process_kill_tree` call behind [Process.killTree] (cutover).
abstract final class _ProcessNative {
  static ffi.DynamicLibrary get _lib => l2native.Lib2Native.require();

  static final killTree = _lib.lookupFunction<ffi.Int32 Function(ffi.Uint32), int Function(int)>(
    'tk_process_kill_tree',
  );
}

/// Thrown when a process fails and `check: true` is requested, or when the
/// child cannot be spawned (a missing executable is code 127).
final class ProcessException implements Exception {
  final String command;
  final String out;
  final String err;
  final int code;

  ProcessException(this.command, this.out, this.err, this.code);

  @override
  String toString() => 'ProcessException: `$command` exited $code: ${err.trim()}';
}
