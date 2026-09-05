import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

// ============================================================================
// SYSTEM, PROCESS RUNNER & SHUTDOWN SIGNALS
// ============================================================================

/// Result of an executed external process.
class ProcResult {
  /// The process exit code (0 indicates success).
  final int code;

  /// Standard output captured from the process.
  final String stdout;

  /// Standard error output captured from the process.
  final String stderr;

  /// Creates a [ProcResult].
  ProcResult({
    required this.code,
    required this.stdout,
    required this.stderr,
  });

  /// Whether the process exited successfully with code 0.
  bool get ok => code == 0;

  @override
  String toString() => 'ProcResult(code: $code)';
}

/// Shutdown and exit lifecycle events namespace (`sys.on.exit(...)`).
class SysEvents {
  /// Registers an asynchronous or synchronous cleanup callback executed upon exit or Ctrl+C.
  void exit(dynamic Function() callback) {
    Exit.hook(callback);
  }
}

/// System, process, environment, and graceful shutdown namespace accessor.
class SysAccessor {
  /// Sub-namespace for exit and shutdown lifecycle events.
  final SysEvents on = SysEvents();

  /// Creates a [SysAccessor] instance.
  SysAccessor();

  /// Executes an external process and returns its captured [ProcResult].
  ///
  /// If [inherit] is true, streams standard input, output, and error directly to the console.
  /// If [echo] is true, prints the command invocation before running.
  /// Standard output and error can also be streamed line-by-line via [out] and [err] callbacks.
  ///
  /// Automatically registers the running process with signal cleanup so Ctrl+C will terminate it.
  ///
  /// ```dart
  /// final res = await sys.run('git', ['status', '--short']);
  /// if (res.ok) {
  ///   print(res.stdout);
  /// }
  /// ```
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    String? cwd,
    bool inherit = false,
    bool echo = false,
    void Function(String line)? out,
    void Function(String line)? err,
  }) =>
      Proc.run(
        executable,
        arguments,
        cwd: cwd,
        inherit: inherit,
        echo: echo,
        out: out,
        err: err,
      );

  /// Locates an executable binary in the system `PATH` or specified candidate [paths].
  ///
  /// On Windows, automatically checks `.exe`, `.cmd`, and `.bat` extensions.
  ///
  /// ```dart
  /// final ffmpeg = sys.which('ffmpeg');
  /// ```
  String? which(String name, {List<String>? paths}) =>
      Proc.which(name, paths: paths);

  /// Starts listening for Ctrl+C (`SIGINT`) signals to invoke registered shutdown hooks.
  void listen() => Exit.listen();

  /// Tracks a temporary or partial file for automatic deletion if the process is aborted.
  void track(File file) => Exit.track(file);

  /// Untracks a file after it has completed successfully, preventing cleanup.
  void untrack(File file) => Exit.untrack(file);

  /// Registers a shutdown cleanup callback.
  void hook(dynamic Function() fn) => Exit.hook(fn);

  /// Triggers an immediate graceful shutdown, executing hooks and cleaning up tracked files.
  Future<void> now([int code = 0]) => Exit.now(code);

  /// Cleanly exits the application with an optional status [code].
  Future<void> exit([int code = 0]) => Exit.now(code);

  /// Reads an environment variable by [key].
  String? env(String key) => Platform.environment[key];

  /// Creates and starts a new [Stopwatch] benchmark timer.
  Stopwatch clock() => Stopwatch()..start();
}

/// Top-level system and process accessor singleton.
final SysAccessor sys = SysAccessor();

/// Alias for system accessor (`proc.*`).
final SysAccessor proc = sys;

