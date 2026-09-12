/// # System Domain (`system.*`)
///
/// Everything between this program and the machine running it: subprocesses,
/// environment variables (`system.env`), the terminal (`system.console`) and
/// crash-safe shutdown — which is `system.on`, holding the whole vocabulary
/// for what happens to your files and child processes when the program is
/// interrupted: `signals`, `track`, `untrack`, `adopt`, `disown` and `exit`.
///
/// **`system.shutdown` is the only way out of the process.** It runs those
/// hooks; `system.exit` did not, and was deleted for it.
/// Six of those sat flat on `system` through 4.0.0 while `system.on` held only
/// `exit`, which had the namespace on the single function and the family
/// beside it — and cost `io` the name `watch`, which it now has back.
///
/// Argument parsing is not here. It reads a `List<String>` and touches nothing,
/// so it is the `cli` domain.
library;

import 'dart:async';
import 'dart:io';

import '../src/proc.dart' as proc;
import '../src/proc.dart' show SysResult;
import '../src/shared.dart';
import 'console/console.dart';
import 'env.dart';

export '../src/proc.dart' show SysResult;
export 'console/console.dart';
export 'env.dart';

// ============================================================================
// TOP-LEVEL SUBPROCESS, ENVIRONMENT & LIFECYCLE
// ============================================================================

final EnvAccessor _env = sharedEnv;

/// Access to environment variables.
EnvAccessor get env => _env;

/// Loads environment variables from a `.env` file.
bool loadEnv([String path = '.env', bool overwrite = false]) =>
    _env.load(path, overwrite);

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

// ============================================================================
// STATIC HELPER HUB: System / Sys
// ============================================================================

/// Static helper hub for subprocesses, environment, and system lifecycle.
///
/// Easily discoverable via IDE auto-complete:
/// ```dart
/// final res = await System.run('git', ['status']);
/// print(res.stdout);
/// ```
abstract final class System {
  System._();

  /// Runs [executable] with [arguments] and waits for completion.
  static Future<SysResult> run(
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
  static Stream<String> runStream(
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
  static String? which(String exe, {List<String>? paths}) =>
      proc.Sys.which(exe, paths: paths);

  /// The number of CPU cores available on this machine.
  static int get cpus => Platform.numberOfProcessors;

  /// Registers [callback] to run during graceful shutdown.
  static void onExit(FutureOr<void> Function() callback) =>
      proc.Sys.hook(callback);

  /// Shuts down the process cleanly after running exit hooks.
  static Future<Never> shutdown([int code = 0]) => proc.Sys.shutdown(code);

  /// Access to environment variables.
  static EnvAccessor get env => _env;

  /// Console / terminal input and output.
  static ConsoleAccessor get console => const ConsoleAccessor();

  /// Registers [file] for deletion if the program is interrupted.
  static void track(File file) => proc.Sys.track(file);

  /// Stops tracking [file].
  static void untrack(File file) => proc.Sys.untrack(file);

  /// Takes responsibility for [process] on program interruption.
  static void adopt(Process process) => proc.Sys.adopt(process);

  /// Gives up responsibility for [process].
  static void disown(Process process) => proc.Sys.disown(process);
}

/// Shorthand alias for [System].
typedef Sys = System;

/// The shared `system` accessor.
const SystemAccessor system = SystemAccessor();

/// Accessor for system capabilities.
class SystemAccessor {
  /// Creates the accessor.
  const SystemAccessor();

  /// Runs [executable] with [arguments].
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
  }) => System.run(
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

  /// Shuts down the process cleanly.
  Future<Never> shutdown([int code = 0]) => System.shutdown(code);

  /// Environment variables.
  EnvAccessor get env => _env;

  /// Console input and output.
  ConsoleAccessor get console => const ConsoleAccessor();

  /// Resolves executable path.
  String? which(String exe, {List<String>? paths}) => System.which(exe, paths: paths);

  /// Registers exit callback.
  void onExit(FutureOr<void> Function() callback) => System.onExit(callback);
}
