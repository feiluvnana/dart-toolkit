import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

// ============================================================================
// SYSTEM, PROCESS RUNNER & SHUTDOWN SIGNALS
// ============================================================================

/// Result of an executed external process.
class SysResult {
  /// The process exit code (0 indicates success).
  final int code;

  /// Standard output captured from the process.
  final String stdout;

  /// Standard error output captured from the process.
  final String stderr;

  /// Creates a [SysResult].
  SysResult({required this.code, required this.stdout, required this.stderr});

  /// Whether the process exited successfully with code 0.
  bool get ok => code == 0;

  /// Standard output captured from the process (1-word).
  String get out => stdout;

  /// Standard error output captured from the process (1-word).
  String get err => stderr;

  /// Output string captured from the process (1-word).
  String get output => stdout.isNotEmpty ? stdout : stderr;

  @override
  String toString() => 'SysResult(code: $code)';
}

/// Shutdown and exit lifecycle events namespace (`sys.on.exit(...)`).
class SysEvents {
  /// Registers an asynchronous or synchronous cleanup callback executed upon exit or Ctrl+C.
  void exit(FutureOr<void> Function() callback) {
    Exit.hook(callback);
  }
}


/// System process and environment execution utilities class (available via lowercase `sys.*`).
class Sys {
  /// Executes external [executable] with [arguments] and returns captured [SysResult].
  static Future<SysResult> run(
    String executable,
    List<String> arguments, {
    String? cwd,
    bool inherit = false,
    bool echo = false,
    Duration? timeout,
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
        var waitExit = process.exitCode;
        if (timeout != null) {
          waitExit = waitExit.timeout(
            timeout,
            onTimeout: () {
              process.kill();
              return -1;
            },
          );
        }
        final code = await waitExit;
        return SysResult(
          code: code,
          stdout: '',
          stderr: code == -1
              ? 'Process timed out after ${timeout?.inSeconds}s'
              : '',
        );
      } finally {
        Exit.unproc(process);
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
      var waitExit = process.exitCode;
      if (timeout != null) {
        waitExit = waitExit.timeout(
          timeout,
          onTimeout: () {
            process.kill();
            return -1;
          },
        );
      }
      final code = await waitExit;
      if (code == -1) {
        return SysResult(
          code: -1,
          stdout: outBuf.toString(),
          stderr: 'Process timed out after ${timeout?.inSeconds}s',
        );
      }
      await Future.wait([outFuture, errFuture]);
      return SysResult(
        code: code,
        stdout: outBuf.toString(),
        stderr: errBuf.toString(),
      );
    } finally {
      Exit.unproc(process);
    }
  }

  /// Finds executable binary in PATH or candidate paths.
  static String? which(String name, {List<String>? paths}) {
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

  /// Stops listening for termination signals (1-word).
  static void unlisten() => Exit.unlisten();

  /// Tracks a temporary file for automatic deletion on abort.
  static void track(File file) => Exit.track(file);

  /// Untracks a file after completion.
  static void untrack(File file) => Exit.untrack(file);

  /// Tracks a child [process] to terminate on exit.
  static void proc(Process process) => Exit.proc(process);

  /// Untracks a child [process] after completion.
  static void unproc(Process process) => Exit.unproc(process);

  /// Registers a shutdown cleanup callback.
  static void hook(FutureOr<void> Function() fn) => Exit.hook(fn);

  /// Initiates immediate graceful shutdown.
  static Future<void> now([int code = 0]) => Exit.now(code);
}

/// Global exit lifecycle manager for SIGINT trapping, process cleanup, and file deletion.
class Exit {
  static final Set<File> _files = <File>{};
  static final Set<Process> _procs = <Process>{};
  static final List<FutureOr<void> Function()> _hooks = [];
  static StreamSubscription<ProcessSignal>? _sigintSub;
  static bool _init = false;
  static bool _stopping = false;

  /// Initializes signal handlers for Ctrl+C (SIGINT).
  static void listen() {
    if (_init) return;
    _init = true;
    try {
      _sigintSub = ProcessSignal.sigint.watch().listen((_) async {
        await now(130);
      });
    } catch (_) {}
  }

  /// Cancels signal listeners and restores default termination behavior (1-word).
  static void unlisten() {
    _sigintSub?.cancel();
    _sigintSub = null;
    _init = false;
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

  /// Untracks child [process] when successfully completed.
  static void unproc(Process process) {
    _procs.remove(process);
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
