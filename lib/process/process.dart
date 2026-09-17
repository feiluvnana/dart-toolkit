import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../util/stdio.dart';
import '../fs/path.dart';
import '../util/env.dart';
import 'shell_result.dart';

export 'shell_result.dart';

List<String> _splitCommand(String command) {
  final args = <String>[];
  final current = StringBuffer();
  var inSingle = false;
  var inDouble = false;
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

    if (char == "'" && !inDouble) {
      inSingle = !inSingle;
      continue;
    }

    if (char == '"' && !inSingle) {
      inDouble = !inDouble;
      continue;
    }

    if (char == ' ' && !inSingle && !inDouble) {
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
/// Pass [shell]: `true` to execute through the system shell interpreter (`cmd.exe` on Windows, `/bin/sh` on POSIX).
///
/// {@category System}
Future<ShellResult> run(
  String command, {
  Path? workdir,
  Map<String, String>? env,
  Duration? timeout,
  bool quiet = false,
  bool throwOnError = true,
  Encoding encoding = utf8,
  bool shell = false,
}) => _runProcess(
  command,
  workdir: workdir,
  env: env,
  timeout: timeout,
  quiet: quiet,
  throwOnError: throwOnError,
  encoding: encoding,
  shell: shell,
);

/// Shorthand alias for [run].
///
/// {@category System}
Future<ShellResult> $(
  String command, {
  Path? workdir,
  Map<String, String>? env,
  Duration? timeout,
  bool quiet = false,
  bool throwOnError = true,
  Encoding encoding = utf8,
  bool shell = false,
}) => run(
  command,
  workdir: workdir,
  env: env,
  timeout: timeout,
  quiet: quiet,
  throwOnError: throwOnError,
  encoding: encoding,
  shell: shell,
);

/// Internal process execution implementation.
Future<ShellResult> _runProcess(
  String command, {
  List<String>? arguments,
  Path? workdir,
  Map<String, String>? env,
  Duration? timeout,
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
    if (parts.isEmpty) {
      throw ArgumentError('Cannot execute an empty command string');
    }
    executable = parts.first;
    args = parts.sublist(1);
    displayCommand = command;
  }

  final mergedEnv = {...Env.all(), ...?env};

  final process = await Process.start(
    executable,
    args,
    workingDirectory: workdir?.path,
    environment: mergedEnv,
    runInShell: shell || Platform.isWindows,
  );

  try {
    await process.stdin.close();
  } catch (_) {}

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
/// {@category System}
Future<Path?> which(String executable) async {
  final pathVar = Platform.environment['PATH'] ?? '';
  final separator = Platform.isWindows ? ';' : ':';
  final paths = pathVar.split(separator).where((p) => p.isNotEmpty);

  final extensions = Platform.isWindows
      ? (Platform.environment['PATHEXT']?.split(';') ?? ['.exe', '.bat', '.cmd'])
      : [''];

  for (final dir in paths) {
    for (final ext in extensions) {
      final candidate = Path(dir) / '$executable$ext';
      if (await candidate.exists()) {
        return candidate;
      }
    }
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
  CommandPipeline pipe(String next) => CommandPipeline([..._commands, next]);

  /// Alias for [pipe].
  CommandPipeline operator |(String next) => pipe(next);

  /// Executes this command pipeline asynchronously.
  Future<ShellResult> run({
    Path? workdir,
    Map<String, String>? env,
    Duration? timeout,
    bool quiet = false,
    bool throwOnError = true,
    Encoding encoding = utf8,
  }) async {
    if (_commands.isEmpty) {
      throw StateError('Cannot execute an empty command pipeline');
    }

    if (_commands.length == 1) {
      return _runProcess(
        _commands.first,
        workdir: workdir,
        env: env,
        timeout: timeout,
        quiet: quiet,
        throwOnError: throwOnError,
        encoding: encoding,
      );
    }

    final processes = <Process>[];
    final mergedEnv = {...Env.all(), ...?env};

    try {
      for (final cmd in _commands) {
        final parts = _splitCommand(cmd.trim());
        if (parts.isEmpty) {
          throw ArgumentError('Empty command in pipeline');
        }
        final p = await Process.start(
          parts.first,
          parts.sublist(1),
          workingDirectory: workdir?.path,
          environment: mergedEnv,
          runInShell: Platform.isWindows,
        );
        processes.add(p);
      }

      for (var i = 0; i < processes.length - 1; i++) {
        final current = processes[i];
        final next = processes[i + 1];
        current.stdout.pipe(next.stdin).catchError((_) {});
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
///
/// {@category System}
extension ShellStringExtension on String {
  /// Executes this string as a system command.
  Future<ShellResult> run({
    Path? workdir,
    Map<String, String>? env,
    Duration? timeout,
    bool quiet = false,
    bool throwOnError = true,
    Encoding encoding = utf8,
    bool shell = false,
  }) => _runProcess(
    this,
    workdir: workdir,
    env: env,
    timeout: timeout,
    quiet: quiet,
    throwOnError: throwOnError,
    encoding: encoding,
    shell: shell,
  );

  /// Starts a command pipeline with this command piped into [next].
  CommandPipeline pipe(String next) => CommandPipeline([this, next]);

  /// Alias for [pipe].
  CommandPipeline operator |(String next) => pipe(next);
}

/// Extension on [Path] for executing scripts or binaries directly.
///
/// {@category System}
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
    bool shell = false,
  }) => _runProcess(
    path,
    arguments: args,
    workdir: workdir,
    env: env,
    timeout: timeout,
    quiet: quiet,
    throwOnError: throwOnError,
    encoding: encoding,
    shell: shell,
  );
}

/// Shorthand getters on `Future<ShellResult>` for clean chaining.
///
/// {@category System}
extension FutureShellResultExtension on Future<ShellResult> {
  /// The trimmed stdout text of the executed command.
  Future<String> get text => then((r) => r.text);

  /// The non-empty output lines of the executed command.
  Future<List<String>> get lines => then((r) => r.lines);

  /// The decoded JSON payload of the executed command.
  Future<dynamic> get json => then((r) => r.json);

  /// Whether the command exited successfully with code 0.
  Future<bool> get ok => then((r) => r.ok);
}
