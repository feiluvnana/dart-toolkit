part of '../../core.dart';

/// Registry of halted process tree PIDs that must be confirmed dead or SIGKILLed
/// before the current process terminates.
final Set<int> _haltedProcessPids = <int>{};

/// Registers process [pids] that were sent SIGTERM and must be reaped.
void registerHaltedProcessPids(Iterable<int> pids) {
  _haltedProcessPids.addAll(pids);
}

/// Unregisters process [pids] once reaped or exited.
void unregisterHaltedProcessPids(Iterable<int> pids) {
  _haltedProcessPids.removeAll(pids);
}

/// Waits up to 200 ms for any halted processes to exit, then sends SIGKILL to any still alive.
Future<void> killHaltedProcesses() async {
  if (Platform.isWindows || _haltedProcessPids.isEmpty) return;
  final deadline = DateTime.now().add(const Duration(milliseconds: 200));
  while (DateTime.now().isBefore(deadline)) {
    _haltedProcessPids.removeWhere((pid) => !Process.killPid(pid, ProcessSignal.sigcont));
    if (_haltedProcessPids.isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  for (final pid in _haltedProcessPids) {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
  _haltedProcessPids.clear();
}

/// Synchronously SIGKILLs all registered halted processes immediately.
void killHaltedProcessesSync() {
  if (Platform.isWindows || _haltedProcessPids.isEmpty) return;
  for (final pid in _haltedProcessPids) {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
  _haltedProcessPids.clear();
}
