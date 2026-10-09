part of 'process.dart';

/// How long a stopped command's tree has between SIGTERM and SIGKILL: inside the second a
/// cancelled task waits for its work.
const _killGrace = Duration(milliseconds: 500);

/// Every variable a child sees: [Env]'s, with [extra] on top (a `null` value unsets one).
Map<String, String> _variables(Map<String, String?>? extra) {
  final all = Env.all;
  if (extra != null) {
    for (final MapEntry(:key, :value) in extra.entries) {
      value == null ? all.remove(key) : all[key] = value;
    }
  }
  return all;
}

/// The environment a child gets, or `null` for this process's own when nothing changed it.
Map<String, String>? _childEnv(Map<String, String?>? extra) =>
    extra == null && !ProcessBridge.isEnvOverridden ? null : _variables(extra);

/// [stage] started in [workdir] with [env] (this process's when `null`), [mode] as given. On
/// Windows a `.bat`, a `.cmd`, a `cmd` built-in and a [Shell.sh] script go through `cmd.exe`, and
/// every child joins the kill-on-close job.
Future<Process> _start(Command stage, String? workdir, Map<String, String>? env, ProcessStartMode mode) async {
  final Process child;
  if (!Platform.isWindows) {
    child = await Process.start(
      stage.program,
      stage.args,
      workingDirectory: workdir,
      environment: env,
      includeParentEnvironment: env == null,
      mode: mode,
    );
  } else {
    final variables = env ?? Env.all;
    final line = await _cmdLine(stage, variables);
    child = line == null
        ? await Process.start(
            await _windowsProgram(stage.program, variables),
            stage.args,
            workingDirectory: workdir,
            environment: env,
            includeParentEnvironment: env == null,
            mode: mode,
          )
        // The one way into cmd.exe: the line rides in a variable cmd expands before it parses,
        // so no quoting of Dart's or ours stands between the line and cmd, and no file is written.
        : await Process.start(
            'cmd.exe',
            const ['/d', '/v:off', '/c', '%$_cmdVariable%'],
            workingDirectory: workdir,
            environment: {...variables, _cmdVariable: line},
            includeParentEnvironment: false,
            mode: mode,
          );
  }
  ProcessBridge.assignJob(child.pid);
  return child;
}

const _cmdVariable = 'DART_TOOLKIT_COMMAND';

/// The line `cmd.exe` runs for [stage], or `null` when it runs as a program of its own.
Future<String?> _cmdLine(Command stage, Map<String, String> variables) async {
  if (stage._cmd) return _expand(stage.args.single, variables);
  final program = stage.program;
  final String target;
  if (_isBare(program)) {
    final found = await _lookup(program, variables);
    if (found == null) return _cmdBuiltins.contains(program.toLowerCase()) ? _cmdWords([program, ...stage.args]) : null;
    target = found;
  } else {
    target = program;
  }
  return const {'bat', 'cmd'}.contains(FileBridge.extension(target)) ? _cmdWords([target, ...stage.args]) : null;
}

/// [words] as one `cmd.exe` line: each quoted where cmd would split or read it. A `"` or a line
/// break, which no quoting keeps from cmd, is an [ArgumentError].
String _cmdWords(List<String> words) => [
  for (final word in words)
    if (word.contains('"') || word.contains('\n') || word.contains('\r'))
      throw ArgumentError.value(word, 'args', 'Invalid argument: cmd.exe cannot be passed a quote or a line break')
    else if (word.isEmpty || word.contains(RegExp(r'[\s&|<>^(),;=!%]')))
      '"$word"'
    else
      word,
].join(' ');

/// [script] with each `%NAME%` that [variables] defines replaced by its value, as cmd expands
/// a typed line; the rest is left as written.
String _expand(String script, Map<String, String> variables) {
  final upper = {for (final MapEntry(:key, :value) in variables.entries) key.toUpperCase(): value};
  return script.replaceAllMapped(RegExp(r'%(\w+)%'), (m) => upper[m[1]!.toUpperCase()] ?? m[0]!);
}

/// The file Windows runs for a bare [program]: the one on the `PATH`, else [program] as it is,
/// which fails to start as a missing program does.
Future<String> _windowsProgram(String program, Map<String, String> variables) async =>
    _isBare(program) ? await _lookup(program, variables) ?? program : program;

