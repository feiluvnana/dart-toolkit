/// Typed file-system handles. Thin facade over `dart:io` and `package:path`.
///
/// ```dart
/// switch (await Fs.entry(args.first)) {
///   case File file: print('file, ${await file.size()} bytes');
///   case Dir dir: print('folder of ${(await dir.list()).length}');
///   case Link link: print('link → ${await link.target()}');
///   case null: print('nothing there');
/// }
/// await (Reader.of(bytes) > Fs.file('a.bin'));
/// ```
///
/// Public surface is exactly: [Fs], [Entry], [File], [Dir], [Link].
/// - `Fs.entry/file/dir/link()` inspect or build handles (`entry` is the
///   one call that does I/O; the other three do none); `Fs.sanitize()` makes
///   an untrusted string a safe file name.
/// - [Entry] supports `path` `name` `parent` `exists` `delete` `copy` `move`.
/// - [File] supports `write` `append` `size` (plus [Reader]/[Writer]).
/// - [Dir] supports `file` `dir` `list` `create`.
/// - [Link] supports `target` `resolve` `create`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:path/path.dart' as p;

import 'core.dart';
export 'core.dart';

import 'src/exit.dart' as exit;
import 'src/names.dart' as names;
import 'src/posix.dart' as posix;
import 'src/tree.dart' as tree;

/// Entry point: inspect the disk or build handles (handles do no I/O).
abstract final class Fs {
  /// What is on disk now: a [File], [Dir], [Link], or null. Never follows
  /// links. The one `Fs.` call that does I/O; `file`/`dir`/`link` don't.
  static Future<Entry?> entry(String path) async {
    // Strip first: `ln/` makes the OS follow the link to its folder.
    path = _strip(path);
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

  /// [name] (a scraped title, a header value) as one file name that is safe
  /// on every OS: `/`, `\\`, `:*?"<>|` and controls become `_`, trailing dots
  /// and spaces go, `CON`-style device names and a leading `.` or `-` get a
  /// `_` prefix, at most 255 bytes; `'_'` when nothing is left. It never
  /// leaves the folder: `dir.file(Fs.sanitize('../../etc/x'))` stays in `dir`.
  static String sanitize(String name) {
    final s = names.safeName(name);
    return s.isEmpty ? '_' : s;
  }
}

/// A path on disk: a [File], [Dir], or [Link].
sealed class Entry {
  Entry._(String path) : _path = _strip(path);

  final String _path;

  /// The string as given, without trailing separators; with [from], the
  /// path relative to that folder, always with `/` (`a/b.txt` under `site`,
  /// on Windows too: it becomes manifest keys and URL paths).
  String path({Dir? from}) => from == null ? _path : p.relative(_path, from: from._path).replaceAll(r'\', '/');

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
  bool operator ==(Object other) => other is Entry && other.runtimeType == runtimeType && other._path == _path;

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
      final t = await io.FileSystemEntity.type(_path, followLinks: false);
      if (t == io.FileSystemEntityType.notFound) return;
      if (t != io.FileSystemEntityType.file) return;
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
    await tree.preserveFileMeta(_path, to);
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
      // Rename across devices; anything else (missing source, occupied
      // destination, permissions) must surface.
      if (!posix.isCrossDevice(e)) rethrow;
      await io.File(_path).copy(to);
      await tree.preserveFileMeta(_path, to);
      await io.File(_path).delete();
    }
    return File._(to);
  }

  /// Replace the content with UTF-8 [text], atomically. Creates missing
  /// parents. Returns this file. Bytes go through the one [Writer] path:
  /// `await (Reader.of(bytes) > file)`.
  Future<File> write(String text) async {
    await _ensureParent(_path);
    await _atomicWrite(Stream.value(utf8.encode(text)));
    return this;
  }

