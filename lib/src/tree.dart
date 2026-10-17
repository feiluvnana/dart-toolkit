/// The in-process tree copy shared by `fs` (`Dir.copy`/`Dir.move`) and
/// `archive` (a cross-device unpack): links copied as links, a dest link
/// replaced and never followed, folder modes and mtimes kept and batched.
library;

import 'dart:io' as io;
import 'dart:math';

import 'package:path/path.dart' as p;

import 'posix.dart' as posix;

/// Keep the source file's mtime and mode on a copy. The mtime is
/// best-effort (some filesystems refuse it); a failed `chmod` throws.
/// Skips the chmod fork when the mode already matches.
Future<void> preserveFileMeta(String from, String to) async {
  final st = await io.FileStat.stat(from);
  try {
    await io.File(to).setLastModified(st.modified);
  } catch (_) {}
  final dst = await io.FileStat.stat(to);
  if ((dst.mode & 0xFFF) != (st.mode & 0xFFF)) await posix.chmod(to, st.mode & 0xFFF);
}

/// In-process tree copy: the Windows path (no `cp -pPR`, no POSIX modes)
/// and the fallback when `cp` is missing or the destination already exists
/// (merging would nest under `cp`, so an existing tree merges here).
///
/// [onBytes] hears each chunk copied (a watched copy); files are then
/// streamed instead of copied by the OS, so the count moves within a file.
Future<void> copyTree(String from, String to, {void Function(int bytes)? onBytes}) async {
  // Throws-before-writes for file<->dir collisions: one walk up front.
  await _checkDirCollisions(from, to);
  final dirs = <(String, io.FileStat)>[];
  await _copyTree(from, to, dirs, onBytes);
  // Folders keep modes AND mtimes, applied after every child is written
  // (writing children bumps them) and batched: one `chmod` per distinct
  // mode and one `touch` per distinct mtime instead of two forks a folder.
  // Both are no-ops on Windows; mtime precision differs per OS (macOS whole
  // seconds, Linux sub-seconds) and the docs say so.
  final byMode = <int, List<String>>{};
  for (final (path, st) in dirs) {
    (byMode[st.mode & 0xFFF] ??= []).add(path);
  }
  await posix.setDirMtimes({for (final (path, st) in dirs) path: st.modified});
  await posix.chmodBatched(byMode);
}

Future<void> _copyTree(String from, String to, List<(String, io.FileStat)> dirs, void Function(int)? onBytes) async {
  await io.Directory(to).create(recursive: true);
  // Files in one folder copy concurrently once the folder is listed (a
  // future started mid-walk could fail with no listener yet); `list` with
  // followLinks:false already tells links, folders and files apart.
  final files = <(String, String)>[];
  await for (final e in io.Directory(from).list(followLinks: false)) {
    final dest = p.join(to, p.basename(e.path));
    if (e is io.Link) {
      final target = await e.target();
      try {
        await io.Link(dest).create(target, recursive: true);
      } on io.FileSystemException {
        // Dest exists (file/link): replace, never follow.
        try {
          await io.Link(dest).delete();
        } catch (_) {
          await io.File(dest).delete();
        }
        await io.Link(dest).create(target, recursive: true);
      }
    } else if (e is io.Directory) {
      // A dest link where a folder goes is replaced, never followed: the
      // copy must not write (or chmod) outside the destination tree.
      if (await io.FileSystemEntity.isLink(dest)) await io.Link(dest).delete();
      await _copyTree(e.path, dest, dirs, onBytes);
    } else if (e is io.File) {
      files.add((e.path, dest));
    }
  }
  await Future.wait([for (final (from, to) in files) _copyFile(from, to, onBytes)]);
  try {
    dirs.add((to, await io.FileStat.stat(from)));
  } catch (_) {}
}

Future<void> _copyFile(String from, String to, void Function(int)? onBytes) async {
  // Replace a dest link, never follow it outside the tree.
  if (await io.FileSystemEntity.isLink(to)) await io.Link(to).delete();
  await copyFile(from, to, onBytes: onBytes);
  await preserveFileMeta(from, to);
}

/// The OS copy of [from] to [to], or with [onBytes] a streamed one that
/// reports each chunk.
Future<void> copyFile(String from, String to, {void Function(int bytes)? onBytes}) async {
  final source = io.Platform.isWindows && await io.FileSystemEntity.isLink(from)
      ? await io.File(from).resolveSymbolicLinks()
      : from;
  if (onBytes == null) {
    await io.File(source).copy(to);
    return;
  }
  await io.File(source)
      .openRead()
      .map((chunk) {
        onBytes(chunk.length);
        return chunk;
      })
      .pipe(io.File(to).openWrite());
}

/// The bytes of every file under [dir], links not followed: a watched
/// folder copy's total.
Future<int> treeBytes(String dir) async {
  var n = 0;
  await for (final e in io.Directory(dir).list(recursive: true, followLinks: false)) {
    if (e is io.File) n += await e.length();
  }
  return n;
}

/// Throw before any writes when a source file would land on a dest dir
/// (or vice versa). Links are replaced, so they never collide.
Future<void> _checkDirCollisions(String from, String to) async {
  await for (final e in io.Directory(from).list(recursive: true, followLinks: false)) {
    final rel = p.relative(e.path, from: from);
    final dest = p.join(to, rel);
    final st = await io.FileSystemEntity.type(e.path, followLinks: false);
    io.FileSystemEntityType? dt;
    try {
      dt = await io.FileSystemEntity.type(dest, followLinks: false);
    } catch (_) {
      continue;
    }
    if (dt == io.FileSystemEntityType.notFound) continue;
    final srcIsDir = st == io.FileSystemEntityType.directory;
    final destIsDir = dt == io.FileSystemEntityType.directory;
    // Links are replaced, not collided.
    if (st == io.FileSystemEntityType.link || dt == io.FileSystemEntityType.link) {
      continue;
    }
    if (srcIsDir != destIsDir) {
      throw io.FileSystemException(
        'copy collides: ${srcIsDir ? 'directory' : 'file'} over ${destIsDir ? 'directory' : 'file'}',
        dest,
      );
    }
  }
}

/// Sorts [items] depth-first by their path relative to [from]: one
/// `p.relative` per item, and both separators compare lowest so `a/b` sorts
/// before `a-b` and mixed `/` and `\\` paths order the same.
void sortByRelative<T>(List<T> items, String Function(T) path, String from) {
  final key = {for (final e in items) e: p.relative(path(e), from: from).replaceAll(_sep, '\x00')};
  items.sort((a, b) => key[a]!.compareTo(key[b]!));
}

final _sep = RegExp(r'[\\/]');

/// Unique temp sibling for [target]: `p.join(dir, '.base.tmp…')` so Windows
/// never mixes separators; long names are cut so the temp still fits.
String tmpPath(String target) {
  final dir = p.dirname(target);
  // At most 32 runes (128 bytes) of the name: the suffix adds ~40, and a
  // 255-byte name must still get a temp under NAME_MAX.
  final base = String.fromCharCodes(p.basename(target).runes.take(32));
  final rand = Random().nextInt(1 << 32);
  return p.join(dir, '.$base.tmp${io.pid}.${DateTime.now().microsecondsSinceEpoch}.$rand');
}
