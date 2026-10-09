/// The operating system calls that need `dart:ffi`: whether a PID is alive, and the Windows
/// kill-on-close job a child joins. Its own library so that `core` does not compile `dart:ffi`;
/// `process` and `chrome` import it. Not API.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

abstract final class OsBridge {
  /// Assigns child process [pid] to the kill-on-close Windows Job Object.
  static void assignJob(int pid) {
    if (!Platform.isWindows) return;
    _WindowsJob.assign(pid);
  }

  /// Whether process [pid] is alive: one that is there but not this user's counts.
  static bool isPidAlive(int pid) {
    if (Platform.isWindows) {
      try {
        return _WindowsJob.isAlive(pid);
      } on ArgumentError catch (_) {
        return false; // kernel32 without the export: no answer, so not alive
      }
    }
    return _Posix.isAlive(pid);
  }
}

/// `kill(pid, 0)`, the probe that sends nothing.
final class _Posix {
  static final _lib = DynamicLibrary.process();
  static final _kill = _lib.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('kill', isLeaf: true);
  static final _errno = _lib.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
    Platform.isMacOS ? '__error' : '__errno_location',
    isLeaf: true,
  );

  /// Whether [pid] is there: `kill` succeeds, or refuses with EPERM (another user's).
  static bool isAlive(int pid) => pid > 0 && (_kill(pid, 0) == 0 || _errno().value == 1);
}

final class _WindowsJob {
  static final _k32 = DynamicLibrary.open('kernel32.dll');
  static final _createJobObject = _k32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>)
      >('CreateJobObjectW');
  static final _setInformationJobObject = _k32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Void>, int)
      >('SetInformationJobObject');
  static final _assignProcessToJobObject = _k32
      .lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>), int Function(Pointer<Void>, Pointer<Void>)>(
        'AssignProcessToJobObject',
      );
  static final _openProcess = _k32
      .lookupFunction<Pointer<Void> Function(Uint32, Int32, Uint32), Pointer<Void> Function(int, int, int)>(
        'OpenProcess',
      );
  static final _getExitCodeProcess = _k32
      .lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint32>), int Function(Pointer<Void>, Pointer<Uint32>)>(
        'GetExitCodeProcess',
      );
  static final _getLastError = _k32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  static final _closeHandle = _k32.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
    'CloseHandle',
  );
  static final _localAlloc = _k32
      .lookupFunction<Pointer<Void> Function(Uint32, IntPtr), Pointer<Void> Function(int, int)>('LocalAlloc');
  static final _localFree = _k32
      .lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');

  static Pointer<Void>? _handle;

  static Pointer<Void> _getJob() {
    if (_handle != null) return _handle!;
    final job = _createJobObject(nullptr, nullptr);
    if (job.address == 0) return _handle = job;
    final is64 = sizeOf<IntPtr>() == 8;
    final infoSize = is64 ? 144 : 112;
    final info = _localAlloc(0x0040, infoSize); // LMEM_ZEROINIT = 0x0040
    try {
      final byteData = ByteData.sublistView(info.cast<Uint8>().asTypedList(infoSize));
      byteData.setUint32(16, 0x2000, Endian.host); // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
      _setInformationJobObject(job, 9, info, infoSize); // JobObjectExtendedLimitInformation = 9
    } finally {
      _localFree(info);
    }
    return _handle = job;
  }

  static void assign(int pid) {
    try {
      final job = _getJob();
      if (job.address == 0) return;
      // PROCESS_SET_QUOTA (0x0100) | PROCESS_TERMINATE (0x0001)
      final proc = _openProcess(0x0100 | 0x0001, 0, pid);
      if (proc.address == 0) return;
      try {
        _assignProcessToJobObject(job, proc);
      } finally {
        _closeHandle(proc);
      }
    } catch (_) {} // best-effort job object assignment
  }

  static bool isAlive(int pid) {
    // PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    final proc = _openProcess(0x1000, 0, pid);
    if (proc.address == 0) {
      return _getLastError() == 5; // ERROR_ACCESS_DENIED means process exists
    }
    final code = _localAlloc(0x0040, 4);
    try {
      if (_getExitCodeProcess(proc, code.cast<Uint32>()) != 0) {
        return code.cast<Uint32>().value == 259; // STILL_ACTIVE = 259
      }
      return false;
    } finally {
      _localFree(code);
      _closeHandle(proc);
    }
  }
}
