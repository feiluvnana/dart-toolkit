/// # System
///
/// Everything between this program and the machine running it: subprocesses
/// ([run], [runStream], [which]), environment variables ([env], [loadEnv]),
/// the terminal (`console/`) and crash-safe shutdown.
///
/// **[shutdown] is the only way out of the process.** It runs the [onExit]
/// hooks, cleans up files registered with [trackFile] and processes registered
/// with [adoptProcess], and only then terminates. `exit` does none of that.
///
/// ```dart
/// onExit(() async => removePath('.tmp'));
///
/// final res = await run('git', ['status', '--short']);
/// if (res.ok) print(res.stdout);
///
/// await shutdown(0);
/// ```
///
/// Argument parsing is not here. It reads a `List<String>` and touches
/// nothing, so it is the `cli` library.
library;

import 'dart:async';
import 'dart:io';

import '../src/proc.dart' as proc;
import '../src/proc.dart' show SysResult;
import '../src/shared.dart';
import 'env.dart';

export '../src/proc.dart' show SysResult;
export 'console/console.dart';
export 'env.dart';

/// The process environment, with any overrides applied.
///
/// Reads are `env['KEY']`; typed reads with a fallback are [Environment.get].
/// [loadEnv] fills it from a `.env` file.
Environment get env => sharedEnv;

/// Loads environment variables from a `.env` file.
///
/// Returns whether the file was there. Existing values win unless [overwrite]
/// is set, so a real environment variable beats a checked-in default.
bool loadEnv([String path = '.env', bool overwrite = false]) =>
    sharedEnv.load(path, overwrite);

/// Runs [executable] with [arguments] and waits for completion, returning a [SysResult].
Future<SysResult> run(
  String executable,
  List<String> arguments, {
  String? cwd,
  bool inherit = false,
  bool echo = false,
  bool shell = false,
  Duration? timeout,
  void Function(String line)? out,
  void Function(String line)? err,
}) => proc.Sys.run(
  executable,
  arguments,
  cwd: cwd,
  inherit: inherit,
  echo: echo,
  shell: shell,
  timeout: timeout,
  out: out,
  err: err,
);

/// Streams output lines from [executable] with [arguments].
Stream<String> runStream(
  String executable,
  List<String> arguments, {
  String? cwd,
  bool includeStderr = false,
  bool shell = false,
}) => proc.Sys.stream(
  executable,
  arguments,
  cwd: cwd,
  includeStderr: includeStderr,
  shell: shell,
);

/// Resolves [exe] to an absolute executable path using `PATH`, or `null` if not found.
String? which(String exe, {List<String>? paths}) =>
    proc.Sys.which(exe, paths: paths);

/// Registers [callback] to run during graceful shutdown (including SIGINT/Ctrl+C).
void onExit(FutureOr<void> Function() callback) => proc.Sys.hook(callback);

/// Shuts down in order: cleans up tracked processes and temporary files, runs exit hooks, and terminates with [code].
Future<Never> shutdown([int code = 0]) => proc.Sys.shutdown(code);

/// The number of CPU cores available on this machine.
int get cpuCount => Platform.numberOfProcessors;

/// Registers [file] for deletion if the program is interrupted.
///
/// Undone by [untrackFile]. The cleanup runs as part of [shutdown].
void trackFile(File file) => proc.Sys.track(file);

/// Stops tracking [file], leaving it in place on interruption.
void untrackFile(File file) => proc.Sys.untrack(file);

/// Takes responsibility for killing [process] if this program is interrupted.
///
/// Undone by [disownProcess].
void adoptProcess(Process process) => proc.Sys.adopt(process);

/// Gives up responsibility for [process], leaving it running.
void disownProcess(Process process) => proc.Sys.disown(process);
