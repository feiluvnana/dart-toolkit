/// Typed file-system handles. Thin facade over `dart:io` and `package:path`.
///
/// ```dart
/// switch (await Fs.entry(args.first)) {
///   case File file: print('file, ${await file.size()} bytes');
///   case Dir dir: print('folder of ${(await dir.list()).length}');
///   case Link link: print('link → ${await link.target()}');
///   case null: print('nothing there');
/// }
/// await (Fs.file('a.iso') | hash > Fs.file('b.iso'));
/// ```
///
/// Public surface is exactly: [Fs], [Entry], [File], [Dir], [Link].
/// - `Fs.entry/file/dir/link()` inspect or build handles (no I/O for the latter three).
/// - [Entry] supports `path` `name` `parent` `exists` `delete` `copy` `move`.
/// - [File] supports `write` `append` `size` (plus [Reader]/[Writer]).
/// - [Dir] supports `file` `dir` `list` `create`.
/// - [Link] supports `target` `resolve` `create`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:path/path.dart' as p;

import 'core.dart';
export 'core.dart';

/// Entry point: inspect the disk or build handles (handles do no I/O).
abstract final class Fs {
  /// What is on disk now: a [File], [Dir], [Link], or null. Never follows links.
  static Future<Entry?> entry(String path) async {
    final type = await io.FileSystemEntity.type(path, followLinks: false);
    return switch (type) {
      io.FileSystemEntityType.file => File._(path),
      io.FileSystemEntityType.directory => Dir._(path),
      io.FileSystemEntityType.link => Link._(path),
      _ => null,
    };
  }

  /// A file handle. No I/O; the target need not exist.
  static File file(String path) => File._(path);

  /// A folder handle. No I/O; the target need not exist.
  static Dir dir(String path) => Dir._(path);

  /// A link handle. No I/O; the target need not exist.
  static Link link(String path) => Link._(path);
}

/// A path on disk: a [File], [Dir], or [Link].
sealed class Entry {
  Entry._(String path) : _path = _strip(path);

  final String _path;

  /// The string as given, without trailing separators.
  String path() => _path;

  /// The last segment.
  String name() => p.basename(_path);

  /// The containing folder. The root's parent is the root.
  Dir parent() => Dir._(p.dirname(_path));

  /// True only when something of this handle's kind is there.
  Future<bool> exists();

  /// Remove a file, a link (never its target) or a whole folder.
  /// A no-op when nothing is there.
  Future<void> delete();

  /// Filesystem copy to [to]: keeps metadata, creates parents, recursive for
  /// folders (links as links). Returns a handle of the same type at [to].
  Future<Entry> copy(String to);

  /// Rename to [to], falling back to copy-then-delete across devices.
  /// Returns a handle of the same type at [to].
  Future<Entry> move(String to);

  @override
  bool operator ==(Object other) =>
      other is Entry &&
      other.runtimeType == runtimeType &&
      other._path == _path;

  @override
  int get hashCode => Object.hash(runtimeType, _path);
}

/// A file: a [Reader] in 64 KiB chunks, a [Writer] written atomically.
final class File extends Entry with Reader implements Writer {
  File._(super.path) : super._();

  @override
  Future<bool> exists() async {
    final t = await io.FileSystemEntity.type(_path, followLinks: false);
    return t == io.FileSystemEntityType.file;
  }

  @override
  Future<void> delete() async {
    try {
      await io.File(_path).delete();
    } on io.PathNotFoundException {
      // no-op when nothing is there
    } on io.FileSystemException catch (e) {
      if (!await _missing(e)) rethrow;
    }
  }

  @override
  Future<File> copy(String to) async {
    await _checkSource(_path, to, io.FileSystemEntityType.file);
    await _ensureParent(to);
    await _removeDestLink(to);
    await io.File(_path).copy(to);
    await _preserveFileMeta(_path, to);
    return File._(to);
  }

  @override
  Future<File> move(String to) async {
    await _checkSource(_path, to, io.FileSystemEntityType.file);
    await _ensureParent(to);
    await _removeDestLink(to);
    try {
      await io.File(_path).rename(to);
    } on io.FileSystemException catch (e) {
      // Rename across devices is EXDEV (18); anything else (missing
      // source, occupied destination, permissions) must surface.
      if (!_isExdev(e)) rethrow;
      await io.File(_path).copy(to);
      await _preserveFileMeta(_path, to);
      await io.File(_path).delete();
    }
    return File._(to);
  }

