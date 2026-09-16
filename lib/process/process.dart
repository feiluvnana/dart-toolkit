import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../fs/path.dart';
import 'shell_result.dart';

export 'shell_result.dart';

/// Splits a command-line string into executable name and arguments list,
/// respecting single and double quotes and escaped spaces.
List<String> _splitCommand(String command) {
  final args = <String>[];
  final current = StringBuffer();
  var inSingleQuote = false;
  var inDoubleQuote = false;
  var isEscaped = false;

  for (var i = 0; i < command.length; i++) {
    final char = command[i];

    if (isEscaped) {
      current.write(char);
      isEscaped = false;
      continue;
    }

    if (char == r'\') {
      isEscaped = true;
      continue;
    }

    if (char == "'" && !inDoubleQuote) {
      inSingleQuote = !inSingleQuote;
      continue;
    }

    if (char == '"' && !inSingleQuote) {
      inDoubleQuote = !inDoubleQuote;
      continue;
    }

    if (char.trim().isEmpty && !inSingleQuote && !inDoubleQuote) {
      if (current.isNotEmpty) {
        args.add(current.toString());
        current.clear();
      }
      continue;
    }

    current.write(char);
  }

  if (current.isNotEmpty) {
    args.add(current.toString());
  }

  return args;
}

/// Executes a system [command] asynchronously.
///
/// If [quiet] is `false` (default), stdout and stderr are echoed live to the console.
/// If [throwOnError] is `true` (default), a [ShellException] is thrown if the process exits with non-zero code.
///
/// Example:
/// ```dart
/// final res = await run('git status');
/// final branch = await run('git branch --show-current', quiet: true);
/// ```
Future<ShellResult> run(
  String command, {
  Path? workdir,
  Map<String, String>? env,
  Duration? timeout,
  bool quiet = false,
  bool throwOnError = true,
  Encoding encoding = utf8,
}) =>
    _runProcess(
      command,
      workdir: workdir,
      env: env,
      timeout: timeout,
      quiet: quiet,
      throwOnError: throwOnError,
      encoding: encoding,
    );

/// Shorthand alias for [run].
///
/// Example:
/// ```dart
/// final branch = await $('git branch --show-current', quiet: true);
/// ```
Future<ShellResult> $(
  String command, {
  Path? workdir,
  Map<String, String>? env,
  Duration? timeout,
  bool quiet = false,
  bool throwOnError = true,
  Encoding encoding = utf8,
}) =>
    run(
      command,
      workdir: workdir,
      env: env,
      timeout: timeout,
      quiet: quiet,
      throwOnError: throwOnError,
      encoding: encoding,
    );

/// Internal process execution implementation.
Future<ShellResult> _runProcess(
  String command, {
  Path? workdir,
  Map<String, String>? env,
  Duration? timeout,
  bool quiet = false,
  bool throwOnError = true,
  Encoding encoding = utf8,
}) async {
  final parts = _splitCommand(command.trim());
  if (parts.isEmpty) {
    throw ArgumentError('Cannot execute an empty command string');
  }

  final executable = parts.first;
  final arguments = parts.sublist(1);

  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workdir?.path,
    environment: env,
    runInShell: Platform.isWindows,
  );

  // Close stdin immediately since interactive stdin is not needed for non-interactive run
  try {
    await process.stdin.close();
  } catch (_) {}

  final stdoutBuf = StringBuffer();
  final stderrBuf = StringBuffer();

  final stdoutFuture = process.stdout.transform(encoding.decoder).forEach((data) {
    stdoutBuf.write(data);
    if (!quiet) stdout.write(data);
  });

  final stderrFuture = process.stderr.transform(encoding.decoder).forEach((data) {
    stderrBuf.write(data);
    if (!quiet) stderr.write(data);
  });

  var exitCodeFuture = process.exitCode;
  if (timeout != null) {
    exitCodeFuture = exitCodeFuture.timeout(
      timeout,
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        throw TimeoutException('Command "$command" timed out after $timeout');
      },
    );
  }

  final code = await exitCodeFuture;
  await Future.wait([stdoutFuture, stderrFuture]);

  final result = ShellResult(
    command: command,
    exitcode: code,
    stdout: stdoutBuf.toString(),
    stderr: stderrBuf.toString(),
  );

  if (throwOnError && code != 0) {
    throw ShellException(result);
  }

  return result;
}

