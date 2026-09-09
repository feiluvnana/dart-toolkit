/// # System Domain (`system.*`)
///
/// Everything between this program and the machine running it: subprocesses,
/// environment variables (`system.env`), CLI arguments (`system.cli`), the
/// terminal (`system.console`) and crash-safe shutdown.
library;

import 'dart:async';
import 'dart:io' hide exit;
import 'dart:io' as io show exit;

import '../src/proc.dart';
import '../src/shared.dart';
import 'cli.dart';
import 'console/console.dart';
import 'env.dart';

export '../src/proc.dart' show SysResult;
export 'cli.dart';
export 'console/console.dart';
export 'env.dart';

// ============================================================================
// SYSTEM DOMAIN (system.*) - Processes, Environment, CLI & Signals
// ============================================================================

final EnvAccessor _env = sharedEnv;
final CliAccessor _cli = CliAccessor();

/// The `system` domain: processes, environment, CLI arguments and signals.
const SystemAccessor system = SystemAccessor();

/// Entry point for subprocess execution and OS integration.
///
/// ```dart
/// final res = await system.run('git', ['status', '--short']);
/// if (res.ok) print(res.out);
/// ```
class SystemAccessor {
  /// Creates the accessor. Prefer the shared [system] instance.
  const SystemAccessor();

  /// Environment variables and `.env` loading.
  EnvAccessor get env => _env;

  /// Command-line argument parsing.
  CliAccessor get cli => _cli;

  /// Terminal output and input.
  ConsoleAccessor get console => const ConsoleAccessor();

  /// Shutdown events. See [SysEvents.exit].
  SysEvents get on => const SysEvents();

  /// Runs [executable] with [arguments] and waits for it to exit.
  ///
  /// See [SysResult]. By default output is captured; set [inherit] to stream
  /// it to the terminal instead. When [timeout] elapses the process is killed
  /// and the result carries code `-1`.
  Future<SysResult> run(
    String executable,
    List<String> arguments, {
    String? cwd,
    bool inherit = false,
    bool echo = false,
    Duration? timeout,
    void Function(String line)? out,
    void Function(String line)? err,
  }) => Sys.run(
    executable,
    arguments,
    cwd: cwd,
    inherit: inherit,
    echo: echo,
    timeout: timeout,
    out: out,
    err: err,
  );

  /// Resolves [tool] to an absolute executable path, or `null` if not found.
  ///
  /// Searches [paths] first, then `PATH`. On Windows the `.exe`, `.cmd` and
  /// `.bat` extensions are tried for each candidate.
  String? which(String tool, {List<String>? paths}) =>
      Sys.which(tool, paths: paths);

  /// Starts watching for `SIGINT` and `SIGTERM` so tracked resources are
  /// cleaned up on Ctrl-C and on `kill`.
  ///
  /// Writes call this for you. Note that a live watcher keeps the process
  /// alive, so calling it directly pairs with [unwatch].
  void watch() => Sys.watch();

  /// Stops watching for signals and releases the subscriptions.
  void unwatch() => Sys.unwatch();

  /// Registers [file] for deletion if the program is interrupted.
  void track(File file) => Sys.track(file);

  /// Stops tracking [file].
  void untrack(File file) => Sys.untrack(file);

  /// Takes responsibility for [process]: it is killed if the program is
  /// interrupted before [disown] is called.
  void adopt(Process process) => Sys.adopt(process);

  /// Gives up responsibility for [process], once it has exited.
  void disown(Process process) => Sys.disown(process);

  /// Shuts down in order: kills adopted children, deletes tracked partial
  /// files, runs the [SysEvents.exit] hooks, then exits with [code] when it is
  /// non-zero.
  ///
  /// A script that registered an exit hook or watched for signals finishes
  /// with this — the watcher holds the process open until it runs.
  ///
  /// ```dart
  /// await system.shutdown();     // clean finish
  /// await system.shutdown(1);    // clean finish, non-zero status
  /// ```
  Future<void> shutdown([int code = 0]) => Sys.shutdown(code);

  /// Terminates the process immediately with [code], skipping cleanup.
  ///
  /// Prefer [shutdown], which removes partial files and kills child processes
  /// first.
  Never exit([int code = 0]) => io.exit(code);

  /// Whether the host is Windows.
  bool get windows => Platform.isWindows;

  /// Whether the host is macOS.
  bool get macos => Platform.isMacOS;

  /// Whether the host is Linux.
  bool get linux => Platform.isLinux;
}

/// Shutdown events, reachable as `system.on`.
class SysEvents {
  /// Creates the accessor. Prefer the shared `system.on` instance.
  const SysEvents();

  /// Registers [callback] to run during graceful shutdown.
  ///
  /// Hooks run after adopted child processes are killed and tracked partial
  /// files are deleted. A registered hook keeps the signal watcher — and so
  /// the process — alive until [SystemAccessor.shutdown] runs it.
  void exit(FutureOr<void> Function() callback) => Sys.hook(callback);
}