  /// Replace the content with in-memory [data] (`String` as UTF-8 or
  /// `List<int>` as is; anything else is an [ArgumentError]), atomically.
  /// Creates missing parents. Returns this file.
  Future<File> write(Object data) async {
    await _ensureParent(_path);
    await _atomicWrite(Stream.value(_toBytes(data)));
    return this;
  }

  /// Add in-memory [data] to the end. Creates missing parents. Returns this.
  Future<File> append(Object data) async {
    await _ensureParent(_path);
    await io.File(_path).writeAsBytes(
      _toBytes(data),
      mode: io.FileMode.append,
      flush: true,
    );
    return this;
  }

  /// Size in bytes.
  Future<int> size() => io.File(_path).length();

  @override
  Stream<List<int>> stream() => io.File(_path).openRead();

  @override
  Future<List<int>> bytes() => io.File(_path).readAsBytes();

  @override
  Future<String> text() async =>
      utf8.decode(await bytes(), allowMalformed: true);

  @override
  Future<void> consume(Stream<List<int>> input) async {
    await _ensureParent(_path);
    await _atomicWrite(input);
  }

  Future<void> _atomicWrite(Stream<List<int>> input) async {
    // Writes go through symlinks to their real target (F7): resolve first so
    // a handle pointing at a link updates the target instead of replacing
    // the link with a regular file. Broken links fall back to the handle
    // path (rename will replace the link).
    var target = _path;
    try {
      final t =
          await io.FileSystemEntity.type(_path, followLinks: false);
      if (t == io.FileSystemEntityType.link) {
        try {
          target = await io.Link(_path).resolveSymbolicLinks();
        } catch (_) {
          target = _path;
        }
      }
    } catch (_) {}
    // Remember the old mode so the atomic replace keeps it (755 stays 755).
    var oldMode = 0;
    try {
      final st = await io.FileStat.stat(target);
      oldMode = st.mode & 0xFFF;
    } catch (_) {}
    final dir = p.dirname(target);
    final tmp =
        '$dir/.${p.basename(target)}.tmp${io.pid}.${DateTime.now().microsecondsSinceEpoch}.${Random().nextInt(1 << 32)}';
    final tmpFile = io.File(tmp);
    try {
      final sink = tmpFile.openWrite();
      try {
        await sink.addStream(input);
        await sink.close();
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {}
        rethrow;
      }
      await tmpFile.rename(target);
      // Keep the old file's mode after the rename (POSIX only,
      // best-effort elsewhere).
      if (oldMode != 0) await _chmod(target, oldMode);
    } catch (_) {
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      rethrow;
    }
  }

  static List<int> _toBytes(Object data) {
    if (data is String) return utf8.encode(data);
    if (data is List<int>) return data;
    throw ArgumentError.value(
      data,
      'data',
      'must be a String or List<int>',
    );
  }
}

/// A folder.
final class Dir extends Entry {
  Dir._(super.path) : super._();

  /// A file handle under this folder. No I/O.
  File file(String name) => File._(p.join(_path, name));

  /// A folder handle under this folder. No I/O.
  Dir dir(String name) => Dir._(p.join(_path, name));

  /// Typed children, sorted by name. With [recursive], descends into
  /// subfolders but never through links.
  Future<List<Entry>> list({bool recursive = false}) async {
    final out = <Entry>[];
    await for (final e in io.Directory(_path).list(
      recursive: recursive,
      followLinks: false,
    )) {
      // With followLinks:false the stream never descends through links,
      // and its runtime type already tells links apart: no extra stat.
      if (e is io.Link) {
        out.add(Link._(e.path));
      } else if (e is io.File) {
        out.add(File._(e.path));
      } else if (e is io.Directory) {
        out.add(Dir._(e.path));
      }
    }
    out.sort((a, b) => a.path().compareTo(b.path()));
    return out;
  }

  /// `mkdir -p`. A no-op when the folder exists. Returns this.
  Future<Dir> create() async {
    await io.Directory(_path).create(recursive: true);
    return this;
  }