bool _isBare(String program) => !program.contains('/') && !program.contains(r'\');

const _cmdBuiltins = {
  'assoc', 'break', 'call', 'cd', 'chdir', 'cls', 'color', 'copy', 'date', 'del', 'dir', 'echo', //
  'endlocal', 'erase', 'for', 'ftype', 'goto', 'if', 'md', 'mkdir', 'mklink', 'move', 'path', 'pause',
  'popd', 'prompt', 'pushd', 'rd', 'rem', 'ren', 'rename', 'rmdir', 'set', 'setlocal', 'shift', 'start',
  'time', 'title', 'type', 'ver', 'verify', 'vol',
};

/// Where [program] is, as the `PATH` (and `PATHEXT`) of [variables] say; `null` when nowhere.
/// A [program] with a folder in it is checked where it is.
///
/// Remembered per `PATH` and `PATHEXT`: a search is a stat per folder and extension.
Future<Path?> _lookup(String program, Map<String, String> variables) async {
  String? read(String key) => switch (variables[key]) {
    final v? when v.isNotEmpty => v,
    _ => null,
  };
  if (!_isBare(program)) {
    for (final candidate in [
      program,
      if (Platform.isWindows) ..._extensions(program, read('PATHEXT')).map((e) => '$program$e'),
    ]) {
      if (_runnable(await FileStat.stat(candidate))) return Path(File(candidate).absolute.path);
    }
    return null;
  }
  final path = read('PATH') ?? '';
  final pathExt = Platform.isWindows ? read('PATHEXT') : null;
  final key = '$path\u0000$pathExt\u0000$program';
  if (_found[key] case final found?) return found;
  final candidates = [
    for (final dir in path.split(Platform.isWindows ? ';' : ':'))
      if (_unquoted(dir.trim()) case final folder when folder.isNotEmpty)
        for (final ext in Platform.isWindows ? _extensions(program, pathExt) : const [''])
          '$folder${Platform.pathSeparator}$program$ext',
  ];
  final stats = await Future.wait(candidates.map(FileStat.stat));
  for (var i = 0; i < candidates.length; i++) {
    if (_runnable(stats[i])) {
      if (_found.length > 256) _found.clear();
      return _found[key] = Path(candidates[i]);
    }
  }
  return null;
}

final _found = <String, Path>{};

String _unquoted(String dir) => Platform.isWindows && dir.length >= 2 && dir.startsWith('"') && dir.endsWith('"')
    ? dir.substring(1, dir.length - 1)
    : dir;

/// The endings Windows tries for [program]: `PATHEXT`'s (`.COM;.EXE;.BAT;.CMD` when unset), and
/// none first when [program] already has an extension, whatever it is.
List<String> _extensions(String program, String? pathExt) => [
  if (FileBridge.extension(program).isNotEmpty) '',
  ...(pathExt ?? '.com;.exe;.bat;.cmd').split(';').where((e) => e.isNotEmpty).map((e) => e.toLowerCase()),
];

/// Whether [stat] is a file a shell would run: on POSIX, one with an execute bit.
bool _runnable(FileStat stat) =>
    stat.type == FileSystemEntityType.file && (Platform.isWindows || stat.mode & 0x49 != 0); // u+x, g+x or o+x

/// The exit code a shell gives for a program that could not start, as [e] says why: 126 for
/// one that cannot run, 127 for one that is not there; `null` for any other failure, which is
/// thrown as it is.
int? _codeOf(ProcessException e) => switch (e.errorCode) {
  2 || 3 when Platform.isWindows => 127, // ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND
  5 || 193 when Platform.isWindows => 126, // ERROR_ACCESS_DENIED, ERROR_BAD_EXE_FORMAT
  2 || 20 when !Platform.isWindows => 127, // ENOENT, ENOTDIR
  8 || 13 || 21 when !Platform.isWindows => 126, // ENOEXEC, EACCES, EISDIR
  _ => null,
};

/// Stops [processes] and everything they started: SIGTERM now, SIGKILL [_killGrace] later for
/// what is left (on Windows, `taskkill /T /F` at once). Completes once they are gone.
Future<void> _stopTree(List<Process> processes) async {
  final roots = [for (final p in processes) p.pid];
  if (roots.isEmpty) return;
  if (Platform.isWindows) {
    try {
      await Process.run('taskkill', [
        for (final pid in roots) ...['/PID', '$pid'],
        '/T',
        '/F',
      ]);
    } on ProcessException catch (_) {} // no taskkill: the job object ends them with this process
    return;
  }
  // The roots first, synchronously: a `Cli` that is leaving reaps what is registered.
  for (final pid in roots) {
    Process.killPid(pid, ProcessSignal.sigterm);
  }
  ProcessBridge.registerHalted(roots);
  final tree = {...roots, ...await _descendants(roots)};
  for (final pid in tree.difference(roots.toSet())) {
    Process.killPid(pid, ProcessSignal.sigterm);
  }
  ProcessBridge.registerHalted(tree);
  // SIGCONT is the probe: it reaches a live process harmlessly and fails on a gone one.
  List<int> alive() => [
    for (final pid in tree)
      if (Process.killPid(pid, ProcessSignal.sigcont)) pid,
  ];
  // Real time, counted in polls: a fake clock in a test must not hold a real child's end.
  var left = alive();
  for (var polls = _killGrace.inMilliseconds ~/ 20; left.isNotEmpty && polls > 0; polls--) {
    await Zone.root.run(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    left = alive();
  }
  for (final pid in left) {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
  ProcessBridge.unregisterHalted(tree);
}

/// Every process [roots] started, and theirs, from one `ps` table.
Future<List<int>> _descendants(List<int> roots) async {
  final children = <int, List<int>>{};
  try {
    final table = await Process.run('ps', ['-A', '-o', 'pid=', '-o', 'ppid=']);
    for (final line in '${table.stdout}'.split('\n')) {
      if (line.trim().split(RegExp(r'\s+')).map(int.tryParse).toList() case [final pid?, final ppid?]) {
        (children[ppid] ??= []).add(pid);
      }
    }
  } on ProcessException catch (_) {} // no `ps`: the roots alone
  final out = <int>[];
  final queue = [...roots];
  while (queue.isNotEmpty) {
    for (final child in children[queue.removeLast()] ?? const <int>[]) {
      out.add(child);
      queue.add(child);
    }
  }
  return out;
}
