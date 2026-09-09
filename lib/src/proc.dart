/// # Process Runner & Shutdown Signals (internal)
///
/// Implementation behind the public `system.*` namespace: subprocess
/// execution ([Sys.run]), executable lookup ([Sys.which]) and crash-safe
/// cleanup of partial files and child processes ([Exit]).
///
/// Not exported apart from [SysResult]: reach these operations through
/// `system.*`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

// ============================================================================
// SYSTEM, PROCESS RUNNER & SHUTDOWN SIGNALS
// ============================================================================

/// The outcome of a subprocess launched by [Sys.run].
class SysResult {
  /// Process exit code. `-1` indicates the process was killed by a timeout.
  final int code;

  /// Captured standard output. Empty when the process inherited the terminal.
  final String out;

  /// Captured standard error. Empty when the process inherited the terminal.
  final String err;

  /// Creates a result. Normally produced by [Sys.run].
  const SysResult({required this.code, required this.out, required this.err});

  /// Whether the process exited successfully (code `0`).
  bool get ok => code == 0;

  @override
  String toString() => 'SysResult(code: $code)';
}

/// Subprocess execution and OS helpers.
class Sys {
  const Sys._();

  /// Runs [executable] with [arguments] and waits for it to exit.
  ///
  /// By default stdout/stderr are captured into the returned [SysResult]. Set
  /// [inherit] to stream them straight to the terminal instead (useful for
  /// tools that render their own progress), in which case the captured strings
  /// are empty. [out] and [err] receive each captured line as it arrives.
  ///
  /// When [timeout] elapses the process is killed and the result carries code
  /// `-1`. [echo] prints the command line before running it.
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
      Exit.adopt(process);
      try {
        final code = await _await(process, timeout);
        return SysResult(
          code: code,
          out: '',
          err: code == -1 ? _timedOut(timeout) : '',
        );
      } finally {
        Exit.disown(process);
      }
    }

    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: cwd,
    );
    Exit.adopt(process);

    final outBuf = StringBuffer();
    final errBuf = StringBuffer();

    // Start draining before awaiting the exit code. `Stream.forEach` returns a
    // future that completes when the pipe closes, and unlike
    // `StreamSubscription.asFuture` it is safe to await after the stream has
    // already finished — which is the common case for a fast process.
    Future<void> drain(
      Stream<List<int>> pipe,
      StringBuffer buffer,
      void Function(String line)? sink,
    ) => pipe.transform(utf8.decoder).transform(const LineSplitter()).forEach((
      line,
    ) {
      buffer.writeln(line);
      sink?.call(line);
    });

    final draining = [
      drain(process.stdout, outBuf, out),
      drain(process.stderr, errBuf, err),
    ];

    try {
      final code = await _await(process, timeout);
      // Killing the process closes its pipes, so this settles either way; the
      // cap only guards against a grandchild inheriting and holding them open.
      await Future.wait(
        draining,
      ).timeout(const Duration(seconds: 5), onTimeout: () => const []);
      return SysResult(
        code: code,
        out: outBuf.toString(),
        err: code == -1 ? _timedOut(timeout) : errBuf.toString(),
      );
    } finally {
      Exit.disown(process);
    }
  }

  static Future<int> _await(Process process, Duration? timeout) {
    if (timeout == null) return process.exitCode;
    return process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
  }

  static String _timedOut(Duration? timeout) =>
      'Process timed out after ${timeout?.inSeconds}s';

  /// Resolves [name] to an absolute executable path, or `null` if not found.
  ///
  /// Searches [paths] first (useful for well-known install locations), then an
  /// absolute [name] as given, then every entry of `PATH`. On Windows the
  /// `.exe`, `.cmd` and `.bat` extensions are tried for each candidate.
  static String? which(String name, {List<String>? paths}) {
    final isWin = Platform.isWindows;
    final exts = isWin ? const ['.exe', '.cmd', '.bat', ''] : const [''];

    for (final candidate in paths ?? const <String>[]) {
      if (File(candidate).existsSync()) return candidate;
      for (final ext in exts) {
        if (File('$candidate$ext').existsSync()) return '$candidate$ext';
      }
    }

    if (p.isAbsolute(name)) {
      if (File(name).existsSync()) return name;
      for (final ext in exts) {
        if (File('$name$ext').existsSync()) return '$name$ext';
      }
    }

    final dirs = (Platform.environment['PATH'] ?? '')
        .split(isWin ? ';' : ':')
        .where((d) => d.isNotEmpty);
    for (final dir in dirs) {
      for (final ext in exts) {
        final candidate = p.join(dir, '$name$ext');
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }

  /// Starts watching for `SIGINT` so tracked resources are cleaned up on Ctrl-C.
  static void watch() => Exit.watch();

  /// Stops watching for `SIGINT` and releases the signal subscription.
  static void unwatch() => Exit.unwatch();

  /// Registers [file] for deletion if the program is interrupted.
  static void track(File file) => Exit.track(file);

  /// Stops tracking [file], typically once it has been renamed into place.
  static void untrack(File file) => Exit.untrack(file);

  /// Takes responsibility for [process]: it is killed if the program is
  /// interrupted before [disown] is called.
  static void adopt(Process process) => Exit.adopt(process);

  /// Gives up responsibility for [process], once it has exited.
  static void disown(Process process) => Exit.disown(process);

  /// Registers [fn] to run during graceful shutdown.
  static void hook(FutureOr<void> Function() fn) => Exit.hook(fn);

  /// Kills tracked children, deletes tracked partials, runs the exit hooks,
  /// then exits with [code] when it is non-zero.
  static Future<void> shutdown([int code = 0]) => Exit.shutdown(code);
}

/// Crash-safe cleanup registry for partial files, child processes and hooks.
///
/// Tracking a resource installs a `SIGINT` watcher so that Ctrl-C removes
/// half-written `.part` files and kills child processes. The watcher is
/// released automatically once nothing is tracked any more, so a script that
/// finishes its work exits without needing [unwatch].
class Exit {
  const Exit._();

  static final Set<File> _files = <File>{};
  static final Set<Process> _procs = <Process>{};
  static final List<FutureOr<void> Function()> _hooks = [];
  static StreamSubscription<ProcessSignal>? _signal;
  static bool _stopping = false;

  /// Starts watching for `SIGINT`. Safe to call repeatedly.
  static void watch() {
    if (_signal != null) return;
    try {
      _signal = ProcessSignal.sigint.watch().listen((_) async {
        await shutdown(130);
      });
    } catch (_) {
      // Signal handling is unavailable on some platforms; cleanup still runs
      // through the explicit `now()` path.
    }
  }

  /// Stops watching for `SIGINT` and releases the subscription.
  ///
  /// A live signal subscription keeps the Dart isolate alive, so this must run
  /// before a script can exit. [untrack], [unproc] and [now] call it for you
  /// once the last tracked resource is released.
  static void unwatch() {
    _signal?.cancel();
    _signal = null;
  }

  /// Releases the signal watcher when no resources remain tracked.
  static void _idle() {
    if (_files.isEmpty && _procs.isEmpty && _hooks.isEmpty) unwatch();
  }

  /// Registers [file] for deletion if the program is interrupted.
  static void track(File file) {
    watch();
    _files.add(file);
  }

  /// Stops tracking [file] and releases the watcher if nothing else is tracked.
  static void untrack(File file) {
    _files.remove(file);
    _idle();
  }

  /// Takes responsibility for [process]: it is killed if the program is
  /// interrupted before [disown] is called.
  static void adopt(Process process) {
    watch();
    _procs.add(process);
  }

  /// Stops tracking [process] and releases the watcher if nothing else is.
  static void disown(Process process) {
    _procs.remove(process);
    _idle();
  }

  /// Registers [fn] to run during graceful shutdown.
  ///
  /// Note that a registered hook keeps the `SIGINT` watcher alive, and so keeps
  /// the process alive, until [now] runs the hooks.
  static void hook(FutureOr<void> Function() fn) {
    watch();
    _hooks.add(fn);
  }

  /// Kills tracked processes, deletes tracked files and runs hooks.
  ///
  /// Exits the process with [code] when it is non-zero. Re-entrant calls are
  /// ignored so a second Ctrl-C cannot interleave with cleanup.
  static Future<void> shutdown([int code = 0]) async {
    if (_stopping) return;
    _stopping = true;

    for (final proc in _procs) {
      try {
        proc.kill();
      } catch (_) {}
    }
    _procs.clear();

    for (final file in _files) {
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
    _files.clear();

    for (final hook in _hooks) {
      try {
        await hook();
      } catch (_) {}
    }
    _hooks.clear();

    unwatch();
    _stopping = false;
    if (code != 0) exit(code);
  }
}