  @override
  Future<bool> exists() async {
    final t = await io.FileSystemEntity.type(_path, followLinks: false);
    return t == io.FileSystemEntityType.directory;
  }

  @override
  Future<void> delete() async {
    try {
      await io.Directory(_path).delete(recursive: true);
    } on io.PathNotFoundException {
      // no-op
    } on io.FileSystemException catch (e) {
      if (!await _missing(e)) rethrow;
    }
  }

  @override
  Future<Dir> copy(String to) async {
    await _checkSource(_path, to, io.FileSystemEntityType.directory);
    await _ensureParent(to);
    await _removeDestLink(to);
    await _copyDir(_path, to);
    return Dir._(to);
  }

  @override
  Future<Dir> move(String to) async {
    await _checkSource(_path, to, io.FileSystemEntityType.directory);
    await _ensureParent(to);
    await _removeDestLink(to);
    try {
      await io.Directory(_path).rename(to);
    } on io.FileSystemException catch (e) {
      // Only EXDEV falls back to copy-then-delete. Anything else (e.g.
      // moving into a non-empty folder, permissions) must rethrow instead
      // of silently merging/overwriting and deleting the source.
      if (!_isExdev(e)) rethrow;
      await _copyDir(_path, to);
      await io.Directory(_path).delete(recursive: true);
    }
    return Dir._(to);
  }
}

/// A symlink.
final class Link extends Entry {
  Link._(super.path) : super._();

  /// The stored target string.
  Future<String> target() => io.Link(_path).target();

  /// Follow the chain to what is finally there, or null when broken.
  /// Returns a handle AT THE TARGET path (not the link's own path).
  Future<Entry?> resolve() async {
    String resolved;
    try {
      resolved = await io.Link(_path).resolveSymbolicLinks();
    } catch (_) {
      return null;
    }
    final t =
        await io.FileSystemEntity.type(resolved, followLinks: false);
    return switch (t) {
      io.FileSystemEntityType.file => File._(resolved),
      io.FileSystemEntityType.directory => Dir._(resolved),
      io.FileSystemEntityType.link => Link._(resolved),
      _ => null,
    };
  }

  /// Make the link, replacing an existing link or file atomically.
  /// A temp link is created next to the target and renamed over it.
  /// Returns this.
  Future<Link> create(String target) async {
    await _ensureParent(_path);
    final dir = p.dirname(_path);
    final tmp =
        '$dir/.${p.basename(_path)}.tmp${io.pid}.${DateTime.now().microsecondsSinceEpoch}.${Random().nextInt(1 << 32)}';
    final tmpLink = io.Link(tmp);
    await tmpLink.create(target, recursive: true);
    try {
      try {
        await tmpLink.rename(_path);
      } on io.FileSystemException {
        // POSIX rename replaces a link or file atomically. On platforms
        // where rename over an existing file fails, remove the destination
        // (link only: never a folder) and retry once.
        final dt = await io.FileSystemEntity.type(
          _path,
          followLinks: false,
        );
        if (dt == io.FileSystemEntityType.directory) {
          await tmpLink.delete();
          throw io.FileSystemException(
            'cannot replace directory with link',
            _path,
          );
        }
        if (dt != io.FileSystemEntityType.notFound) {
          try {
            await io.Link(_path).delete();
          } catch (_) {
            await io.File(_path).delete();
          }
          await tmpLink.rename(_path);
        } else {
          rethrow;
        }
      }
    } catch (_) {
      try {
        await tmpLink.delete();
      } catch (_) {}
      rethrow;
    }
    return this;
  }

  @override
  Future<bool> exists() async {
    final t = await io.FileSystemEntity.type(_path, followLinks: false);
    return t == io.FileSystemEntityType.link;
  }

  @override
  Future<void> delete() async {
    try {
      await io.Link(_path).delete();
    } on io.PathNotFoundException {
      // no-op
    } on io.FileSystemException catch (e) {
      if (!await _missing(e)) rethrow;
    }
  }

  @override
  Future<Link> copy(String to) async {
    await _checkSource(_path, to, io.FileSystemEntityType.link);
    await _ensureParent(to);
    final t = await target();
    final link = io.Link(to);
    try {
      await link.create(t, recursive: true);
    } on io.FileSystemException {
      await link.delete();
      await link.create(t, recursive: true);
    }
    return Link._(to);
  }

