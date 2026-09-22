part of '../../process.dart';

/// Splits [command] as a POSIX shell would read a simple command: whitespace separates,
/// single quotes take everything literally, double quotes let `\\ \" \$ \`` escape, and an
/// unquoted backslash escapes the next character. No expansion of any kind.
List<String> _splitCommand(String command) {
  final args = <String>[];
  final current = StringBuffer();
  var quoted = false; // an empty quoted string is still an argument
  var inSingle = false;
  var inDouble = false;

  const backslash = 0x5c, singleQuote = 0x27, doubleQuote = 0x22, dollar = 0x24, backtick = 0x60;
  bool isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;

  for (var i = 0; i < command.length; i++) {
    final char = command.codeUnitAt(i);
    if (inSingle) {
      if (char == singleQuote) {
        inSingle = false;
      } else {
        current.writeCharCode(char);
      }
    } else if (inDouble) {
      if (char == doubleQuote) {
        inDouble = false;
      } else if (char == backslash && i + 1 < command.length) {
        final next = command.codeUnitAt(i + 1);
        if (next == backslash || next == doubleQuote || next == dollar || next == backtick) {
          current.writeCharCode(next);
          i++;
        } else {
          current.writeCharCode(char);
        }
      } else {
        current.writeCharCode(char);
      }
    } else if (char == backslash && i + 1 < command.length) {
      current.writeCharCode(command.codeUnitAt(++i));
    } else if (char == singleQuote) {
      inSingle = quoted = true;
    } else if (char == doubleQuote) {
      inDouble = quoted = true;
    } else if (isSpace(char)) {
      if (current.isNotEmpty || quoted) args.add(current.toString());
      current.clear();
      quoted = false;
    } else {
      current.writeCharCode(char);
    }
  }
  if (current.isNotEmpty || quoted) args.add(current.toString());
  return args;
}

const _shellKey = #dartToolkitShellScope;

/// The settings every command in a scope shares.
final class _Shell {
  final Path? workdir;
  final Map<String, String>? env;
  final Duration? timeout;
  final Encoding encoding;
  final bool quiet;
  final bool strict;

  const _Shell({this.workdir, this.env, this.timeout, this.encoding = utf8, this.quiet = false, this.strict = true});

  static _Shell get current => Zone.current[_shellKey] as _Shell? ?? const _Shell();

  _Shell merge({
    Path? workdir,
    Map<String, String>? env,
    Duration? timeout,
    Encoding? encoding,
    bool? quiet,
    bool? strict,
  }) => _Shell(
    workdir: workdir ?? this.workdir,
    env: env == null ? this.env : {...?this.env, ...env},
    timeout: timeout ?? this.timeout,
    encoding: encoding ?? this.encoding,
    quiet: quiet ?? this.quiet,
    strict: strict ?? this.strict,
  );
}

/// The ambient shell seam: what every command in a scope shares.
///
/// A working directory, an environment, a timeout or a failure policy that every command
/// would otherwise repeat belongs to the scope that sets it — the shape [Http.session] has
/// for a client. Anything genuinely per command — `input:`, `args:`, `shell:` — stays an
/// argument, and a per-call `workdir:` or `strict:` still wins over the session's.
///
/// ```dart
/// await Shell.session(() async {
///   await run('git fetch --all');
///   await run('git status --short');
/// }, workdir: repo, timeout: 30.s);
/// ```
///
/// {@category System}
class Shell {
  /// Runs [body] with these settings for every command inside it.
  ///
  /// [env] is added to the enclosing session's rather than replacing it.
  static Future<T> session<T>(
    FutureOr<T> Function() body, {
    Path? workdir,
    Map<String, String>? env,
    Duration? timeout,
    Encoding? encoding,
    bool? quiet,
    bool? strict,
  }) async {
    final scope = _Shell.current.merge(
      workdir: workdir,
      env: env,
      timeout: timeout,
      encoding: encoding,
      quiet: quiet,
      strict: strict,
    );
    return runZoned(() async => body(), zoneValues: {_shellKey: scope});
  }
}

/// Runs [command], echoing its output unless [quiet].
///
/// Throws [ShellException] on a non-zero exit unless [strict] is false. [input] is written
/// to stdin, which is otherwise closed at once. [shell] runs through the system interpreter
/// rather than exec'ing directly. Every argument here defaults to the enclosing
/// [Shell.session]'s, so a scope says `workdir:` once instead of every call.
///
/// [command] is split here, the way a POSIX shell reads a simple command — so **never
/// interpolate a scraped or user-supplied value into it**. Pass those as arguments, where
/// nothing re-reads them: `(await which('git'))!.run(args: ['commit', '-m', message])`. On
/// Windows every command goes through `cmd.exe` whatever [shell] says, which reinterprets
/// metacharacters in the string a second time.
///
/// {@category System}
Future<ShellResult> run(
  String command, {
  Path? workdir,
  Map<String, String>? env,
  Duration? timeout,
  String? input,
  bool? quiet,
  bool? strict,
  Encoding? encoding,
  bool shell = false,
}) => _runProcess(
  command,
  scope: _Shell.current.merge(
    workdir: workdir,
    env: env,
    timeout: timeout,
    encoding: encoding,
    quiet: quiet,
    strict: strict,
  ),
  input: input,
  shell: shell,
);

