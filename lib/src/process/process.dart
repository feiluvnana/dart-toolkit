import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/json_document.dart';
import '../fs/path.dart';
import '../util/env.dart';
import '../util/stdio.dart';
import 'shell_result.dart';

List<String> _splitCommand(String command) {
  final args = <String>[];
  final current = StringBuffer();
  var inSingle = false;
  var inDouble = false;
  var isEscaped = false;

  const backslash = 0x5c, singleQuote = 0x27, doubleQuote = 0x22;
  bool isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;

  for (var i = 0; i < command.length; i++) {
    final char = command.codeUnitAt(i);

    if (isEscaped) {
      current.writeCharCode(char);
      isEscaped = false;
    } else if (char == backslash) {
      isEscaped = true;
    } else if (char == singleQuote && !inDouble) {
      inSingle = !inSingle;
    } else if (char == doubleQuote && !inSingle) {
      inDouble = !inDouble;
    } else if (isSpace(char) && !inSingle && !inDouble) {
      if (current.isNotEmpty) {
        args.add(current.toString());
        current.clear();
      }
    } else {
      current.writeCharCode(char);
    }
  }

  if (current.isNotEmpty) args.add(current.toString());
  return args;
}

/// Runs [command], echoing its output unless [quiet].
///
/// Throws [ShellException] on a non-zero exit unless [throwOnError] is false.
/// [input] is written to stdin, which is otherwise closed at once. [shell] runs through
/// the system interpreter rather than exec'ing directly.
///
/// {@category System}
Future<ShellResult> run(
  String command, {
  Path? workdir,
  Map<String, String>? env,
  Duration? timeout,
  String? input,
  bool quiet = false,
  bool throwOnError = true,
  Encoding encoding = utf8,
  bool shell = false,
}) => _runProcess(
  command,
  workdir: workdir,
  env: env,
  timeout: timeout,
  input: input,
  quiet: quiet,
  throwOnError: throwOnError,
  encoding: encoding,
  shell: shell,
);

/// The environment children inherit: the process's plus [Env] overrides plus [extra].
Map<String, String>? _childEnv(Map<String, String>? extra) {
  final all = Env.all();
  if (extra != null) all.addAll(extra);
  return all;
}

Future<void> _feed(Process process, String? input, Encoding encoding) async {
  try {
    if (input != null) process.stdin.add(encoding.encode(input));
    await process.stdin.close();
  } catch (_) {}
}

/// Internal process execution implementation.
Future<ShellResult> _runProcess(
  String command, {
  List<String>? arguments,
  Path? workdir,
  Map<String, String>? env,
  Duration? timeout,
  String? input,
  bool quiet = false,
  bool throwOnError = true,
  Encoding encoding = utf8,
  bool shell = false,
}) async {
  final String executable;
  final List<String> args;
  final String displayCommand;

  if (arguments != null) {
    executable = command;
    args = arguments;
    displayCommand = args.isEmpty ? command : '$command ${args.map((a) => a.contains(' ') ? '"$a"' : a).join(' ')}';
  } else {
    final parts = _splitCommand(command.trim());
    if (parts.isEmpty) throw ArgumentError('Cannot execute an empty command string');
    executable = parts.first;
    args = parts.sublist(1);
    displayCommand = command;
  }

  final process = await Process.start(
    executable,
    args,
    workingDirectory: workdir?.path,
    environment: _childEnv(env),
    runInShell: shell || Platform.isWindows,
  );

  await _feed(process, input, encoding);

  final stdoutBuf = StringBuffer();
  final stderrBuf = StringBuffer();

  final stdoutFuture = process.stdout.transform(encoding.decoder).forEach((data) {
    stdoutBuf.write(data);
    if (!quiet) ConsoleIo.out.write(data);
  });

  final stderrFuture = process.stderr.transform(encoding.decoder).forEach((data) {
    stderrBuf.write(data);
    if (!quiet) ConsoleIo.err.write(data);
  });

  var exitCodeFuture = process.exitCode;
  if (timeout != null) {
    exitCodeFuture = exitCodeFuture.timeout(
      timeout,
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        throw TimeoutException('Command "$displayCommand" timed out after $timeout');
      },
    );
  }

  final code = await exitCodeFuture;
  await Future.wait([stdoutFuture, stderrFuture]);

  final result = ShellResult(
    command: displayCommand,
    exitCode: code,
    stdout: stdoutBuf.toString(),
    stderr: stderrBuf.toString(),
  );

  if (throwOnError && code != 0) throw ShellException(result);
  return result;
}

/// Locates the absolute path of an executable on the `PATH` seen by [Env].
///
/// Returns a [Path] to the binary if found, or `null` otherwise.
///
/// {@category System}
Future<Path?> which(String executable) async {
  final pathVar = Env.get('PATH') ?? '';
  final separator = Platform.isWindows ? ';' : ':';
  final paths = pathVar.split(separator).where((p) => p.isNotEmpty);

  final extensions = Platform.isWindows ? ['', ...?Env.get('PATHEXT')?.split(';')] : [''];

  final candidates = [
    for (final dir in paths)
      for (final ext in extensions) Path(dir) / '$executable$ext',
  ];
  final found = await Future.wait(candidates.map((c) => c.exists()));
  for (var i = 0; i < candidates.length; i++) {
    if (found[i]) return candidates[i];
  }

  return null;
}

