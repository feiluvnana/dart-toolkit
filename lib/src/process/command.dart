part of 'process.dart';

/// A program to run: [program] with [args], each passed as it is and never re-read, in
/// [workdir] with [env] on top of the environment. A value: build it once, run it as often as
/// you like.
///
/// ```dart
/// final build = Command('cargo', ['build', '--release'], workdir: 'native');
/// await build.run(timeout: 10.m);
/// await (Command('ls', ['-1']) | Command('wc', ['-l'])).run().text;    // a pipeline
/// await Command.file(Path.here.parent / 'tool.sh', ['--fast']).run();  // a script, spaces and all
/// ```
///
/// A bare [program] (`git`) is looked up on the `PATH`; one with a folder in it is that file.
/// [workdir] relative to the enclosing [Shell.scope]'s resolves against it; [env] adds to the
/// scope's, a `null` value unsetting the variable.
///
/// {@category System}
final class Command {
  /// The program: a name on the `PATH`, or a file. In a pipeline, its last stage's.
  final String program;

  /// The arguments, passed as they are. In a pipeline, its last stage's.
  final List<String> args;

  /// The working directory, or `null` for the scope's (else this process's).
  final String? workdir;

  /// Variables on top of the scope's; a `null` value unsets one.
  final Map<String, String?>? env;

  /// The stage whose stdout feeds this one's stdin, in a pipeline.
  final Command? _from;

  /// Whether this is a script for `cmd.exe` ([Shell.sh] on Windows): [args] holds the script.
  final bool _cmd;

  /// Whether its script's `%NAME%`s are its environment's, as in a typed line; `false` for a
  /// line built of quoted words ([Shell.open]), which runs as it is.
  final bool _expands;

  Command(this.program, List<String> args, {this.workdir, Map<String, String?>? env})
    : args = List.unmodifiable(args),
      env = env == null ? null : Map.unmodifiable(env),
      _from = null,
      _cmd = false,
      _expands = false {
    if (program.isEmpty) throw ArgumentError.value(program, 'program', 'Invalid program: empty');
  }

  /// The script or binary at [path], resolved against the working directory now: never looked
  /// up on the `PATH`, and the same file whatever [workdir] it runs in. On Windows a `.bat` or a
  /// `.cmd` runs through `cmd.exe`.
  factory Command.file(String path, List<String> args, {String? workdir, Map<String, String?>? env}) {
    if (path.isEmpty) throw ArgumentError.value(path, 'path', 'Invalid path: empty');
    return Command(File(path).absolute.path, args, workdir: workdir, env: env);
  }

  /// [script] for `cmd.exe`, as [Shell.sh] runs one on Windows; with [expand] `false`, run as
  /// it is.
  Command._cmdScript(String script, {this.workdir, Map<String, String?>? env, bool expand = true})
    : program = 'cmd.exe',
      args = List.unmodifiable([script]),
      env = env == null ? null : Map.unmodifiable(env),
      _from = null,
      _cmd = true,
      _expands = expand;

  /// [stage] with [from] feeding it: a stage of a pipeline, or (with no [from]) one alone again.
  Command._fed(Command? from, Command stage)
    : program = stage.program,
      args = stage.args,
      workdir = stage.workdir,
      env = stage.env,
      _from = from,
      _cmd = stage._cmd,
      _expands = stage._expands;

  /// A pipeline: this command's stdout fed to [next]'s stdin, each stage's stderr kept. Its exit
  /// code is the rightmost non-zero one, as `set -o pipefail` gives; a stage that only stopped
  /// because the next one stopped reading is no failure.
  Command operator |(Command next) {
    var out = this;
    for (final stage in next.stages) {
      out = Command._fed(out, stage);
    }
    return out;
  }

  /// The commands of a pipeline, first to last; `[this]` for one alone.
  List<Command> get stages {
    final out = <Command>[];
    for (Command? at = this; at != null; at = at._from) {
      out.add(at._from == null ? at : Command._fed(null, at));
    }
    return out.reversed.toList();
  }