  @override
  Future<Link> move(String to) async {
    await _checkSource(_path, to, io.FileSystemEntityType.link);
    await _ensureParent(to);
    try {
      await io.Link(_path).rename(to);
    } on io.FileSystemException catch (e) {
      if (!_isExdev(e)) rethrow;
      final t = await target();
      await io.Link(to).create(t, recursive: true);
      await io.Link(_path).delete();
    }
    return Link._(to);
  }
}

/// Future mirrors (rule 6). The extension name is import-only; never reference it. Sync members come back as Futures.
/// [Reader]/[Writer]/[Closeable] members come from `Future<Reader>`.
extension FileFuture on Future<File> {
  Future<String> path() async => (await this).path();
  Future<String> name() async => (await this).name();
  Future<Dir> parent() async => (await this).parent();
  Future<bool> exists() async => (await this).exists();
  Future<void> delete() async => (await this).delete();
  Future<File> copy(String to) async => (await this).copy(to);
  Future<File> move(String to) async => (await this).move(to);
  Future<File> write(Object data) async => (await this).write(data);
  Future<File> append(Object data) async => (await this).append(data);
  Future<int> size() async => (await this).size();
}

/// Future mirrors for [Dir].
extension DirFuture on Future<Dir> {
  Future<String> path() async => (await this).path();
  Future<String> name() async => (await this).name();
  Future<Dir> parent() async => (await this).parent();
  Future<bool> exists() async => (await this).exists();
  Future<void> delete() async => (await this).delete();
  Future<Dir> copy(String to) async => (await this).copy(to);
  Future<Dir> move(String to) async => (await this).move(to);
  Future<File> file(String name) async => (await this).file(name);
  Future<Dir> dir(String name) async => (await this).dir(name);
  Future<List<Entry>> list({bool recursive = false}) async =>
      (await this).list(recursive: recursive);
  Future<Dir> create() async => (await this).create();
}

/// Future mirrors for [Link].
extension LinkFuture on Future<Link> {
  Future<String> path() async => (await this).path();
  Future<String> name() async => (await this).name();
  Future<Dir> parent() async => (await this).parent();
  Future<bool> exists() async => (await this).exists();
  Future<void> delete() async => (await this).delete();
  Future<Link> copy(String to) async => (await this).copy(to);
  Future<Link> move(String to) async => (await this).move(to);
  Future<String> target() async => (await this).target();
  Future<Entry?> resolve() async => (await this).resolve();
  Future<Link> create(String target) async =>
      (await this).create(target);
}

Future<void> _ensureParent(String path) async {
  final dir = p.dirname(path);
  if (dir.isNotEmpty && dir != '.') {
    await io.Directory(dir).create(recursive: true);
  }
}

/// True only for cross-device renames.
bool _isExdev(io.FileSystemException e) => e.osError?.errorCode == 18;

/// Replace a dest symlink with nothing, so a file/dir copy replaces the
/// link instead of following it to a target outside the tree.
Future<void> _removeDestLink(String to) async {
  try {
    final t = await io.FileSystemEntity.type(to, followLinks: false);
    if (t == io.FileSystemEntityType.link) {
      await io.Link(to).delete();
    }
  } catch (_) {}
}

