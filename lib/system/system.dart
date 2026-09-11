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

import '../src/proc.dart';
import '../src/shared.dart';
import 'console/console.dart';
import 'env.dart';

export '../src/proc.dart' show SysResult;
export 'console/console.dart';
export 'env.dart';

// ============================================================================
// SYSTEM DOMAIN (system.*) - Processes, Environment, Terminal & Signals
// ============================================================================

final EnvAccessor _env = sharedEnv;

/// The `system` domain: processes, environment, the terminal and signals.
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

  /// Terminal output and input.
  ConsoleAccessor get console => const ConsoleAccessor();

  /// What happens to your resources when the program is interrupted:
  /// signals, tracked files, adopted processes and exit hooks.
  ///
  /// Six of these seven members sat flat on `system` through 4.0.0 —
  /// `watch`, `unwatch`, `track`, `untrack`, `adopt`, `disown` — while
  /// `system.on` held one, `exit`. Rule 3 says a sub-namespace is for a
  /// cohesive vocabulary with its own nouns, and this is that vocabulary: the
  /// structure was inverted. Moving them in also frees the word `watch`, which
  /// `io.observe` had to go without.
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

  /// Resolves [exe] to an absolute executable path, or `null` if not found.
  ///
  /// Searches [paths] first, then `PATH`. On Windows the `.exe`, `.cmd` and
  /// `.bat` extensions are tried for each candidate.
  String? which(String exe, {List<String>? paths}) =>
      Sys.which(exe, paths: paths);

  /// Shuts down in order: kills adopted children, deletes tracked partial
  /// files, runs the [SysEvents.exit] hooks, then exits with [code].
  ///
  /// **The one door out of the process.** A script that registered an exit
  /// hook or watched for signals finishes with this — the watcher holds the
  /// process open until it runs.
  ///
  /// ```dart
  /// await system.shutdown();     // clean finish
  /// await system.shutdown(1);    // clean finish, non-zero status
  /// ```
  ///
  /// `system.exit` was the other door through 5.5.0 — `dart:io`'s `exit`
  /// under this domain's name, skipping every hook `system.on` exists to
  /// guarantee, including the tracked `.part` files. The only reason to reach
  /// for it over this was not knowing the difference, which is the definition
  /// of a footgun, and neither name said which was which. A script that
  /// genuinely means to skip its own cleanup imports `dart:io` and calls
  /// `exit`, and has written down that it meant to.
  ///
  /// Returning `Never` is the other half of the fix: through 5.5.0 this
  /// returned `Future<void>` and left a reachable statement after
  /// `await system.shutdown(1)` that never ran.
  Future<Never> shutdown([int code = 0]) => Sys.shutdown(code);

  /// What this program is running on: platform, cores, host and user.
  ///
  /// A record rather than five loose members, because it is one struct's worth
  /// of facts and reading two of them should not mean two accessors:
  ///
  /// ```dart
  /// final machine = system.os;
  /// await concurrent.run(urls, fetch, size: machine.cpus);
  /// log.info('${machine.user}@${machine.host} on ${machine.name}');
  /// ```
  ///
  /// [name] is Dart's own `'macos'`, `'linux'`, `'windows'`, `'android'`,
  /// `'ios'` or `'fuchsia'`. [windows], [macos] and [linux] stay for the
  /// question a script usually asks, and they are **one line off this
  /// record** — through 5.5.0 they read `Platform.is*` directly, so the
  /// record and the three booleans were two independent readings of one
  /// fact. [host] and [user] are `''` when the platform will not say.
  ({String name, int cpus, String host, String user}) get os => (
    name: Platform.operatingSystem,
    cpus: Platform.numberOfProcessors,
    host: _host(),
    user: _user(),
  );

  static String _host() {
    try {
      return Platform.localHostname;
    } on Object {
      // Unavailable in a sandbox, and a hostname is never worth a crash.
      return '';
    }
  }

  static String _user() {
    final env = Platform.environment;
    return env['USER'] ?? env['USERNAME'] ?? env['LOGNAME'] ?? '';
  }

  /// Whether the host is Windows. One line off [os].
  bool get windows => os.name == 'windows';

  /// Whether the host is macOS. One line off [os].
  bool get macos => os.name == 'macos';

  /// Whether the host is Linux. One line off [os].
  bool get linux => os.name == 'linux';
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

  /// Starts watching for `SIGINT` and `SIGTERM` so tracked resources are
  /// cleaned up on Ctrl-C and on `kill`.
  ///
  /// Writes call this for you. Note that a live watcher keeps the process
  /// alive, so calling it directly pairs with [stop].
  ///
  /// Was `system.on.signals()`, which is the name `io` wanted for a filesystem
  /// watcher and had to settle for `io.observe` instead. `signals` says what
  /// it listens to; `io.watch` is now the one that watches files.
  void signals() => Sys.watch();

  /// Stops watching for signals and releases the subscriptions.
  ///
  /// Was `system.on.stop()`.
  void stop() => Sys.unwatch();

  /// Registers [file] for deletion if the program is interrupted.
  void track(File file) => Sys.track(file);

  /// Stops tracking [file].
  void untrack(File file) => Sys.untrack(file);

  /// Takes responsibility for [process]: it is killed if the program is
  /// interrupted before [disown] is called.
  void adopt(Process process) => Sys.adopt(process);

  /// Gives up responsibility for [process], once it has exited.
  void disown(Process process) => Sys.disown(process);
}