/// Process execution utilities class (also available via lowercase `sys.*` and `proc.*`).
class Proc {
  /// Executes external [executable] with [arguments] and returns captured [ProcResult].
  static Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    String? cwd,
    bool inherit = false,
    bool echo = false,
    void Function(String line)? out,
    void Function(String line)? err,
  }) async {
    if (echo) {
      stdout.writeln('> $executable ${arguments.join(' ')}');
    }

    if (inherit) {
      final process = await Process.start(
        executable,
        arguments,
        workingDirectory: cwd,
        mode: ProcessStartMode.inheritStdio,
      );

      Exit.proc(process);
      try {
        final code = await process.exitCode;
        return ProcResult(code: code, stdout: '', stderr: '');
      } finally {
        Exit.proc(process);
      }
    }

    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: cwd,
    );

    Exit.proc(process);

    final outBuf = StringBuffer();
    final errBuf = StringBuffer();

    final outFuture = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          outBuf.writeln(line);
          if (out != null) out(line);
        })
        .asFuture<void>();

    final errFuture = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          errBuf.writeln(line);
          if (err != null) err(line);
        })
        .asFuture<void>();

    try {
      final code = await process.exitCode;
      await Future.wait([outFuture, errFuture]);
      return ProcResult(
        code: code,
        stdout: outBuf.toString(),
        stderr: errBuf.toString(),
      );
    } finally {
      Exit.proc(process);
    }
  }

  /// Finds executable binary in PATH or candidate paths.
  static String? which(
    String name, {
    List<String>? paths,
  }) {
    final isWin = Platform.isWindows;
    final exts = isWin ? ['.exe', '.cmd', '.bat', ''] : [''];

    if (paths != null) {
      for (final c in paths) {
        if (File(c).existsSync()) return c;
        for (final ext in exts) {
          final withExt = '$c$ext';
          if (File(withExt).existsSync()) return withExt;
        }
      }
    }

    if (p.isAbsolute(name)) {
      if (File(name).existsSync()) return name;
      for (final ext in exts) {
        final withExt = '$name$ext';
        if (File(withExt).existsSync()) return withExt;
      }
    }

    final env = Platform.environment['PATH'] ?? '';
    final sep = isWin ? ';' : ':';
    final dirs = env.split(sep).where((d) => d.isNotEmpty);

    for (final dir in dirs) {
      for (final ext in exts) {
        final cand = p.join(dir, '$name$ext');
        if (File(cand).existsSync()) return cand;
      }
    }

    return null;
  }

  /// Starts listening for Ctrl+C signals.
  static void listen() => Exit.listen();

  /// Tracks a temporary file for automatic deletion on abort.
  static void track(File file) => Exit.track(file);

  /// Untracks a file after completion.
  static void untrack(File file) => Exit.untrack(file);

  /// Registers a shutdown cleanup callback.
  static void hook(dynamic Function() fn) => Exit.hook(fn);

  /// Initiates immediate graceful shutdown.
  static Future<void> now([int code = 0]) => Exit.now(code);
}

/// Global exit lifecycle manager for SIGINT trapping, process cleanup, and file deletion.
class Exit {
  static final Set<File> _files = <File>{};
  static final Set<Process> _procs = <Process>{};
  static final List<FutureOr<void> Function()> _hooks = [];
  static bool _init = false;
  static bool _stopping = false;

  /// Initializes signal handlers for Ctrl+C (SIGINT).
  static void listen() {
    if (_init) return;
    _init = true;
    try {
      ProcessSignal.sigint.watch().listen((_) async {
        await now(130);
      });
    } catch (_) {}
  }

  /// Registers [file] to be deleted if the application is interrupted.
  static void track(File file) {
    listen();
    _files.add(file);
  }

  /// Untracks [file] when successfully completed.
  static void untrack(File file) {
    _files.remove(file);
  }

  /// Registers child [process] to be killed if the parent exits.
  static void proc(Process process) {
    listen();
    _procs.add(process);
  }

  /// Registers an exit hook callback.
  static void hook(FutureOr<void> Function() fn) {
    listen();
    _hooks.add(fn);
  }

  /// Kills spawned processes, deletes tracked files, runs hooks, and terminates with [code].
  static Future<void> now([int code = 0]) async {
    if (_stopping) return;
    _stopping = true;

    for (final p in _procs) {
      try {
        p.kill();
      } catch (_) {}
    }
    _procs.clear();

    for (final f in _files) {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    _files.clear();

    for (final fn in _hooks) {
      try {
        await fn();
      } catch (_) {}
    }
    _hooks.clear();

    if (code != 0) exit(code);
  }
}
