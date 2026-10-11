import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

/// Spawn a child process and capture or stream its output.
///
/// ```dart
/// final res = await Process.run('git', ['status', '--short']);
/// if (res.ok) print(res.out);
///
/// final ping = Process('ping', ['-c', '4']);
/// await for (final line in ping.lines()) { print(line); }
/// ```
final class Process {
  final Future<io.Process> _proc;

  /// Starts [cmd] with [args] immediately; output is consumed by [lines]/[out].
  Process(Object cmd, [List<Object>? args])
    : _proc = io.Process.start(cmd.toString(), [for (final a in args ?? const []) a.toString()]);

  /// The child's stdin, when constructed directly.
  Future<io.IOSink> get stdin async => (await _proc).stdin;

  /// The process id.
  Future<int> get pid async => (await _proc).pid;

  /// A stream of the child's stdout lines.
  Stream<String> lines() async* {
    final p = await _proc;
    yield* p.stdout.transform(utf8.decoder).transform(const LineSplitter());
  }

  /// A stream of the child's stderr lines.
  Stream<String> errors() async* {
    final p = await _proc;
    yield* p.stderr.transform(utf8.decoder).transform(const LineSplitter());
  }

  /// All of the child's stdout once it exits.
  Future<String> out() async => utf8.decode(await (await _proc).stdout.expand((b) => b).toList());

  /// Waits for the child to exit.
  Future<int> get exitCode async => (await _proc).exitCode;

  /// Sends [signal] to the child.
  Future<void> kill([io.ProcessSignal signal = io.ProcessSignal.sigterm]) async => (await _proc).kill(signal);

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

/// Thrown when a process fails and `check: true` is requested.
final class ProcessException implements Exception {
  final String command;
  final String out;
  final String err;
  final int code;

  ProcessException(this.command, this.out, this.err, this.code);

  @override
  String toString() => 'ProcessException: `$command` exited $code: ${err.trim()}';
}
