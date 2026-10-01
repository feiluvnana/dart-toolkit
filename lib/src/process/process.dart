part of '../../process.dart';

/// Splits [command] as a POSIX shell reads a simple command, with no expansion.
///
/// An unclosed quote is a [FormatException]; unquoted shell syntax (`|`, `;`, `$(`, …) an
/// [ArgumentError], since exec'd directly `a | wc -l` would hand `|` to `a` without a word.
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
    } else if (_shellSyntax(command, i, current.isEmpty) case final syntax?) {
      final hint = switch (syntax) {
        '`*`' || '`?`' || '`[`' => 'pass shell: true, or expand with Path.glob',
        _ => "pass shell: true, or pipe with ('a' | 'b').run()",
      };
      throw ArgumentError('"$command" uses $syntax, which only a shell reads: $hint');
    } else {
      current.writeCharCode(char);
    }
  }
  if (inSingle || inDouble) {
    throw FormatException('Unterminated ${inSingle ? 'single' : 'double'} quote', command, command.length);
  }
  if (current.isNotEmpty || quoted) args.add(current.toString());
  return args;
}

/// The shell operator starting at [i] of [command], unquoted, or `null`.
String? _shellSyntax(String command, int i, bool atStartOfWord) {
  final char = command[i];
  if ('|&;<>`*?['.contains(char) || (atStartOfWord && char == '~')) return '`$char`';
  if (char == r'$' && i + 1 < command.length) {
    if (command[i + 1] == '(') return r'`$(`';
    if (command[i + 1] == '{') return r'`${`';
    final next = command.codeUnitAt(i + 1);
    if (_isIdentStart(next)) {
      var j = i + 1;
      while (j < command.length && _isIdentChar(command.codeUnitAt(j))) {
        j++;
      }
      return '`\$${command.substring(i + 1, j)}`';
    }
  }
  return null;
}

bool _isIdentStart(int c) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f; // A-Z, a-z, _
bool _isIdentChar(int c) => _isIdentStart(c) || (c >= 0x30 && c <= 0x39); // A-Z, a-z, _, 0-9

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

  /// A decoder that never fails a command over its output: a stray byte is `U+FFFD`.
  Converter<List<int>, String> get decoder =>
      identical(encoding, utf8) ? const Utf8Decoder(allowMalformed: true) : encoding.decoder;
}

/// The per-call settings of [run], [PathShellExtensions.run] and [CommandPipeline.run].
typedef _Given = ({
  Path? workdir,
  Map<String, String>? env,
  Duration? timeout,
  Encoding? encoding,
  bool? quiet,
  bool? strict,
});

