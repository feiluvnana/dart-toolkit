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

  /// Process exit code. Alias for [code].
  int get exitCode => code;

  /// Whether the process exited successfully (code `0`).
  bool get ok => code == 0;

  /// Whether the process exited successfully (code `0`). Alias for [ok].
  bool get isSuccess => ok;

  /// Captured standard output. Alias for [out].
  String get stdout => out;

  /// Captured standard error. Alias for [err].
  String get stderr => err;

  /// The lines of captured standard output, ignoring empty lines.
  List<String> get lines =>
      out.isEmpty ? const [] : out.split(RegExp(r'\r?\n')).where((l) => l.isNotEmpty).toList();

  /// Parsed JSON object from [stdout].
  dynamic get json => jsonDecode(out);

  @override
  String toString() => 'SysResult(code: $code)';
}

/// Subprocess execution and OS helpers.
class Sys {
  const Sys._();

  /// Streams output lines from [executable] running with [arguments].
  static Stream<String> stream(
    String executable,
    List<String> arguments, {
    String? cwd,
    bool includeStderr = false,
  }) async* {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: cwd,
    );
    Exit.adopt(process);
    try {
      if (!includeStderr) {
        unawaited(process.stderr.drain<void>());
        yield* process.stdout
            .transform(systemEncoding.decoder)
            .transform(const LineSplitter());
      } else {
        final controller = StreamController<String>();
        var activeStreams = 2;
        void onDone() {
          activeStreams--;
          if (activeStreams == 0) controller.close();
        }
        process.stdout
            .transform(systemEncoding.decoder)
            .transform(const LineSplitter())
            .listen(controller.add, onError: controller.addError, onDone: onDone);
        process.stderr
            .transform(systemEncoding.decoder)
            .transform(const LineSplitter())
            .listen(controller.add, onError: controller.addError, onDone: onDone);
        yield* controller.stream;
      }
      await process.exitCode;
    } finally {
      Exit.disown(process);
    }
  }

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

    // Nothing is going to be written to a captured child, and a child that
    // reads stdin would otherwise wait on a pipe that never closes.
    try {
      await process.stdin.close();
    } catch (_) {}

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

  /// How long a killed process is given to exit before `SIGKILL` follows.
  static const Duration _graceOnKill = Duration(seconds: 3);

  static Future<int> _await(Process process, Duration? timeout) {
    if (timeout == null) return process.exitCode;
    return process.exitCode.timeout(
      timeout,
      onTimeout: () {
        // SIGTERM first, so the child can unwind, then SIGKILL if it ignores
        // it. Without the escalation a process that traps SIGTERM outlives the
        // result that claims to have killed it.
        process.kill();
        Future<void>.delayed(_graceOnKill).then((_) {
          try {
            process.kill(ProcessSignal.sigkill);
          } catch (_) {}
        });
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
  static Future<Never> shutdown([int code = 0]) => Exit.shutdown(code);
}

/// Crash-safe cleanup registry for partial files, child processes and hooks.
///
/// Tracking a resource installs a `SIGINT` watcher so that Ctrl-C removes
/// half-written `.part` files and kills child processes. The watcher is
/// released automatically once nothing is tracked any more, so a script that
/// finishes its work exits without needing [unwatch].
class Exit {
  const Exit._();

  // Keyed by path: dart:io's File has no value equality, so a Set<File> would
  // leave `untrack(File(path))` unable to remove an entry that `track` added
  // through a different instance — and a stuck entry keeps the SIGINT watcher,
  // and so the process, alive forever.
  static final Map<String, File> _files = <String, File>{};
  static final Set<Process> _procs = <Process>{};
  static final List<FutureOr<void> Function()> _hooks = [];
  static final List<StreamSubscription<ProcessSignal>> _signals = [];
  static bool _stopping = false;

  // SIGINT is Ctrl-C; SIGTERM is what `kill`, a supervisor and a container
  // runtime send. Watching only the first left a terminated run's .part files
  // on disk and its exit hooks unrun. Note that SIGTERM is unsupported on Windows.
  static List<ProcessSignal> get _watched => [
    ProcessSignal.sigint,
    if (!Platform.isWindows) ProcessSignal.sigterm,
  ];

  /// Starts watching for `SIGINT` and `SIGTERM`. Safe to call repeatedly.
  static void watch() {
    if (_signals.isNotEmpty) return;
    for (final signal in _watched) {
      try {
        _signals.add(
          signal.watch().listen(
            (_) async {
              // The shell convention: 128 plus the signal number, so a caller
              // can tell a Ctrl-C (130) from a `kill` (143).
              await shutdown(128 + signal.signalNumber);
            },
            onError: (_) {
              // Gracefully ignore unsupported signal errors on some platforms
            },
            cancelOnError: false,
          ),
        );
      } catch (_) {
        // Windows raises for SIGTERM, and signal handling is unavailable
        // entirely on some platforms; cleanup still runs through the explicit
        // `shutdown()` path.
      }
    }
  }

  /// Stops watching for signals and releases the subscriptions.
  ///
  /// A live signal subscription keeps the Dart isolate alive, so this must run
  /// before a script can exit. [untrack], [disown], [unhook] and [shutdown]
  /// call it for you once the last tracked resource is released.
  static void unwatch() {
    for (final signal in _signals) {
      signal.cancel();
    }
    _signals.clear();
  }

  /// Releases the signal watcher when no resources remain tracked.
  static void _idle() {
    if (_files.isEmpty && _procs.isEmpty && _hooks.isEmpty) unwatch();
  }

  /// Registers [file] for deletion if the program is interrupted.
  static void track(File file) {
    watch();
    _files[file.path] = file;
  }

  /// Stops tracking [file] and releases the watcher if nothing else is tracked.
  ///
  /// Matched by path, so any [File] naming the same target unregisters it.
  static void untrack(File file) {
    _files.remove(file.path);
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
  /// the process alive, until [shutdown] runs the hooks.
  static void hook(FutureOr<void> Function() fn) {
    watch();
    _hooks.add(fn);
  }

  /// Unregisters [fn], releasing the watcher if nothing else is tracked.
  ///
  /// A hook registered for the length of one operation has to come off again
  /// when that operation ends: the watcher it installed keeps the process
  /// alive, so a library that registered one and never removed it would leave
  /// every script that used it hanging at exit.
  static void unhook(FutureOr<void> Function() fn) {
    _hooks.remove(fn);
    _idle();
  }

  /// Kills tracked processes, deletes tracked files, runs hooks, then exits.
  ///
  /// Always exits, with [code]. Re-entrant calls wait rather than interleave,
  /// so a second Ctrl-C cannot run the hooks twice.
  static Future<Never> shutdown([int code = 0]) async {
    if (_stopping) {
      // A second caller — a Ctrl-C arriving mid-cleanup — waits for the
      // first to finish rather than racing it, and never returns either.
      while (_stopping) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      exit(code);
    }
    _stopping = true;

    for (final proc in _procs) {
      try {
        proc.kill();
      } catch (_) {}
    }
    _procs.clear();

    for (final file in _files.values) {
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
    exit(code);
  }
}
