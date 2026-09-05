import 'dart:async';
import 'dart:io' hide exit;
import 'dart:io' as io_pkg show exit;

import 'cli.dart';
import 'env.dart';
import 'sys.dart';

export 'cli.dart';
export 'env.dart';
export 'sys.dart';

// ============================================================================
final SysEvents _sysEvents = SysEvents();
final EnvAccessor _sysEnv = EnvAccessor();
final CliAccessor _sysCli = CliAccessor();

/// Top-level System & OS domain accessor singleton (`system.*`).
///
/// Provides unified access to subprocess execution, environment variables, CLI args, and shutdown signals.
///
/// ```dart
/// // Execute process
/// final res = await system.run('git', ['status']);
///
/// // Environment variables
/// final apiKey = system.env.get('API_KEY');
///
/// // Command-line arguments
/// system.cli.parse(args);
/// final verbose = system.cli.has('verbose', 'v');
/// ```
const SystemAccessor system = SystemAccessor();

/// Top-level System and OS domain accessor.
class SystemAccessor {
  const SystemAccessor();

  /// Sub-namespace for environment variables and `.env` loader (`system.env.*`).
  EnvAccessor get env => _sysEnv;

  /// Sub-namespace for command-line arguments parsing (`system.cli.*`).
  CliAccessor get cli => _sysCli;

  /// Sub-namespace for system lifecycle event listeners (`system.on.*`).
  SysEvents get on => _sysEvents;

  // --- Forwarded subprocess execution & OS methods ---

  /// Executes an external command and captures stdout/stderr (1-word).
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

  /// Resolves the absolute path of an executable tool in PATH (1-word).
  String? which(String tool) => Sys.which(tool);

  /// Starts and returns a benchmark stopwatch (1-word).
  Stopwatch clock() => Stopwatch()..start();

  /// Intercepts termination signals (SIGINT, SIGTERM) for graceful shutdown (1-word).
  void listen() => Sys.listen();

  /// Stops listening for termination signals (1-word).
  void unlisten() => Sys.unlisten();

  /// Registers a temporary file to be automatically deleted on shutdown (1-word).
  void track(File file) => Sys.track(file);

  /// Untracks a file after it has completed successfully, preventing cleanup.
  void untrack(File file) => Sys.untrack(file);

  /// Tracks a child [process] to terminate on exit.
  void proc(Process process) => Sys.proc(process);

  /// Untracks a child [process] after completion.
  void unproc(Process process) => Sys.unproc(process);

  /// Registers a cleanup hook to run on process exit (1-word).
  void hook(FutureOr<void> Function() fn) => Sys.hook(fn);

  /// Triggers an immediate graceful shutdown, executing hooks and cleaning up tracked files (1-word).
  Future<void> now([int code = 0]) => Sys.now(code);

  /// Terminates the process with an exit [code] (1-word).
  Never exit([int code = 0]) => io_pkg.exit(code);

  /// Whether the current OS is Windows.
  bool get win => Platform.isWindows;

  /// Whether the current OS is macOS.
  bool get mac => Platform.isMacOS;

  /// Whether the current OS is Linux or Unix-based.
  bool get nix => Platform.isLinux;
}