  /// Runs it, as a [Run]: awaiting it gives the [ShellResult] or throws a [ShellException] for a
  /// non-zero exit; its readings (`text`, `isOk`, `output`, `save`) say what you want of it.
  ///
  /// Stdin is one of [text], [bytes] or a [stream] fed as it arrives (an error in it stops the
  /// command and is what this throws); with none it is closed at once. [timeout] stops it and
  /// throws a [ShellTimeoutException]; [quiet] `false` echoes its output. Both default to the
  /// enclosing [Shell.scope]'s.
  Run run({Duration? timeout, bool? quiet, String? text, List<int>? bytes, Stream<List<int>>? stream}) =>
      _Run(this, _Scope.current, timeout: timeout, quiet: quiet, input: _input(text, bytes, stream));

  /// Runs it on this terminal: the child reads the keyboard and writes the screen, and ^C is its
  /// own (`git commit`, `ssh`, `vim`, a REPL). Nothing is captured. Awaiting it throws a
  /// [ShellException] for a non-zero exit; [timeout] stops it as in [run].
  Task<void> interact({Duration? timeout}) {
    if (_from != null) throw ArgumentError.value(this, 'command', 'Invalid command: a pipeline cannot interact');
    return _interact(this, _Scope.current, timeout);
  }

  @override
  bool operator ==(Object other) =>
      other is Command &&
      other.program == program &&
      _sameList(other.args, args) &&
      other.workdir == workdir &&
      _sameMap(other.env, env) &&
      other._cmd == _cmd &&
      other._expands == _expands &&
      other._from == _from;

  @override
  int get hashCode => Object.hash(program, Object.hashAll(args), workdir, _from);

  /// How it reads in an error or an echo, quoted as `sh` would read it back (`cmd` on Windows).
  @override
  String toString() => [
    for (final stage in stages) stage._cmd ? 'cmd.exe /c ${stage.args.single}' : _display(stage.program, stage.args),
  ].join(' | ');
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameMap(Map<String, String?>? a, Map<String, String?>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (final MapEntry(:key, :value) in a.entries) {
    if (!b.containsKey(key) || b[key] != value) return false;
  }
  return true;
}

/// [program] and [args] as `sh` reads them back: a word that is empty or holds a character `sh`
/// reads is single-quoted, a quote inside closed, escaped and reopened (`it's` → `'it'\''s'`).
/// `cmd.exe` has no such quoting, so on Windows a word with a space is double-quoted.
String _display(String program, List<String> args) {
  final windows = Platform.isWindows;
  String one(String a) {
    if (windows) return a.contains(' ') || a.isEmpty ? '"$a"' : a;
    return a.isEmpty || a.contains(_shReads) ? "'${a.replaceAll("'", r"'\''")}'" : a;
  }

  return [one(program), ...args.map(one)].join(' ');
}

final _shReads = RegExp(r'''[\s'"$`\\|&;<>()*?\[\]#~!{}]''');

/// What the seam stands in for: how a command is run. The default runs it; [Runner.fake]
/// answers instead, for tests (`Shell.scope(runner: …)`).
///
/// {@category System}
final class Runner {
  final FutureOr<ShellResult> Function(Command command)? _answer;

  const Runner._(this._answer);

  /// A runner that runs nothing: each command (each stage of a pipeline, in order) is handed to
  /// [answer], whose [ShellResult] is what the run gets, its stdout and stderr read as a real
  /// child's would be. Stdin is not read.
  ///
  /// ```dart
  /// await Shell.scope(() async {
  ///   expect(await Shell.run('git branch --show-current').text, 'main');
  /// }, runner: Runner.fake((c) => ShellResult(c, stdout: 'main\n')));
  /// ```
  factory Runner.fake(FutureOr<ShellResult> Function(Command command) answer) => Runner._(answer);
}

/// What a command printed and how it exited.
///
/// {@category System}
final class ShellResult {
  /// The command that ran.
  final Command command;

  final int exitCode;

  /// The end of what it printed on stderr: the last 64 KiB, `…` first when there was more.
  final String stderr;

  /// Its stdout as printed; `null` when a reading (`output`, `save`) took it.
  final Uint8List? _bytes;
  String? _stdout;

