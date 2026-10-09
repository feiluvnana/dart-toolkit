part of '../base.dart';

/// The halted-subprocess registry `process` and `cli` share: public only because those are
/// separate libraries, and not covered by the versioning promise.
final class ProcessBridge {
  ProcessBridge._();

  /// Whether [error] is a command that could not run at all (exit 126 or 127), which [Retry]
  /// never repeats. Every `ShellException` installs it as it is made, so it answers for each one.
  static bool Function(Object error) cannotRun = _never;

  static bool _never(Object _) => false;

  /// How many children own the terminal now (`Shell.interact`): while above zero, ^C is theirs,
  /// and `Cli` leaves it to them rather than stopping the program.
  static int interactive = 0;

  /// Whether [Env.set] or [Env.parse] has set a variable, so a child needs an environment of its own.
  static bool get isEnvOverridden => Env._isOverridden;

  /// PIDs sent SIGTERM that must be confirmed dead (or SIGKILLed) before this process exits.
  static final Set<int> _haltedProcessPids = <int>{};

  /// Registers [pids] that were sent SIGTERM and must be reaped.
  static void registerHalted(Iterable<int> pids) => _haltedProcessPids.addAll(pids);

  /// Unregisters [pids] once reaped.
  static void unregisterHalted(Iterable<int> pids) => _haltedProcessPids.removeAll(pids);

  /// SIGKILLs every registered halted process now.
  static void killHaltedSync() {
    if (Platform.isWindows) return;
    for (final pid in _haltedProcessPids) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
    _haltedProcessPids.clear();
  }
}