/// Locates the absolute path of an executable on the system `PATH`.
///
/// Returns a [Path] to the binary if found, or `null` otherwise.
///
/// Example:
/// ```dart
/// final gitPath = await which('git');
/// ```
Future<Path?> which(String executable) async {
  if (executable.isEmpty) return null;

  // Direct absolute or relative path given
  if (executable.contains('/') || (Platform.isWindows && executable.contains(r'\'))) {
    final direct = Path(executable);
    if (await direct.exist()) return direct;
  }

  final pathEnv = Platform.environment['PATH'] ?? '';
  final separator = Platform.isWindows ? ';' : ':';
  final paths = pathEnv.split(separator).where((p) => p.isNotEmpty);

  final extensions = Platform.isWindows ? ['', '.exe', '.bat', '.cmd'] : [''];

  for (final dir in paths) {
    for (final ext in extensions) {
      final candidate = Path(dir) / '$executable$ext';
      if (await candidate.exist()) {
        return candidate;
      }
    }
  }

  return null;
}

/// Represents a sequence of piped shell commands.
class CommandPipeline {
  final List<String> _commands;

  CommandPipeline(List<String> commands) : _commands = List.unmodifiable(commands);

  /// Appends [next] command to the pipeline.
  CommandPipeline pipe(String next) => CommandPipeline([..._commands, next]);

  /// Alias for [pipe].
  CommandPipeline operator |(String next) => pipe(next);

  /// Executes the pipeline, piping stdout from each process into stdin of the next.
  Future<ShellResult> run({
    Path? workdir,
    Map<String, String>? env,
    Duration? timeout,
    bool quiet = false,
    bool throwOnError = true,
  }) async {
    if (_commands.isEmpty) {
      throw StateError('Pipeline contains no commands');
    }

    if (_commands.length == 1) {
      return _runProcess(
        _commands.first,
        workdir: workdir,
        env: env,
        timeout: timeout,
        quiet: quiet,
        throwOnError: throwOnError,
      );
    }

    final processes = <Process>[];
    try {
      for (var i = 0; i < _commands.length; i++) {
        final parts = _splitCommand(_commands[i].trim());
        final proc = await Process.start(
          parts.first,
          parts.sublist(1),
          workingDirectory: workdir?.path,
          environment: env,
          runInShell: Platform.isWindows,
        );
        processes.add(proc);
      }

      // Close stdin of first process
      try {
        await processes.first.stdin.close();
      } catch (_) {}

      // Pipe intermediates
      for (var i = 0; i < processes.length - 1; i++) {
        processes[i].stdout.pipe(processes[i + 1].stdin).catchError((_) {});
      }

      final lastProcess = processes.last;
      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();

      final stdoutFuture = lastProcess.stdout.transform(utf8.decoder).forEach((data) {
        stdoutBuf.write(data);
        if (!quiet) stdout.write(data);
      });

      final stderrFuture = lastProcess.stderr.transform(utf8.decoder).forEach((data) {
        stderrBuf.write(data);
        if (!quiet) stderr.write(data);
      });

      final exitCodes = await Future.wait(processes.map((p) => p.exitCode));
      await Future.wait([stdoutFuture, stderrFuture]);

      final lastExitCode = exitCodes.last;
      final result = ShellResult(
        command: _commands.join(' | '),
        exitcode: lastExitCode,
        stdout: stdoutBuf.toString(),
        stderr: stderrBuf.toString(),
      );

      if (throwOnError && lastExitCode != 0) {
        throw ShellException(result);
      }

      return result;
    } finally {
      for (final p in processes) {
        p.kill();
      }
    }
  }
}

/// Extension on [String] for concise command execution and piping.
extension ShellStringExtension on String {
  /// Executes this string as a system command.
  Future<ShellResult> run({
    Path? workdir,
    Map<String, String>? env,
    Duration? timeout,
    bool quiet = false,
    bool throwOnError = true,
    Encoding encoding = utf8,
  }) =>
      _runProcess(
        this,
        workdir: workdir,
        env: env,
        timeout: timeout,
        quiet: quiet,
        throwOnError: throwOnError,
        encoding: encoding,
      );

  /// Starts a command pipeline with this command piped into [next].
  CommandPipeline pipe(String next) => CommandPipeline([this, next]);

  /// Alias for [pipe].
  CommandPipeline operator |(String next) => pipe(next);
}

/// Extension on [Path] for executing scripts or binaries directly.
extension ShellPathExtension on Path {
  /// Executes the file or binary at this path as a system command.
  ///
  /// Example:
  /// ```dart
  /// final res = await (Path.current / 'scripts/deploy.sh').run(args: ['--prod']);
  /// ```
  Future<ShellResult> run({
    List<String> args = const [],
    Path? workdir,
    Map<String, String>? env,
    Duration? timeout,
    bool quiet = false,
    bool throwOnError = true,
    Encoding encoding = utf8,
  }) {
    final cmd = args.isEmpty ? path : '$path ${args.map((a) => a.contains(' ') ? '"$a"' : a).join(' ')}';
    return _runProcess(
      cmd,
      workdir: workdir,
      env: env,
      timeout: timeout,
      quiet: quiet,
      throwOnError: throwOnError,
      encoding: encoding,
    );
  }
}