  /// Whether a reading took stdout, so none was kept.
  final bool _taken;

  ShellResult(this.command, {this.exitCode = 0, String stdout = '', this.stderr = ''})
    : _stdout = stdout,
      _bytes = null,
      _taken = false;

  ShellResult._(this.command, this.exitCode, this._bytes, this.stderr, {bool taken = false})
    : _stdout = taken || _bytes != null ? null : '',
      _taken = taken;

  /// Its stdout, UTF-8 with a stray byte as `U+FFFD`. A [StateError] when `output` or `save`
  /// took it.
  String get stdout {
    if (_taken) throw StateError('Cannot read the stdout of $command: output or save took it');
    return _stdout ??= const Utf8Decoder(allowMalformed: true).convert(_bytes!);
  }

  /// Whether it exited 0.
  bool get isOk => exitCode == 0;

  /// [stdout], trimmed. Decoded from the trimmed bytes, so a large output is not held twice.
  String get text {
    final bytes = _bytes;
    if (_stdout != null || bytes == null) return stdout.trim();
    bool space(int b) => b == 0x20 || (b >= 0x09 && b <= 0x0d);
    var start = 0, end = bytes.length;
    while (start < end && space(bytes[start])) {
      start++;
    }
    while (end > start && space(bytes[end - 1])) {
      end--;
    }
    // Unicode spaces at either end are trimmed after: `trim` gives the same string when none.
    return const Utf8Decoder(allowMalformed: true).convert(bytes, start, end).trim();
  }

  /// Its stdout as printed, for an encoding other than UTF-8.
  Uint8List get bytes {
    if (_taken) throw StateError('Cannot read the stdout of $command: output or save took it');
    return _bytes ?? utf8.encode(stdout);
  }

  /// The non-empty lines of [stdout], right-trimmed, split as [Run.output] splits them.
  List<String> get lines => [
    for (final line in const LineSplitter().convert(stdout))
      if (line.trimRight() case final kept when kept.isNotEmpty) kept,
  ];

  @override
  String toString() => '$command exited $exitCode';
}

/// A command failed: [result] exited non-zero. `<command> exited <code>: <stderr tail>`. Exit
/// 126 is a program that cannot run, 127 one that is not there; a retry never repeats either.
///
/// {@category System}
final class ShellException implements Exception {
  final ShellResult result;

  ShellException(this.result) {
    // `Retry` asks core whether an error would fail the same way again; this is how it knows.
    ProcessBridge.cannotRun = _cannotRun;
  }

  @override
  String toString() => '${result.command} exited ${result.exitCode}${_tail(result.stderr)}';
}

/// A command ran out of its `timeout`, and was stopped with everything it started. [result] is
/// what it printed until then, exit code 124. `<command> timed out after <d>: <stderr tail>`.
///
/// {@category System}
final class ShellTimeoutException extends TimeoutException {
  final ShellResult result;

  ShellTimeoutException(this.result, Duration limit)
    : super('${result.command} timed out after ${limit.humanized}${_tail(result.stderr)}', limit);

  @override
  String toString() => 'TimeoutException: $message';
}

/// `: ` and the last three lines [stderr] said, or nothing: a compiler or a test runner puts the
/// reason just above its last noise.
String _tail(String stderr) {
  final said = [
    for (final line in const LineSplitter().convert(stderr.trim()))
      if (line.trim() case final kept when kept.isNotEmpty) kept,
  ];
  return said.isEmpty ? '' : ': ${said.skip(said.length > 3 ? said.length - 3 : 0).join('\n  ')}';
}

bool _cannotRun(Object e) => e is ShellException && (e.result.exitCode == 126 || e.result.exitCode == 127);

/// The one stdin a run was given: [text], [bytes] or [stream], at most one.
Object? _input(String? text, List<int>? bytes, Stream<List<int>>? stream) {
  final given = [?text, ?bytes, ?stream];
  if (given.length > 1) {
    throw ArgumentError('Invalid input: give one of text:, bytes: and stream:, not ${given.length}');
  }
  return given.firstOrNull;
}