  /// Add [text] to the end with OS append mode (`O_APPEND`) under an
  /// exclusive lock: O(len(data)), so concurrent appends never lose data
  /// and never replace open inodes. Creates missing parents. Returns this.
  Future<File> append(String text) async {
    await _ensureParent(_path);
    // Serialised process-wide first (see [_appendMutex]), then one
    // open/seek/write under the OS lock.
    await _appendMutex.run(() async {
      final raf = await io.File(_path).open(mode: io.FileMode.append);
      try {
        await raf.lock(io.FileLock.exclusive);
        try {
          // The file offset is captured per open, so seek to the end
          // inside the lock: concurrent opens would otherwise all write
          // at the same stale offset.
          await raf.setPosition(await raf.length());
          await raf.writeString(text);
          await raf.flush();
        } finally {
          await raf.unlock();
        }
      } finally {
        await raf.close();
      }
    });
    return this;
  }

  /// Size in bytes.
  Future<int> size() => io.File(_path).length();

  @override
  Origin origin() => Origin(path: _path, name: p.basename(_path));

  @override
  Stream<List<int>> stream() => io.File(_path).openRead();

  @override
  Future<List<int>> bytes() => io.File(_path).readAsBytes();

  @override
  Future<void> consume(Stream<List<int>> input) async {
    await _ensureParent(_path);
    await _atomicWrite(input);
  }

  Future<void> _atomicWrite(Stream<List<int>> input) async {
    // Writes go through symlinks to their real target: resolve first so
    // a handle pointing at a link updates the target instead of replacing
    // the link with a regular file. Broken links fall back to the handle
    // path (rename will replace the link with a file).
    // Note: rename breaks hardlinks (the target gets a new inode; other
    // links keep the old content).
    var target = _path;
    try {
      final t = await io.FileSystemEntity.type(_path, followLinks: false);
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
    // Unique temp sibling (`p.join`, so Windows never mixes separators),
    // created exclusively (O_EXCL) so a collision retries with a fresh name
    // instead of clobbering.
    var tmp = posix.tmpPath(target);
    var tmpFile = io.File(tmp);
    for (var attempt = 0; ; attempt++) {
      try {
        await tmpFile.create(exclusive: true);
        break;
      } on io.FileSystemException {
        if (attempt >= 4) rethrow;
        tmp = posix.tmpPath(target);
        tmpFile = io.File(tmp);
      }
    }
    // An interrupt skips `finally`: the exit hook removes the temp file.
    final token = exit.onExit(() async {
      try {
        await tmpFile.delete();
      } catch (_) {}
    });
    try {
      // chmod the tmp before any byte lands in it (a 0600 secret must never
      // sit in a 0644 temp), and only when the fresh mode differs from the
      // old one: under the same umask that is almost never, so overwrites
      // skip the fork.
      if (oldMode != 0) {
        var tmpMode = 0;
        try {
          tmpMode = (await io.FileStat.stat(tmp)).mode & 0xFFF;
        } catch (_) {}
        if (tmpMode != oldMode) await posix.chmod(tmp, oldMode);
      }
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
      await _renameOver(tmpFile, target);
    } catch (_) {
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      rethrow;
    } finally {
      exit.offExit(token);
    }
  }
}

/// A folder.
final class Dir extends Entry {
  Dir._(super.path) : super._();

  /// A file handle under this folder. No I/O.
  File file(String name) => File._(p.join(_path, name));

  /// A folder handle under this folder. No I/O.
  Dir dir(String name) => Dir._(p.join(_path, name));