/// What every command in a scope shares: working directory, environment, timeout, encoding
/// and failure policy. A per-call argument still wins.
///
/// ```dart
/// await Shell.scope(() async {
///   await run('git fetch --all');
///   await run('git status --short');
/// }, workdir: repo, timeout: 30.s);
/// ```
///
/// {@category System}
class Shell {
  /// Runs [body] with these settings for every command inside it.
  ///
  /// [env] is added to the enclosing scope's rather than replacing it.
  static Future<T> scope<T>(
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
/// Throws [ShellException] on a non-zero exit unless [strict] is false; a missing executable
/// is exit 127, as in a shell. [input] is written to stdin, otherwise closed at once.
/// [inherit] gives the child this terminal (`git commit`, `ssh`, `vim`); nothing is captured
/// then. Unset arguments come from the enclosing [Shell.scope].
///
/// The enclosing [Cancel.scope] stops it — SIGTERM to the child and everything it started,
/// SIGKILL two seconds later — and this throws [CancelledException]; a [timeout] does the
/// same and throws [ShellTimeoutException] with what was printed so far.
///
/// [command] is split as a POSIX shell reads a simple command and exec'd directly, so
/// **never interpolate a scraped or user-supplied value into it**: pass it in [args], which
/// is never re-read: `run('git commit -m', args: [message])`. Unquoted `|`, `&&` or `>` is an
/// [ArgumentError]; [shell] hands the string to `/bin/sh -c` (`cmd /c` on Windows) with
/// [args] as `$1`, `$2`…: `run(r'grep -c "$1" *.log', shell: true, args: [pattern])`.
///
/// On Windows only a `.bat`, a `.cmd` or a `cmd.exe` built-in goes through `cmd.exe`, and
/// there an argument holding `& | < > ^ % "` or a newline is an [ArgumentError].
///
/// The [ShellRun] that comes back is a future whose readings say what the caller wants:
/// `await run('git diff --quiet').isOk` neither throws nor echoes.
///
/// {@category System}
ShellRun run(
  String command, {
  List<String> args = const [],
  Path? workdir,
  Map<String, String>? env,
  Duration? timeout,
  String? input,
  bool? quiet,
  bool? strict,
  Encoding? encoding,
  bool shell = false,
  bool inherit = false,
}) => ShellRun._((scope, control) {
  final display = _display(command, args);
  if (shell) {
    if (Platform.isWindows && args.isNotEmpty) {
      throw ArgumentError('args: cannot be passed with shell: true on Windows');
    }
    final stage = Platform.isWindows
        ? ('cmd', ['/c', command])
        : ('/bin/sh', ['-c', command, 'sh', ...args]); // `sh` is $0; args are $1…
    return _exec([stage], display, scope, control, input: input, inherit: inherit);
  }
  final parts = _splitCommand(command.trim());
  if (parts.isEmpty) throw ArgumentError('Cannot execute an empty command string');
  return _exec(
    [
      (parts.first, [...parts.skip(1), ...args]),
    ],
    display,
    scope,
    control,
    input: input,
    inherit: inherit,
    viaShell: Platform.isWindows,
  );
}, (workdir: workdir, env: env, timeout: timeout, encoding: encoding, quiet: quiet, strict: strict));

/// How a command reads in an error or an echo: [args] quoted where a space would split them.
String _display(String command, List<String> args) =>
    args.isEmpty ? command : '$command ${args.map((a) => a.contains(' ') || a.isEmpty ? '"$a"' : a).join(' ')}';

final _cmdUnsafe = RegExp(r'[&|<>^%"\r\n]');

/// [args], refused if `cmd.exe` would read one as more than an argument: `cmd` has no
/// reliable quoting (`%VAR%` expands inside quotes), so the only safe argument is one
/// without its metacharacters ("BatBadBut").
List<String> _cmdSafe(List<String> args) {
  for (final arg in args) {
    if (arg.contains(_cmdUnsafe)) {
      throw ArgumentError.value(arg, 'args', 'cannot be passed through cmd.exe safely');
    }
  }
  return args;
}

/// A command on its way: a `Future<ShellResult>`, and the readings on it.
///
/// It starts in a microtask, so a reading chained onto [run] still says how it runs:
/// [text] and [lines] imply `quiet: true`, [isOk] also `strict: false`. An argument given
/// to [run] still wins.
///
/// ```dart
/// final branch = await run('git rev-parse --abbrev-ref HEAD').text;   // not echoed
/// if (!await run('git diff --quiet').isOk) Console.warn('uncommitted changes');
/// ```
///
/// {@category System}
final class ShellRun implements Future<ShellResult> {
  final Future<ShellResult> Function(_Shell scope, _Control control) _start;
  final _Shell _scope;
  final bool? _quiet;
  final bool? _strict;
  bool _wantsOutput = false;
  bool _wantsAnswer = false;
  final _control = _Control();

  /// The enclosing [Shell.scope] is read here, in the caller's zone, not when it starts.
  ShellRun._(this._start, _Given given)
    : _scope = _Shell.current.merge(
        workdir: given.workdir,
        env: given.env,
        timeout: given.timeout,
        encoding: given.encoding,
      ),
      _quiet = given.quiet,
      _strict = given.strict {
    scheduleMicrotask(() => _result);
  }

  late final Future<ShellResult> _result = Future.sync(
    () => _start(
      _scope.merge(
        quiet: _quiet ?? (_wantsOutput || _wantsAnswer ? true : null),
        strict: _strict ?? (_wantsAnswer ? false : null),
      ),
      _control,
    ),
  );

  /// Its stdout a line at a time as it is printed, not echoed. A failure is the stream's
  /// error after the lines before it; cancelling stops the command and what it started.
  ///
  /// ```dart
  /// await for (final line in run('tail -f app.log').stream) {
  ///   if (line.contains('ready')) break;   // tail is stopped
  /// }
  /// ```
  Stream<String> get stream {
    if (_control.lines case final lines?) return lines.stream;
    final lines = _control.lines = StreamController<String>(
      onCancel: () => _control.stop(const CancelledException('The stream was cancelled.')),
    );
    _result.then(
      (_) => lines.close(),
      onError: (Object error, StackTrace trace) {
        if (_control.stopped == null) lines.addError(error, trace);
        lines.close();
      },
    );
    return lines.stream;
  }

  /// Stops it and everything it started — SIGTERM, then SIGKILL after two seconds — and
  /// completes once they are gone:
  ///
  /// ```dart
  /// final server = run('dart run bin/server.dart');
  /// await run('dart test');
  /// await server.kill();
  /// ```
  ///
  /// Awaiting the run afterwards throws [CancelledException], unless it had already ended.
  Future<void> kill() async {
    _control.stop(const CancelledException('The command was killed.'));
    await _result.then((_) {}, onError: (_) {});
  }

  /// The trimmed stdout, not echoed.
  Future<String> get text => (this.._wantsOutput = true)._result.then((r) => r.text);

  /// The non-empty, trimmed stdout lines, not echoed.
  Future<List<String>> get lines => (this.._wantsOutput = true)._result.then((r) => r.lines);

  /// Whether it exited 0 — never a [ShellException], and not echoed.
  Future<bool> get isOk => (this.._wantsAnswer = true)._result.then((r) => r.isOk);

  @override
  Future<R> then<R>(FutureOr<R> Function(ShellResult value) onValue, {Function? onError}) =>
      _result.then(onValue, onError: onError);

  @override
  Future<ShellResult> catchError(Function onError, {bool Function(Object error)? test}) =>
      _result.catchError(onError, test: test);

  @override
  Future<ShellResult> whenComplete(FutureOr<void> Function() action) => _result.whenComplete(action);

  @override
  Future<ShellResult> timeout(Duration timeLimit, {FutureOr<ShellResult> Function()? onTimeout}) =>
      _result.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Stream<ShellResult> asStream() => _result.asStream();
}

/// Where [ShellRun.stream]'s lines go, and how a cancelled stream or [ShellRun.kill] stops it.
final class _Control {
  StreamController<String>? lines;

  /// Set by the command once its processes are up.
  void Function(Object why)? halt;

  /// Why the caller stopped it, so nobody is handed the error that causes.
  Object? stopped;

  /// Stops the command now, or as soon as it is up.
  void stop(Object why) {
    stopped ??= why;
    halt?.call(why);
  }
}

/// The environment children inherit: the process's plus [Env] overrides plus [extra].
Map<String, String> _childEnv(Map<String, String>? extra) => {...Env.all(), ...?extra};

Future<void> _feed(Process process, String? input, Encoding encoding) async {
  try {
    if (input != null) process.stdin.add(encoding.encode(input));
    await process.stdin.close();
  } catch (_) {}
}

/// How long a stopped child has between SIGTERM and SIGKILL.
const _grace = Duration(seconds: 2);

/// Runs [stages] as a pipeline: each stdout feeds the next; the last stdout and every stderr
/// are captured; the exit code is the rightmost non-zero one, like `pipefail`.
Future<ShellResult> _exec(
  List<(String, List<String>)> stages,
  String display,
  _Shell scope,
  _Control control, {
  String? input,
  bool inherit = false,
  bool viaShell = false,
}) async {
  final streamed = control.lines;
  if (inherit && input != null) throw ArgumentError('input: cannot be given to a child that inherits stdin');
  if (inherit && streamed != null) throw ArgumentError('stream cannot read a child that inherits stdout');

  ShellResult refused(int code, String stderr) {
    final result = ShellResult(command: display, exitCode: code, stdout: '', stderr: stderr);
    if (scope.strict) throw ShellException(result);
    return result;
  }

  if (scope.workdir case final workdir?
      when (await FileStat.stat(workdir.path)).type == FileSystemEntityType.notFound) {
    return refused(127, 'No such working directory: ${workdir.path}\n');
  }

  Future<ShellResult> execute() async {
    final token = Cancel.token;
    token?.throwIfCancelled();
    final processes = <Process>[];
    final environment = _childEnv(scope.env);
    try {
      for (final (executable, args) in stages) {
        final (exe, cmd) = viaShell ? await _windowsTarget(executable) : (executable, false);
        processes.add(
          await Process.start(
            exe,
            cmd ? _cmdSafe(args) : args,
            workingDirectory: scope.workdir?.path,
            environment: environment,
            runInShell: cmd,
            mode: inherit ? ProcessStartMode.inheritStdio : ProcessStartMode.normal,
          ),
        );
      }
    } on ProcessException catch (e) {
      for (final p in processes) {
        p.kill(ProcessSignal.sigkill);
      }
      // A shell's codes: 126 for a file that cannot be run, 127 for none at all.
      return refused(e.errorCode == 13 ? 126 : 127, '${e.message}: ${e.executable}\n');
    }

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    final subscriptions = <StreamSubscription<String>>[];
    final drained = <Future<void>>[];
    void capture(Stream<List<int>> stream, StringBuffer into, {required bool err}) {
      final echo = (scope.quiet || (!err && streamed != null)) ? null : _Echo(err: err);
      final done = Completer<void>();
      final lines = err ? null : streamed;
      var text = stream.transform(scope.decoder);
      if (lines != null) {
        // The live lines are the output; the buffer keeps them for the result.
        text = text.transform(const LineSplitter()).map((line) {
          lines.add(line);
          return '$line\n';
        });
      }
      subscriptions.add(
        text.listen(
          (data) {
            into.write(data);
            echo?.add(data);
          },
          onError: (Object _) {
            echo?.close();
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            echo?.close();
            if (!done.isCompleted) done.complete();
          },
        ),
      );
      drained.add(done.future);
    }

    var fed = Future<void>.value();
    if (!inherit) {
      // Readers first: a child that echoes a large [input] fills its stdout pipe and stops
      // reading stdin, so feeding before draining deadlocks both sides.
      for (var i = 0; i < processes.length - 1; i++) {
        processes[i].stdout.pipe(processes[i + 1].stdin).catchError((_) {});
      }
      capture(processes.last.stdout, stdoutBuf, err: false);
      for (final p in processes) {
        capture(p.stderr, stderrBuf, err: true);
      }
      fed = _feed(processes.first, input, scope.encoding);
    }

    // Why it is being stopped, once something decides it is: a timeout or the scope's token.
    final stop = Completer<Object>();
    var tree = const <int>[];
    void halt(Object why) {
      if (stop.isCompleted) return;
      // Synchronously, so a signal that is about to end this process still reaches them.
      tree = _signalTree([for (final p in processes) p.pid], ProcessSignal.sigterm);
      ProcessBridge.registerHalted(tree);
      stop.complete(why);
    }

    final timer = scope.timeout == null
        ? null
        : Timer(scope.timeout!, () => halt(TimeoutException('"$display" timed out after ${scope.timeout}')));
    final unregister = token?.onCancel(
      () => halt(CancelledException(token.reason?.toString() ?? 'Operation was cancelled.')),
    );
    control.halt = halt;
    if (control.stopped case final why?) halt(why);
    final ended = <int>[];
    final exits = Future.wait([
      for (final (i, p) in processes.indexed) p.exitCode.then((code) => (ended..add(i), code).$2),
    ]);
    // The output is waited for under the same timeout and cancel as the exits: a background
    // child left holding stdout open (`sleep 60 &`) would otherwise hold this call with it.
    final settled = await Future.any<Object>([
      exits.then((codes) async => (await Future.wait([...drained, fed]), codes).$2),
      stop.future,
    ]);
    timer?.cancel();
    unregister?.call();

    ShellResult result(int code) =>
        ShellResult(command: display, exitCode: code, stdout: '$stdoutBuf', stderr: '$stderrBuf');

    if (settled is! List<int>) {
      await _reap(tree);
      for (final s in subscriptions) {
        await s.cancel();
      }
      throw switch (settled) {
        TimeoutException(:final message, :final duration) => ShellTimeoutException(result(-1), message, duration),
        _ => settled,
      };
    }
    bool isBrokenPipe(int i, int code) =>
        i + 1 < settled.length &&
        (code == -13 ||
            code == 141 ||
            (ended.indexOf(i + 1) < ended.indexOf(i) && '$stderrBuf'.contains('Broken pipe')));

    final codes = [for (final (i, code) in settled.indexed) isBrokenPipe(i, code) ? 0 : code];
    final code = codes.lastWhere((c) => c != 0, orElse: () => 0);
    if (scope.strict && code != 0) throw ShellException(result(code));
    return result(code);
  }

  return (inherit && IoBridge.suspend != null) ? IoBridge.suspend!(execute) : execute();
}

final _psWhitespace = RegExp(r'\s+');

/// What Windows runs for [executable]: the program on the `PATH`, or `cmd.exe` (the second
/// field) for a `.bat`, a `.cmd` or a built-in such as `dir`.
///
/// Remembered until `PATH` or `PATHEXT` changes: finding it is some 400 stats per `run`.
Future<(String, bool)> _windowsTarget(String executable) async {
  final bare = !executable.contains('/') && !executable.contains('\\');
  if (bare) {
    final key = '${Env.getOrNull('PATH')}\u0000${Env.getOrNull('PATHEXT')}';
    if (key != _targetsKey) {
      _targets.clear();
      _targetsKey = key;
    }
    if (_targets[executable] case final hit?) return hit;
  }
  final found = bare ? await which(executable) : Path(executable);
  if (found == null) return (executable, true);
  final target = const {'bat', 'cmd'}.contains(found.ext.toLowerCase()) ? (executable, true) : (found.path, false);
  if (bare) _targets[executable] = target;
  return target;
}

final _targets = <String, (String, bool)>{};
String? _targetsKey;

/// Sends [signal] to [roots] and everything they started, and returns every pid it sent to.
///
/// One `ps` table, read synchronously: asynchronously would lose the race with a signal
/// that ends this process.
List<int> _signalTree(List<int> roots, ProcessSignal signal) {
  if (Platform.isWindows) {
    for (final pid in roots) {
      Process.runSync('taskkill', ['/PID', '$pid', '/T', '/F']);
    }
    return const [];
  }
  final children = <int, List<int>>{};
  try {
    final table = Process.runSync('ps', ['-A', '-o', 'pid=', '-o', 'ppid=']).stdout as String;
    for (final line in table.split('\n')) {
      if (line.trim().split(_psWhitespace).map(int.tryParse).toList() case [final pid?, final ppid?]) {
        (children[ppid] ??= []).add(pid);
      }
    }
  } catch (_) {} // no `ps`: the roots alone
  final tree = <int>[];
  final queue = [...roots];
  while (queue.isNotEmpty) {
    final pid = queue.removeLast();
    tree.add(pid);
    queue.addAll(children[pid] ?? const []);
  }
  for (final pid in tree) {
    Process.killPid(pid, signal);
  }
  return tree;
}

/// Waits up to [_grace] for [tree] to be gone, then SIGKILLs whatever is left.
Future<void> _reap(List<int> tree) async {
  // SIGCONT is the probe: it reaches a live process, harmlessly, and fails on a gone one.
  List<int> alive() => [
    for (final pid in tree)
      if (Process.killPid(pid, ProcessSignal.sigcont)) pid,
  ];
  final deadline = DateTime.now().add(_grace);
  var left = alive();
  while (left.isNotEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    left = alive();
  }
  for (final pid in left) {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
  ProcessBridge.unregisterHalted(tree);
}

/// A child's output on its way to the terminal. While a spinner or a board is drawn it
/// goes a line at a time above it, through [IoBridge.above], instead of onto its row.
final class _Echo {
  final bool err;
  final _partial = StringBuffer();

  _Echo({required this.err});

  StringSink get _sink => err ? Io.err : Io.out;

  void add(String chunk) {
    final above = IoBridge.above;
    if (above == null) {
      _sink.write(_partial.isEmpty ? chunk : '$_partial$chunk');
      _partial.clear();
      return;
    }
    _partial.write(chunk);
    final text = _partial.toString();
    final end = text.lastIndexOf('\n') + 1;
    if (end == 0) return;
    _partial
      ..clear()
      ..write(text.substring(end));
    above(() => _sink.write(text.substring(0, end)));
  }

  void close() {
    if (_partial.isEmpty) return;
    final rest = '$_partial';
    _partial.clear();
    if (IoBridge.above case final above?) {
      above(() => _sink.writeln(rest));
    } else {
      _sink.write(rest);
    }
  }
}

/// The executable on the `PATH` [Env] sees, or `null`.
///
/// {@category System}
Future<Path?> which(String executable) async {
  final paths = (Env.getOrNull('PATH') ?? '').split(Platform.isWindows ? ';' : ':').where((p) => p.isNotEmpty);
  final pathExt = Env.getOrNull('PATHEXT')?.split(';').where((e) => e.isNotEmpty);
  final extensions = switch (Platform.isWindows) {
    false => const [''],
    true when executable.contains('.') => ['', ...?pathExt],
    true => [
      ...pathExt ?? const ['.com', '.exe', '.bat', '.cmd'],
    ],
  };

  final candidates = [
    for (final dir in paths)
      for (final ext in extensions) Path(dir) / '$executable$ext',
  ];
  final found = await Future.wait(candidates.map(_isProgram));
  for (var i = 0; i < candidates.length; i++) {
    if (found[i]) return candidates[i];
  }
  return null;
}

/// Whether [candidate] is a file with an execute bit: what a shell would find.
Future<bool> _isProgram(Path candidate) async {
  final stat = await FileStat.stat(candidate.path);
  if (stat.type != FileSystemEntityType.file) return false;
  return Platform.isWindows || stat.mode & 0x49 != 0; // any of u+x, g+x, o+x
}

/// Commands chained through their standard streams: `('ls' | 'grep dart').run()`.
///
/// {@category System}
class CommandPipeline {
  final List<String> _commands;

  CommandPipeline._(List<String> commands) : _commands = List.unmodifiable(commands);

  /// Pipes this pipeline's output into [next].
  CommandPipeline operator |(String next) => CommandPipeline._([..._commands, next]);

  /// Runs every stage, as [run] runs one. Like `pipefail`: [ShellResult.exitCode] is the
  /// rightmost non-zero exit, and [strict] throws when any stage fails.
  ShellRun run({
    Path? workdir,
    Map<String, String>? env,
    Duration? timeout,
    String? input,
    bool? quiet,
    bool? strict,
    Encoding? encoding,
  }) => ShellRun._((scope, control) {
    final stages = [
      for (final cmd in _commands)
        switch (_splitCommand(cmd.trim())) {
          [] => throw ArgumentError('Empty command in pipeline'),
          [final exe, ...final args] => (exe, args),
        },
    ];
    return _exec(stages, _commands.join(' | '), scope, control, input: input, viaShell: Platform.isWindows);
  }, (workdir: workdir, env: env, timeout: timeout, encoding: encoding, quiet: quiet, strict: strict));
}

/// Pipeline construction on [String]: `('ls' | 'grep dart').run()`; one command is [run].
///
/// {@category System}
extension StringShellExtensions on String {
  /// Starts a command pipeline with this command piped into [next].
  CommandPipeline operator |(String next) => CommandPipeline._([this, next]);
}

/// Running a script or a binary by its path.
///
/// {@category System}
extension PathShellExtensions on Path {
  /// Runs this file with [args] as they are, never re-read; otherwise as [run]. On Windows
  /// only a `.bat` or `.cmd` goes through `cmd.exe`.
  ShellRun run({
    List<String> args = const [],
    Path? workdir,
    Map<String, String>? env,
    Duration? timeout,
    String? input,
    bool? quiet,
    bool? strict,
    Encoding? encoding,
    bool inherit = false,
  }) => ShellRun._(
    (scope, control) => _exec(
      [(absolute.path, args)],
      _display(path, args),
      scope,
      control,
      input: input,
      inherit: inherit,
      viaShell: Platform.isWindows && const {'bat', 'cmd'}.contains(ext.toLowerCase()),
    ),
    (workdir: workdir, env: env, timeout: timeout, encoding: encoding, quiet: quiet, strict: strict),
  );
}
