/// The in-process tree copy shared by `fs` (`Dir.copy`/`Dir.move`) and
/// `archive` (a cross-device unpack): links copied as links, a dest link
/// replaced and never followed, folder modes and mtimes kept and batched.
library;

import 'dart:io' as io;

import 'package:path/path.dart' as p;

import 'posix.dart' as posix;

/// Keep the source file's mtime and mode on a copy.
/// Skips the chmod fork when the mode already matches.
Future<void> preserveFileMeta(String from, String to) async {
  try {
    final st = await io.FileStat.stat(from);
    try {
      await io.File(to).setLastModified(st.modified);
    } catch (_) {}
    try {
      final dst = await io.FileStat.stat(to);
      if ((dst.mode & 0xFFF) != (st.mode & 0xFFF)) {
        await posix.chmod(to, st.mode & 0xFFF);
      }
    } catch (_) {
      await posix.chmod(to, st.mode & 0xFFF);
    }
  } catch (_) {}
}

/// In-process tree copy: the Windows path (no `cp -pPR`, no POSIX modes)
/// and the fallback when `cp` is missing or the destination already exists
/// (merging would nest under `cp`, so an existing tree merges here).
Future<void> copyTree(String from, String to) async {
  // Throws-before-writes for file<->dir collisions: one walk up front.
  await _checkDirCollisions(from, to);
  final dirs = <(String, io.FileStat)>[];
  await _copyTree(from, to, dirs);
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

Future<void> _copyTree(String from, String to, List<(String, io.FileStat)> dirs) async {
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
      await _copyTree(e.path, dest, dirs);
    } else if (e is io.File) {
      files.add((e.path, dest));
    }
  }
  await Future.wait([for (final (from, to) in files) _copyFile(from, to)]);
  try {
    dirs.add((to, await io.FileStat.stat(from)));
  } catch (_) {}
}

Future<void> _copyFile(String from, String to) async {
  // Replace a dest link, never follow it outside the tree.
  if (await io.FileSystemEntity.isLink(to)) await io.Link(to).delete();
  await io.File(from).copy(to);
  await preserveFileMeta(from, to);
}

/// Throw before any writes when a source file would land on a dest dir
/// (or vice versa). Links are replaced, so they never collide.
Future<void> _checkDirCollisions(String from, String to) async {
  await for (final e in io.Directory(from).list(
    recursive: true,
    followLinks: false,
  )) {
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
    if (st == io.FileSystemEntityType.link ||
        dt == io.FileSystemEntityType.link) {
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
