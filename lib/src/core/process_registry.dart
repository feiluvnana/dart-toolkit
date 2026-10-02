part of '../../core.dart';

/// The halted-subprocess registry `process` and `cli` share: public only because those are
/// separate libraries, and not covered by the versioning promise.
final class ProcessBridge {
  ProcessBridge._();

  /// PIDs sent SIGTERM that must be confirmed dead (or SIGKILLed) before this process exits.
  static final Set<int> _haltedProcessPids = <int>{};

  /// Registers [pids] that were sent SIGTERM and must be reaped.
  static void registerHalted(Iterable<int> pids) => _haltedProcessPids.addAll(pids);

  /// Unregisters [pids] once reaped.
  static void unregisterHalted(Iterable<int> pids) => _haltedProcessPids.removeAll(pids);

  /// Waits up to 200 ms for halted processes to exit, then SIGKILLs the rest.
  static Future<void> killHalted() async {
    if (Platform.isWindows || _haltedProcessPids.isEmpty) return;
    final deadline = DateTime.now().add(const Duration(milliseconds: 200));
    while (DateTime.now().isBefore(deadline)) {
      _haltedProcessPids.removeWhere((pid) => !Process.killPid(pid, ProcessSignal.sigcont));
      if (_haltedProcessPids.isEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    killHaltedSync();
  }

  /// SIGKILLs every registered halted process now.
  static void killHaltedSync() {
    if (Platform.isWindows) return;
    for (final pid in _haltedProcessPids) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
    _haltedProcessPids.clear();
  }
}
