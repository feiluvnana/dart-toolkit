/// POSIX helpers shared by `fs`, `archive` and `http` (no package imports,
/// so `http` pays nothing for its cache folder's chmod).
///
/// `dart:io` has no `chmod`/`utimes`, so modes and folder mtimes go through
/// child processes. One home for the batching so unpacking 1,000 files forks
/// 2–3 times (one `chmod` per distinct mode) instead of 1,000, and for the
/// platform gates so Windows skips both and `EXDEV` means the right errno per
/// OS. Facades never branch on `Platform.isWindows`; they call here.
library;

import 'dart:io' as io;
import 'dart:math';

/// Write [input] to [file]. A failed source (or write) surfaces as itself,
/// never as the sink's `File closed` naming [file] on the way out.
Future<void> writeAll(io.File file, Stream<List<int>> input) async {
  final sink = file.openWrite();
  try {
    await sink.addStream(input);
  } catch (e, st) {
    try {
      await sink.close();
    } catch (_) {}
    Error.throwWithStackTrace(e, st);
  }
  await sink.close();
}

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

/// `chmod <mode> <path>`. No-op on Windows (no POSIX modes). A non-zero
/// exit throws a [io.FileSystemException] with the tool's message.
Future<void> chmod(String path, int mode) => chmodBatched({
  mode: [path],
});

/// Batched chmod (throws like [chmod]): one `chmod <mode> p1 p2 …` per distinct mode, chunked so
/// each argv stays well under `ARG_MAX`. Usually 2–3 forks per archive.
Future<void> chmodBatched(Map<int, List<String>> byMode) async {
  if (!isPosix) return;
  for (final entry in byMode.entries) {
    final mode = entry.key & 0xFFF;
    final paths = entry.value;
    // ~200 paths per fork keeps argv far below ARG_MAX on all targets.
    for (var i = 0; i < paths.length; i += 200) {
      final chunk = paths.sublist(i, i + 200 > paths.length ? paths.length : i + 200);
      if (chunk.isEmpty) continue;
      // `--` goes before the mode: BSD chmod reads the operand after the mode
      // as a file, so `chmod 644 -- f` fails on `--` (exit 1).
      await _run('chmod', ['--', mode.toRadixString(8), ...chunk], chunk);
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
/// No-op on Windows; a failed `touch` throws. Precision differs per OS (macOS `touch -t`
/// keeps whole seconds only; Linux `touch -d @s.frac` keeps milliseconds)
/// and callers document that.
Future<void> setDirMtime(String path, DateTime mtime) => setDirMtimes({path: mtime});

/// [setDirMtime] for many folders (a failed `touch` throws): one `touch` per distinct stamp (at the
/// precision `touch` keeps) and ~200 paths, not one fork per folder.
Future<void> setDirMtimes(Map<String, DateTime> mtimes) async {
  if (!isPosix) return;
  final byStamp = <String, List<String>>{};
  for (final MapEntry(key: path, value: mtime) in mtimes.entries) {
    (byStamp[_touchStamp(mtime)] ??= []).add(path);
  }
  for (final MapEntry(key: stamp, value: paths) in byStamp.entries) {
    for (var i = 0; i < paths.length; i += 200) {
      final chunk = paths.sublist(i, min(i + 200, paths.length));
      await _run('touch', [io.Platform.isMacOS ? '-t' : '-d', stamp, '--', ...chunk], chunk);
    }
  }
}

/// Run a POSIX tool; a non-zero exit throws with its stderr and the first
/// path it was given.
Future<void> _run(String tool, List<String> args, List<String> paths) async {
  final r = await io.Process.run(tool, args);
  if (r.exitCode == 0) return;
  final err = '${r.stderr}'.trim();
  throw io.FileSystemException('$tool failed (exit ${r.exitCode})${err.isEmpty ? '' : ': $err'}', paths.first);
}

String _touchStamp(DateTime mtime) {
  if (!io.Platform.isMacOS) {
    return '@${(mtime.millisecondsSinceEpoch / 1000).toStringAsFixed(3)}';
  }
  String two(int n) => n.toString().padLeft(2, '0');
  return '${mtime.year.toString().padLeft(4, '0')}${two(mtime.month)}${two(mtime.day)}'
      '${two(mtime.hour)}${two(mtime.minute)}.${two(mtime.second)}';
}

/// Copy a tree with `cp -pPR` (keeps modes, times, links) on POSIX.
/// Returns true when `cp` did the work; false when the caller should use its
/// in-process loop (Windows, or no `cp` to start). A `cp` that fails throws
/// its own message: running the copy again would only hide it.
Future<bool> copyTreeWithCp(String from, String to) async {
  if (!isPosix) return false;
  final io.ProcessResult r;
  try {
    r = await io.Process.run('cp', ['-pPR', '--', from, to]);
  } on io.ProcessException {
    return false;
  }
  if (r.exitCode != 0) throw io.FileSystemException('copy failed: ${'${r.stderr}'.trim()}', from);
  return true;
}

/// True for a name [tmpPath] made: `.<base>.tmp<pid>.<µs>.<rand>`.
bool isTmpName(String name) => _tmpName.hasMatch(name);

final _tmpName = RegExp(r'^\..*\.tmp\d+\.\d+\.\d+$');
