/// POSIX helpers shared by `fs` and `archive`.
///
/// `dart:io` has no `chmod`/`utimes`, so modes and folder mtimes go through
/// child processes. One home for the batching so unpacking 1,000 files forks
/// 2–3 times (one `chmod` per distinct mode) instead of 1,000, and for the
/// platform gates so Windows skips both and `EXDEV` means the right errno per
/// OS. Facades never branch on `Platform.isWindows`; they call here.
library;

import 'dart:io' as io;
import 'dart:math';

import 'package:path/path.dart' as p;

/// True on macOS/Linux; false on Windows. Modes/times helpers are no-ops
/// when false.
bool get isPosix => !io.Platform.isWindows;

/// True only for cross-device renames: `EXDEV` (18) on POSIX,
/// `ERROR_NOT_SAME_DEVICE` (17) on Windows. errno 17 is `EEXIST` on POSIX
/// and must not be treated as cross-device there.
bool isCrossDevice(io.FileSystemException e) {
  final code = e.osError?.errorCode;
  if (code != null) {
    if (io.Platform.isWindows) return code == 17;
    return code == 18;
  }
  final msg = e.message.toLowerCase();
  if (msg.contains('cross-device') || msg.contains('different device')) {
    return true;
  }
  return false;
}

/// `chmod <mode> <path>`, best-effort. No-op on Windows (no POSIX modes).
Future<void> chmod(String path, int mode) async {
  if (!isPosix) return;
  try {
    final perms = mode & 0xFFF;
    final r = await io.Process.run(
      'chmod',
      [perms.toRadixString(8), path],
    );
    if (r.exitCode != 0) return;
  } catch (_) {}
}

/// Batched chmod: one `chmod <mode> p1 p2 …` per distinct mode, chunked so
/// each argv stays well under `ARG_MAX`. Usually 2–3 forks per archive.
Future<void> chmodBatched(Map<int, List<String>> byMode) async {
  if (!isPosix) return;
  for (final entry in byMode.entries) {
    final mode = entry.key & 0xFFF;
    final paths = entry.value;
    // ~200 paths per fork keeps argv far below ARG_MAX on all targets.
    for (var i = 0; i < paths.length; i += 200) {
      final chunk = paths.sublist(
        i,
        i + 200 > paths.length ? paths.length : i + 200,
      );
      if (chunk.isEmpty) continue;
      try {
        await io.Process.run(
          'chmod',
          [mode.toRadixString(8), ...chunk],
        );
      } catch (_) {}
    }
  }
}

/// Group [paths] with parallel [modes] by mode for [chmodBatched].
Map<int, List<String>> groupByMode(List<String> paths, List<int> modes) {
  final out = <int, List<String>>{};
  for (var i = 0; i < paths.length; i++) {
    final mode = modes[i] & 0xFFF;
    (out[mode] ??= []).add(paths[i]);
  }
  return out;
}

/// Set a folder's mtime (`dart:io` has no `Directory.setLastModified`).
/// No-op on Windows. Best-effort; precision differs per OS (macOS `touch -t`
/// keeps whole seconds only; Linux `touch -d @s.frac` keeps sub-seconds) and
/// callers document that.
Future<void> setDirMtime(String path, DateTime mtime) async {
  if (!isPosix) return;
  try {
    final List<String> args;
    if (io.Platform.isMacOS) {
      String two(int n) => n.toString().padLeft(2, '0');
      final t =
          '${mtime.year.toString().padLeft(4, '0')}${two(mtime.month)}${two(mtime.day)}${two(mtime.hour)}${two(mtime.minute)}.${two(mtime.second)}';
      args = ['-t', t, path];
    } else {
      final secs = mtime.millisecondsSinceEpoch / 1000;
      args = ['-d', '@${secs.toStringAsFixed(3)}', path];
    }
    await io.Process.run('touch', args);
  } catch (_) {}
}

/// Copy a tree with `cp -pPR` (keeps modes, times, links) on POSIX.
/// Returns true when `cp` did the work; false when the caller should use its
/// in-process loop (Windows, missing `cp`, non-zero exit).
Future<bool> copyTreeWithCp(String from, String to) async {
  if (!isPosix) return false;
  try {
    final r = await io.Process.run('cp', ['-pPR', from, to]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Unique temp sibling for [target]: `p.join(dir, '.base.tmp…')` so Windows
/// never mixes separators.
String tmpPath(String target) {
  final dir = p.dirname(target);
  final base = p.basename(target);
  final rand = Random().nextInt(1 << 32);
  return p.join(
    dir,
    '.$base.tmp${io.pid}.${DateTime.now().microsecondsSinceEpoch}.$rand',
  );
}