  /// Typed children, sorted by relative path (depth-first when [recursive]).
  /// Never descends through links.
  Future<List<Entry>> list({bool recursive = false}) async {
    final t = await io.FileSystemEntity.type(_path, followLinks: false);
    if (t != io.FileSystemEntityType.directory) {
      throw io.FileSystemException('not a directory', _path);
    }
    final out = <Entry>[];
    await for (final e in io.Directory(_path).list(recursive: recursive, followLinks: false)) {
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
    posix.sortByRelative(out, (e) => e.path(), _path);
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
      final t = await io.FileSystemEntity.type(_path, followLinks: false);
      if (t == io.FileSystemEntityType.notFound) return;
      if (t != io.FileSystemEntityType.directory) return;
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
    // One `cp -pPR` keeps modes, times and links with a single fork. It
    // only matches the merge semantics for a fresh destination (into an
    // existing tree `cp` would nest instead), so an existing target, a
    // missing `cp`, or Windows falls back to the in-process loop below.
    if (await io.FileSystemEntity.type(to, followLinks: false) == io.FileSystemEntityType.notFound) {
      if (await posix.copyTreeWithCp(_path, to)) return Dir._(to);
    }
    await tree.copyTree(_path, to);
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
      // Only a cross-device move falls back to copy-then-delete. Anything
      // else (e.g. moving into a non-empty folder, permissions) must
      // rethrow instead of silently merging/overwriting and deleting the
      // source.
      if (!posix.isCrossDevice(e)) rethrow;
      final destType = await io.FileSystemEntity.type(to, followLinks: false);
      if (destType != io.FileSystemEntityType.notFound) {
        throw io.FileSystemException('Destination already exists', to);
      }
      await tree.copyTree(_path, to);
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
    final t = await io.FileSystemEntity.type(resolved, followLinks: false);
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
    final tmp = posix.tmpPath(_path);
    final tmpLink = io.Link(tmp);
    await tmpLink.create(target, recursive: true);
    try {
      try {
        await tmpLink.rename(_path);
      } on io.FileSystemException {
        // POSIX rename replaces a link or file atomically. On platforms
        // where rename over an existing file fails, remove the destination
        // (link only: never a folder) and retry once.
        final dt = await io.FileSystemEntity.type(_path, followLinks: false);
        if (dt == io.FileSystemEntityType.directory) {
          await tmpLink.delete();
          throw io.FileSystemException('cannot replace directory with link', _path);
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
      final t = await io.FileSystemEntity.type(_path, followLinks: false);
      if (t == io.FileSystemEntityType.notFound) return;
      if (t != io.FileSystemEntityType.link) return;
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
    return Link._(to).create(await target());
  }

  @override
  Future<Link> move(String to) async {
    await _checkSource(_path, to, io.FileSystemEntityType.link);
    await _ensureParent(to);
    try {
      await io.Link(_path).rename(to);
    } on io.FileSystemException catch (e) {
      if (!posix.isCrossDevice(e)) rethrow;
      final t = await target();
      await io.Link(to).create(t, recursive: true);
      await io.Link(_path).delete();
    }
    return Link._(to);
  }
}

/// Future mirrors (rule 4). The extension name is import-only; never reference it. Sync members come back as Futures.
/// [Reader]/[Writer]/[Closeable] members come from `Future<Reader>`.
extension EntryFuture on Future<Entry> {
  Future<String> path({Dir? from}) async => (await this).path(from: from);
  Future<String> name() async => (await this).name();
  Future<Dir> parent() async => (await this).parent();
  Future<bool> exists() async => (await this).exists();
  Future<void> delete() async => (await this).delete();
  Future<Entry> copy(String to) async => (await this).copy(to);
  Future<Entry> move(String to) async => (await this).move(to);
}

/// Future mirrors for [File].
extension FileFuture on Future<File> {
  Future<String> path({Dir? from}) async => (await this).path(from: from);
  Future<String> name() async => (await this).name();
  Future<Dir> parent() async => (await this).parent();
  Future<bool> exists() async => (await this).exists();
  Future<void> delete() async => (await this).delete();
  Future<File> copy(String to) async => (await this).copy(to);
  Future<File> move(String to) async => (await this).move(to);
  Future<File> write(String text) async => (await this).write(text);
  Future<File> append(String text) async => (await this).append(text);
  Future<int> size() async => (await this).size();
}

/// Future mirrors for [Dir].
extension DirFuture on Future<Dir> {
  Future<String> path({Dir? from}) async => (await this).path(from: from);
  Future<String> name() async => (await this).name();
  Future<Dir> parent() async => (await this).parent();
  Future<bool> exists() async => (await this).exists();
  Future<void> delete() async => (await this).delete();
  Future<Dir> copy(String to) async => (await this).copy(to);
  Future<Dir> move(String to) async => (await this).move(to);
  Future<File> file(String name) async => (await this).file(name);
  Future<Dir> dir(String name) async => (await this).dir(name);
  Future<List<Entry>> list({bool recursive = false}) async => (await this).list(recursive: recursive);
  Future<Dir> create() async => (await this).create();
}

/// Future mirrors for [Link].
extension LinkFuture on Future<Link> {
  Future<String> path({Dir? from}) async => (await this).path(from: from);
  Future<String> name() async => (await this).name();
  Future<Dir> parent() async => (await this).parent();
  Future<bool> exists() async => (await this).exists();
  Future<void> delete() async => (await this).delete();
  Future<Link> copy(String to) async => (await this).copy(to);
  Future<Link> move(String to) async => (await this).move(to);
  Future<String> target() async => (await this).target();
  Future<Entry?> resolve() async => (await this).resolve();
  Future<Link> create(String target) async => (await this).create(target);
}

Future<void> _ensureParent(String path) async {
  final dir = p.dirname(path);
  if (dir.isNotEmpty && dir != '.') {
    await io.Directory(dir).create(recursive: true);
  }
}

/// Process-wide FIFO mutex serialising appends. `dart:io` file locks are
/// `fcntl` locks, which never conflict between opens of one process, so
/// the OS lock alone cannot stop same-process appends racing on a stale
/// file offset. The mutex serialises this process; the OS
/// lock still excludes other processes.
final _appendMutex = _Mutex();

final class _Mutex {
  Future<void> _tail = Future.value();

  Future<void> run(Future<void> Function() work) {
    final next = Completer<void>();
    final prev = _tail;
    _tail = next.future;
    return prev.then((_) => work()).whenComplete(next.complete);
  }
}

/// Rename the temp file over [target]. Atomic on POSIX; on Windows a target
/// held open elsewhere (an editor, antivirus, the indexer) can fail with a
/// sharing violation, so retry briefly (3 attempts, 50 ms apart) there.
Future<void> _renameOver(io.File tmp, String target) async {
  try {
    await tmp.rename(target);
    return;
  } on io.FileSystemException catch (first) {
    if (posix.isPosix) rethrow;
    var last = first;
    for (var i = 0; i < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      try {
        await tmp.rename(target);
        return;
      } on io.FileSystemException catch (e) {
        last = e;
      }
    }
    throw last;
  }
}

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
Future<void> _checkSource(String from, String to, [io.FileSystemEntityType? expected]) async {
  final t = await io.FileSystemEntity.type(from, followLinks: false);
  if (t == io.FileSystemEntityType.notFound) {
    throw io.PathNotFoundException(from, const io.OSError());
  }
  if (expected != null && t != expected) {
    throw io.FileSystemException('source is $t, not $expected', from);
  }
  final nf = p.normalize(p.absolute(from));
  final nt = p.normalize(p.absolute(to));
  if (p.equals(nf, nt) || p.isWithin(nf, nt)) {
    throw ArgumentError.value(to, 'to', 'destination must not be inside the source ($from)');
  }
  // Resolve symlinks for a real self-copy check.
  try {
    // A link has no inside: judge it by where it sits, not what it points at.
    final realFrom = expected == io.FileSystemEntityType.link
        ? p.join(await io.Directory(p.dirname(nf)).resolveSymbolicLinks(), p.basename(nf))
        : await io.File(nf).resolveSymbolicLinks();
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
      throw ArgumentError.value(to, 'to', 'destination must not be inside the source ($from)');
    }
  } catch (e) {
    if (e is ArgumentError) rethrow;
  }
}

Future<bool> _missing(io.FileSystemException e) async {
  // Already handled PathNotFoundException; other "not found" OS errors
  // (e.g. delete on a missing dir on some platforms) are also a no-op.
  return e.osError?.errorCode == 2;
}

/// The string as given, without trailing separators (the root keeps one).
/// Windows drive roots (`C:\`, `C:/`) keep their separator.
String _strip(String path) {
  if (RegExp(r'^[A-Za-z]:[\\/]?$').hasMatch(path)) return path;
  if (path.length > 1) {
    var end = path.length;
    while (end > 1 && (path.codeUnitAt(end - 1) == 0x2f || path.codeUnitAt(end - 1) == 0x5c)) {
      end--;
    }
    if (end != path.length) return path.substring(0, end);
  }
  return path;
}
