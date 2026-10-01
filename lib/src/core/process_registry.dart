part of '../../core.dart';

/// PIDs sent SIGTERM that must be confirmed dead (or SIGKILLed) before this process exits.
final _haltedProcessPids = <int>{};

/// Registers [pids] that were sent SIGTERM and must be reaped.
void registerHaltedProcessPids(Iterable<int> pids) => _haltedProcessPids.addAll(pids);

/// Unregisters [pids] once reaped.
void unregisterHaltedProcessPids(Iterable<int> pids) => _haltedProcessPids.removeAll(pids);

/// Waits up to 200 ms for halted processes to exit, then SIGKILLs the rest.
Future<void> killHaltedProcesses() async {
  if (Platform.isWindows || _haltedProcessPids.isEmpty) return;
  final deadline = DateTime.now().add(const Duration(milliseconds: 200));
  while (DateTime.now().isBefore(deadline)) {
    _haltedProcessPids.removeWhere((pid) => !Process.killPid(pid, ProcessSignal.sigcont));
    if (_haltedProcessPids.isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  killHaltedProcessesSync();
}

/// SIGKILLs every registered halted process now.
void killHaltedProcessesSync() {
  if (Platform.isWindows) return;
  for (final pid in _haltedProcessPids) {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
  _haltedProcessPids.clear();
}
