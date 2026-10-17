/// Cross-platform dynamic library loader for sqlite3.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

bool _initialized = false;

/// Ensures the sqlite3 native library is loaded into the current process.
void initSqlite() {
  if (_initialized) return;
  _initialized = true;

  // Try loading if already in the process address space.
  try {
    DynamicLibrary.process().lookup('sqlite3_initialize');
    return;
  } catch (_) {
    // Not loaded in process; search platform candidates.
  }

  final candidates = <String>[];

  if (Platform.isWindows) {
    candidates.addAll([
      // Sibling to script or executable
      p.join(p.dirname(Platform.resolvedExecutable), 'sqlite3.dll'),
      p.join(p.dirname(Platform.script.toFilePath()), 'sqlite3.dll'),
      'sqlite3.dll',
      // Scoop Python install
      r'D:\dev\scoop\apps\python\current\DLLs\sqlite3.dll',
      // Standard Python installs in AppData or Program Files
      if (Platform.environment['LOCALAPPDATA'] case final appData?) ...[
        p.join(appData, 'dart_toolkit', 'sqlite3.dll'),
        p.join(appData, 'Programs', 'Python', 'Python312', 'DLLs', 'sqlite3.dll'),
        p.join(appData, 'Programs', 'Python', 'Python311', 'DLLs', 'sqlite3.dll'),
        p.join(appData, 'Programs', 'Python', 'Python310', 'DLLs', 'sqlite3.dll'),
      ],
      r'C:\Program Files\Python312\DLLs\sqlite3.dll',
      r'C:\Program Files\Python311\DLLs\sqlite3.dll',
    ]);
  } else if (Platform.isMacOS) {
    candidates.addAll([
      // Sibling to script or executable
      p.join(p.dirname(Platform.resolvedExecutable), 'libsqlite3.dylib'),
      p.join(p.dirname(Platform.script.toFilePath()), 'libsqlite3.dylib'),
      // System dynamic library
      '/usr/lib/libsqlite3.dylib',
      // Homebrew (Apple Silicon)
      '/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib',
      '/opt/homebrew/lib/libsqlite3.dylib',
      // Homebrew (Intel)
      '/usr/local/opt/sqlite/lib/libsqlite3.dylib',
      '/usr/local/lib/libsqlite3.dylib',
      // MacPorts
      '/opt/local/lib/libsqlite3.dylib',
      // dyld fallback
      'libsqlite3.dylib',
    ]);
  } else if (Platform.isLinux) {
    candidates.addAll([
      p.join(p.dirname(Platform.resolvedExecutable), 'libsqlite3.so'),
      p.join(p.dirname(Platform.script.toFilePath()), 'libsqlite3.so'),
      'libsqlite3.so.0',
      'libsqlite3.so',
      '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
      '/usr/lib/aarch64-linux-gnu/libsqlite3.so.0',
      '/usr/lib/libsqlite3.so.0',
      '/usr/local/lib/libsqlite3.so',
    ]);
  }

  for (final path in candidates) {
    if (path.contains(Platform.pathSeparator) || path.contains('/')) {
      if (File(path).existsSync()) {
        try {
          DynamicLibrary.open(path);
          return;
        } catch (_) {}
      }
    } else {
      try {
        DynamicLibrary.open(path);
        return;
      } catch (_) {}
    }
  }

  // Fallback: try opening default OS library name via dynamic loader
  try {
    if (Platform.isWindows) {
      DynamicLibrary.open('sqlite3.dll');
    } else if (Platform.isMacOS) {
      DynamicLibrary.open('libsqlite3.dylib');
    } else {
      DynamicLibrary.open('libsqlite3.so');
    }
  } catch (_) {
    // Will throw when sqlite3 function is invoked if not found.
  }
}