/// The environment children inherit: the process's plus [Env] overrides plus [extra], or
/// `null` — inherit as is — when there is nothing to add.
Map<String, String>? _childEnv(Map<String, String>? extra) {
  if (extra == null && !Env.hasOverrides) return null;
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
  required _Shell scope,
  List<String>? arguments,
  String? input,
  bool shell = false,
}) async {
  final _Shell(:workdir, :env, :timeout, :encoding, :quiet, :strict) = scope;
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

  final stdoutBuf = StringBuffer();
  final stderrBuf = StringBuffer();

  // Readers first: a child that echoes a large [input] fills its stdout pipe and stops
  // reading stdin, so feeding before draining deadlocks both sides.
  final stdoutFuture = process.stdout.transform(encoding.decoder).forEach((data) {
    stdoutBuf.write(data);
    if (!quiet) Io.out.write(data);
  });

  final stderrFuture = process.stderr.transform(encoding.decoder).forEach((data) {
    stderrBuf.write(data);
    if (!quiet) Io.err.write(data);
  });

  final fed = _feed(process, input, encoding);

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
  await Future.wait([stdoutFuture, stderrFuture, fed]);

  final result = ShellResult(
    command: displayCommand,
    exitCode: code,
    stdout: stdoutBuf.toString(),
    stderr: stderrBuf.toString(),
  );

  if (strict && code != 0) throw ShellException(result);
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
  /// [strict] throws when any stage fails, not only the last. Unset arguments come from
  /// the enclosing [Shell.session].
  Future<ShellResult> run({
    Path? workdir,
    Map<String, String>? env,
    Duration? timeout,
    String? input,
    bool? quiet,
    bool? strict,
    Encoding? encoding,
  }) async {
    if (_commands.isEmpty) throw StateError('Cannot execute an empty command pipeline');
    final scope = _Shell.current.merge(
      workdir: workdir,
      env: env,
      timeout: timeout,
      encoding: encoding,
      quiet: quiet,
      strict: strict,
    );

    if (_commands.length == 1) {
      return _runProcess(_commands.first, scope: scope, input: input);
    }

    final processes = <Process>[];
    final environment = _childEnv(scope.env);

    try {
      for (final cmd in _commands) {
        final parts = _splitCommand(cmd.trim());
        if (parts.isEmpty) throw ArgumentError('Empty command in pipeline');
        processes.add(
          await Process.start(
            parts.first,
            parts.sublist(1),
            workingDirectory: scope.workdir?.path,
            environment: environment,
            runInShell: Platform.isWindows,
          ),
        );
      }

      for (var i = 0; i < processes.length - 1; i++) {
        processes[i].stdout.pipe(processes[i + 1].stdin).catchError((_) {});
      }
      final fed = _feed(processes.first, input, scope.encoding);

      final lastProcess = processes.last;
      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();

      final stdoutFuture = lastProcess.stdout.transform(scope.encoding.decoder).forEach((data) {
        stdoutBuf.write(data);
        if (!scope.quiet) Io.out.write(data);
      });

      final stderrFuture = Future.wait(
        processes.map(
          (p) => p.stderr.transform(scope.encoding.decoder).forEach((data) {
            stderrBuf.write(data);
            if (!scope.quiet) Io.err.write(data);
          }),
        ),
      );

      var exitCodesFuture = Future.wait(processes.map((p) => p.exitCode));
      if (scope.timeout case final limit?) {
        exitCodesFuture = exitCodesFuture.timeout(
          limit,
          onTimeout: () =>
              throw TimeoutException('Pipeline "${_commands.join(' | ')}" timed out after ${scope.timeout}'),
        );
      }
      final exitCodes = await exitCodesFuture;
      await Future.wait([stdoutFuture, stderrFuture, fed]);

      final exitCode = exitCodes.lastWhere((c) => c != 0, orElse: () => 0);
      final result = ShellResult(
        command: _commands.join(' | '),
        exitCode: exitCode,
        stdout: stdoutBuf.toString(),
        stderr: stderrBuf.toString(),
      );

      if (scope.strict && exitCode != 0) throw ShellException(result);
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
  ///
  /// Unset arguments come from the enclosing [Shell.session]; see [run].
  Future<ShellResult> run({
    List<String> args = const [],
    Path? workdir,
    Map<String, String>? env,
    Duration? timeout,
    String? input,
    bool? quiet,
    bool? strict,
    Encoding? encoding,
    bool shell = false,
  }) => _runProcess(
    path,
    scope: _Shell.current.merge(
      workdir: workdir,
      env: env,
      timeout: timeout,
      encoding: encoding,
      quiet: quiet,
      strict: strict,
    ),
    arguments: args,
    input: input,
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

  /// Whether the command exited successfully with code 0.
  Future<bool> get isOk => then((r) => r.isOk);
}