/// Throw before creating anything when the source is missing or of the wrong
/// kind, and reject a destination inside (or equal to) the source. Must run
/// before [_ensureParent] so a missing source never leaves an empty
/// destination. Symlinks are resolved so `link->real` + `to=real/sub` is
/// still a self-copy.
Future<void> _checkSource(
  String from,
  String to, [
  io.FileSystemEntityType? expected,
]) async {
  final t = await io.FileSystemEntity.type(from, followLinks: false);
  if (t == io.FileSystemEntityType.notFound) {
    throw io.PathNotFoundException(from, const io.OSError());
  }
  if (expected != null && t != expected) {
    throw io.FileSystemException(
      'source is $t, not $expected',
      from,
    );
  }
  final nf = p.normalize(p.absolute(from));
  final nt = p.normalize(p.absolute(to));
  if (p.equals(nf, nt) || p.isWithin(nf, nt)) {
    throw ArgumentError.value(
      to,
      'to',
      'destination must not be inside the source ($from)',
    );
  }
  // Resolve symlinks for a real self-copy check.
  try {
    final realFrom = await io.File(nf).resolveSymbolicLinks();
    String realTo;
    try {
      // Dest may not exist: resolve its parent.
      final parent = p.dirname(nt);
      final realParent = await io.Directory(parent).resolveSymbolicLinks();
      realTo = p.join(realParent, p.basename(nt));
    } catch (_) {
      realTo = nt;
    }
    if (p.equals(realFrom, realTo) || p.isWithin(realFrom, realTo)) {
      throw ArgumentError.value(
        to,
        'to',
        'destination must not be inside the source ($from)',
      );
    }
  } catch (e) {
    if (e is ArgumentError) rethrow;
  }
}

/// chmod on POSIX, best-effort elsewhere (Windows has no POSIX modes).
Future<void> _chmod(String path, int mode) async {
  if (io.Platform.isWindows) return;
  try {
    final perms = mode & 0xFFF;
    final r = await io.Process.run(
      'chmod',
      [perms.toRadixString(8), path],
    );
    // Ignore launcher/exit failures: best-effort.
    if (r.exitCode != 0) return;
  } catch (_) {}
}

/// Keep the source file's mtime and mode on a copy.
Future<void> _preserveFileMeta(String from, String to) async {
  try {
    final st = await io.FileStat.stat(from);
    try {
      await io.File(to).setLastModified(st.modified);
    } catch (_) {}
    await _chmod(to, st.mode & 0xFFF);
  } catch (_) {}
}

/// Set a folder's mtime (dart:io has no Directory.setLastModified):
/// `touch` on POSIX, no-op on Windows. Best-effort.
Future<void> _setDirMtime(String path, DateTime mtime) async {
  if (io.Platform.isWindows) return;
  try {
    final List<String> args;
    if (io.Platform.isMacOS) {
      String two(int n) => n.toString().padLeft(2, '0');
      final t =
          '${mtime.year.toString().padLeft(4, '0')}${two(mtime.month)}${two(mtime.day)}${two(mtime.hour)}${two(mtime.minute)}.${two(mtime.second)}';
      args = ['-t', t, path];
    } else {
      args = [
        '-d',
        '@${mtime.millisecondsSinceEpoch ~/ 1000}',
        path,
      ];
    }
    await io.Process.run('touch', args);
  } catch (_) {}
}

Future<bool> _missing(io.FileSystemException e) async {
  // Already handled PathNotFoundException; other "not found" OS errors
  // (e.g. delete on a missing dir on some platforms) are also a no-op.
  return e.osError?.errorCode == 2;
}

/// The string as given, without trailing separators (the root keeps one).
String _strip(String path) {
  if (path.length > 1) {
    var end = path.length;
    while (end > 1 &&
        (path.codeUnitAt(end - 1) == 0x2f ||
            path.codeUnitAt(end - 1) == 0x5c)) {
      end--;
    }
    if (end != path.length) return path.substring(0, end);
  }
  return path;
}

Future<void> _copyDir(String from, String to) async {
  await io.Directory(to).create(recursive: true);
  await for (final e in io.Directory(from).list(
    recursive: false,
    followLinks: false,
  )) {
    final name = p.basename(e.path);
    final dest = p.join(to, name);
    final t = await io.FileSystemEntity.type(e.path, followLinks: false);
    if (t == io.FileSystemEntityType.link) {
      final target = await io.Link(e.path).target();
      await io.Link(dest).create(target, recursive: true);
    } else if (t == io.FileSystemEntityType.directory) {
      await _copyDir(e.path, dest);
    } else if (t == io.FileSystemEntityType.file) {
      await io.File(e.path).copy(dest);
      await _preserveFileMeta(e.path, dest);
    }
  }
  // Folders keep modes AND mtimes: set the folder mtime after its contents
  // are copied (writing children bumps it), and chmod to the source mode.
  try {
    final st = await io.FileStat.stat(from);
    await _setDirMtime(to, st.modified);
    await _chmod(to, st.mode & 0xFFF);
  } catch (_) {}
}
