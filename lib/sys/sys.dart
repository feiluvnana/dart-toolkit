import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

// ============================================================================
// SYSTEM, PROCESS RUNNER & SHUTDOWN SIGNALS
// ============================================================================

/// Result of a process execution.
class ProcResult {
  final int code;
  final String stdout;
  final String stderr;

  ProcResult({
    required this.code,
    required this.stdout,
    required this.stderr,
  });

  bool get ok => code == 0;

  @override
  String toString() => 'ProcResult(code: $code)';
}

/// Shutdown and exit lifecycle events namespace (`sys.on.exit(...)`).
class SysEvents {
  void exit(dynamic Function() callback) {
    Exit.hook(callback);
  }
}

/// System namespace accessor (`sys.run(...)`, `sys.which(...)`, `sys.listen()`).
class SysAccessor {
  final SysEvents on = SysEvents();

  SysAccessor();

  /// Execute an external process (1-word).
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

  /// Locate executable in PATH or candidate paths (1-word).
  String? which(String name, {List<String>? paths}) =>
      Proc.which(name, paths: paths);

  /// Listen to Ctrl+C (SIGINT) and run cleanup hooks (1-word).
  void listen() => Exit.listen();

  /// Track a temporary or partial file for automatic cleanup upon abort (1-word).
  void track(File file) => Exit.track(file);

  /// Untrack file after successful completion (1-word).
  void untrack(File file) => Exit.untrack(file);

  /// Register shutdown cleanup hook (1-word).
  void hook(dynamic Function() fn) => Exit.hook(fn);

  /// Trigger immediate graceful shutdown (1-word).
  Future<void> now([int code = 0]) => Exit.now(code);

  /// Cleanly exit application with optional status code (1-word).
  Future<void> exit([int code = 0]) => Exit.now(code);

  /// Query environment variable (1-word).
  String? env(String key) => Platform.environment[key];

  /// Create and start a new benchmark stopwatch (1-word).
  Stopwatch clock() => Stopwatch()..start();
}

/// Top-level system accessor instance.
final SysAccessor sys = SysAccessor();

/// Alias for system accessor (`proc.*`).
final SysAccessor proc = sys;

/// Process execution utilities class (also available via lowercase `sys.*` and `proc.*`).
class Proc {
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

  static void listen() => Exit.listen();
  static void track(File file) => Exit.track(file);
  static void untrack(File file) => Exit.untrack(file);
  static void hook(dynamic Function() fn) => Exit.hook(fn);
  static Future<void> now([int code = 0]) => Exit.now(code);
}

class Exit {
  static final Set<File> _files = <File>{};
  static final Set<Process> _procs = <Process>{};
  static final List<FutureOr<void> Function()> _hooks = [];
  static bool _init = false;
  static bool _stopping = false;

  static void listen() {
    if (_init) return;
    _init = true;
    try {
      ProcessSignal.sigint.watch().listen((_) async {
        await now(130);
      });
    } catch (_) {}
  }

  static void track(File file) {
    listen();
    _files.add(file);
  }

  static void untrack(File file) {
    _files.remove(file);
  }

  static void proc(Process process) {
    listen();
    _procs.add(process);
  }

  static void hook(FutureOr<void> Function() fn) {
    listen();
    _hooks.add(fn);
  }

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