/// Pipeline of chained system commands connected via standard streams (e.g. `cmd1 | cmd2 | cmd3`).
///
/// {@category System}
class CommandPipeline {
  final List<String> _commands;

  CommandPipeline(List<String> commands) : _commands = List.unmodifiable(commands);

  /// Pipes the output of this pipeline into another [next] command.
  CommandPipeline operator |(String next) => CommandPipeline([..._commands, next]);

  /// Executes this command pipeline asynchronously.
  ///
  /// Like `pipefail`: [ShellResult.exitCode] is the rightmost non-zero exit code, and
  /// [throwOnError] throws when any stage fails, not only the last.
  Future<ShellResult> run({
    Path? workdir,
    Map<String, String>? env,
    Duration? timeout,
    String? input,
    bool quiet = false,
    bool throwOnError = true,
    Encoding encoding = utf8,
  }) async {
    if (_commands.isEmpty) throw StateError('Cannot execute an empty command pipeline');

    if (_commands.length == 1) {
      return _runProcess(
        _commands.first,
        workdir: workdir,
        env: env,
        timeout: timeout,
        input: input,
        quiet: quiet,
        throwOnError: throwOnError,
        encoding: encoding,
      );
    }

    final processes = <Process>[];
    final environment = _childEnv(env);

    try {
      for (final cmd in _commands) {
        final parts = _splitCommand(cmd.trim());
        if (parts.isEmpty) throw ArgumentError('Empty command in pipeline');
        processes.add(
          await Process.start(
            parts.first,
            parts.sublist(1),
            workingDirectory: workdir?.path,
            environment: environment,
            runInShell: Platform.isWindows,
          ),
        );
      }

      await _feed(processes.first, input, encoding);
      for (var i = 0; i < processes.length - 1; i++) {
        processes[i].stdout.pipe(processes[i + 1].stdin).catchError((_) {});
      }

      final lastProcess = processes.last;
      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();

      final stdoutFuture = lastProcess.stdout.transform(encoding.decoder).forEach((data) {
        stdoutBuf.write(data);
        if (!quiet) ConsoleIo.out.write(data);
      });

      final stderrFuture = Future.wait(
        processes.map(
          (p) => p.stderr.transform(encoding.decoder).forEach((data) {
            stderrBuf.write(data);
            if (!quiet) ConsoleIo.err.write(data);
          }),
        ),
      );

      var exitCodesFuture = Future.wait(processes.map((p) => p.exitCode));
      if (timeout != null) {
        exitCodesFuture = exitCodesFuture.timeout(
          timeout,
          onTimeout: () => throw TimeoutException('Pipeline "${_commands.join(' | ')}" timed out after $timeout'),
        );
      }
      final exitCodes = await exitCodesFuture;
      await Future.wait([stdoutFuture, stderrFuture]);

      final exitCode = exitCodes.lastWhere((c) => c != 0, orElse: () => 0);
      final result = ShellResult(
        command: _commands.join(' | '),
        exitCode: exitCode,
        stdout: stdoutBuf.toString(),
        stderr: stderrBuf.toString(),
      );

      if (throwOnError && exitCode != 0) throw ShellException(result);
      return result;
    } finally {
      for (final p in processes) {
        p.kill();
      }
    }
  }
}

/// Pipeline construction on [String]: `('ls' | 'grep dart').run()`.
///
/// To run one command, use [run].
///
/// {@category System}
extension StringShellExtensions on String {
  /// Starts a command pipeline with this command piped into [next].
  CommandPipeline operator |(String next) => CommandPipeline([this, next]);
}

/// Extension on [Path] for executing scripts or binaries directly.
///
/// {@category System}
extension PathShellExtensions on Path {
  /// Runs the file at this path as a command, with [args] passed as-is (no splitting).
  Future<ShellResult> run({
    List<String> args = const [],
    Path? workdir,
    Map<String, String>? env,
    Duration? timeout,
    String? input,
    bool quiet = false,
    bool throwOnError = true,
    Encoding encoding = utf8,
    bool shell = false,
  }) => _runProcess(
    path,
    arguments: args,
    workdir: workdir,
    env: env,
    timeout: timeout,
    input: input,
    quiet: quiet,
    throwOnError: throwOnError,
    encoding: encoding,
    shell: shell,
  );
}

/// Shorthand getters on `Future<ShellResult>` for clean chaining.
///
/// {@category System}
extension FutureShellExtensions on Future<ShellResult> {
  /// The trimmed stdout text of the executed command.
  Future<String> get text => then((r) => r.text);

  /// The non-empty output lines of the executed command.
  Future<List<String>> get lines => then((r) => r.lines);

  /// The stdout of the executed command, parsed as JSON.
  Future<JsonDocument> get json => then((r) => r.json);

  /// Whether the command exited successfully with code 0.
  Future<bool> get ok => then((r) => r.ok);
}
