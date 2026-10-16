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
/// await (http.get(url) > Fs.dir('out'));   // out/<the server's name>
/// ```
///
/// Public surface is exactly: [Fs], [Entry], [File], [Dir], [Link],
/// [LockedException].
/// - `Fs.entry/file/dir()` inspect or build handles (`entry` is the one
///   call that does I/O, and the way to a [Link]; the other two do none); `Fs.sanitize()` makes
///   an untrusted string a safe file name; `Fs.tempDir()` runs a body with a
///   fresh folder; `Fs.homeDir()` and `Fs.scriptDir()` name the usual places.
/// - [Entry] supports `path` `name` `parent` `exists` `modified` `delete` `copy` `move`
///   (`copy`, `move` and `Dir.list` are [Task]s: `dir.copy(to) & Console.bar('backup')`).
///   `copy`/`move` move an entry with its modes and times; `>` moves content.
/// - [File] supports `write` `append` `size` `touch` `lock` (plus [Reader]/[Writer]).
/// - [Dir] supports `file` `dir` `list` `size` `create` (plus [Writer]:
///   `> Fs.dir('out')` stores a reader under its `origin().name()`).
/// - [Link] supports `target` `resolve`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'core.dart';
export 'core.dart';

import 'src/exit.dart' as exit;
import 'src/format.dart' show Unit;
import 'src/glob.dart';
import 'src/missing.dart';
import 'src/names.dart' as names;
import 'src/posix.dart' as posix;
import 'src/progress.dart' show Run, relay, task;
import 'src/resume.dart' show Folder;
import 'src/tree.dart' as tree;

/// What [File.lock] throws when another holder keeps the lock: tell it
/// from other disk errors by type. A [io.FileSystemException].
final class LockedException extends io.FileSystemException implements ToolkitException {
  /// The lock at [path] is held elsewhere.
  const LockedException(super.message, [super.path]);

  @override
  Object? get cause => null;
}

/// Entry point: inspect the disk or build handles (handles do no I/O).
abstract final class Fs {
  /// What is on disk now: a [File], [Dir], [Link], or null. Never follows
  /// links. The one `Fs.` call that does I/O; `file`/`dir` don't.
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

  /// Run [body] with a fresh folder under the system temp dir, then delete
  /// it (Ctrl-C included) and return what [body] returned. A scope, not a
  /// handle: nothing to forget, and nothing keeps the script alive.
  static Future<T> tempDir<T>(Future<T> Function(Dir dir) body) async {
    final made = await io.Directory.systemTemp.createTemp('tmp-');
    final token = exit.onExit(() async {
      try {
        await made.delete(recursive: true);
      } catch (_) {}
    });
    try {
      return await body(Dir._(made.path));
    } finally {
      exit.offExit(token);
      try {
        await made.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// The user's home folder (`HOME`; `USERPROFILE` on Windows).
  static Dir homeDir() {
    final env = io.Platform.environment;
    final home = io.Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
    if (home == null || home.isEmpty) throw const io.FileSystemException('no home folder (HOME is unset)');
    return Dir._(home);
  }

  /// The folder of the running script (`Platform.script`), so a script keeps
  /// its data next to itself whatever the working directory.
  static Dir scriptDir() => Dir._(p.dirname(io.Platform.script.toFilePath()));

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

  /// The string as given, without trailing separators. A getter, as in
  /// `dart:io`, so `'${dir.path}/x'` builds a path (and `'$dir/x'` too).
  String get path => _path;

  /// The path relative to [dir], always with `/` (`a/b.txt` under `site`,
  /// on Windows too: it becomes manifest keys and URL paths).
  String relative(Dir dir) => p.relative(_path, from: dir._path).replaceAll(r'\', '/');

  /// The last segment.
  String name() => p.basename(_path);

  /// The containing folder. The root's parent is the root.
  Dir parent() => Dir._(p.dirname(_path));

  /// True only when something of this handle's kind is there. A [File] or
  /// [Dir] follows links (a link to a file is a file, as for reading); a
  /// [Link] asks about the link itself.
  Future<bool> exists();

  /// Remove a file, a link (never its target) or a whole folder. A no-op
  /// when nothing is there; another kind throws a [io.FileSystemException]
  /// (`Fs.dir(file).delete()` never silently keeps the file).
  Future<void> delete();

  /// Filesystem copy to [to]: keeps metadata, creates parents, recursive for
  /// folders (links inside as links). A [File] or [Dir] handle on a link
  /// copies what the link points at. Returns a handle of the same type at
  /// [to], as a [Task] that counts the bytes copied when watched
  /// (`& Console.bar('backup')`).
  Task<Entry> copy(String to);

  /// Rename to [to], falling back to copy-then-delete across devices (then
  /// counted like [copy]). A link moves as the link. Returns a handle of
  /// the same type at [to].
  Task<Entry> move(String to);

  /// When the content last changed (links followed). A missing entry
  /// throws [io.PathNotFoundException].
  Future<DateTime> modified() async {
    final st = await io.FileStat.stat(_path);
    if (st.type == io.FileSystemEntityType.notFound) {
      throw io.PathNotFoundException(_path, const io.OSError('No such file or directory', 2));
    }
    return st.modified;
  }

  late final String _key = p.normalize(_path);

  /// Same type and the same normalized path (`a/./b` is `a/b`).
  @override
  bool operator ==(Object other) => other is Entry && other.runtimeType == runtimeType && other._key == _key;

  @override
  int get hashCode => Object.hash(runtimeType, _key);

  /// The path, so `'$dir/x'` and `print(file)` show it.
  @override
  String toString() => _path;
}

/// A file: a [Reader] in 64 KiB chunks, a [Writer] written atomically.
final class File extends Entry with Reader, Writer {
  File._(super.path) : super._();

  @override
  Future<bool> exists() async => await io.FileSystemEntity.type(_path) == io.FileSystemEntityType.file;

  @override
  Future<void> delete() => _delete(_path, io.FileSystemEntityType.file);

  @override
  Task<File> copy(String to) => task((run) async {
    await _checkSource(_path, to, io.FileSystemEntityType.file);
    await _ensureParent(to);
    await _removeDestLink(to);
    // `File.copy` and the stat behind preserveFileMeta follow a source link.
    await tree.copyFile(_path, to, onBytes: await _counter(run, () => io.File(_path).length()));
    await tree.preserveFileMeta(_path, to);
    return File._(to);
  });

  @override
  Task<File> move(String to) => task((run) async {
    if (await _checkSource(_path, to, io.FileSystemEntityType.file) == io.FileSystemEntityType.link) {
      await Link._(_path).move(to);
      return File._(to);
    }
    await _ensureParent(to);
    await _removeDestLink(to);
    try {
      await io.File(_path).rename(to);
    } on io.FileSystemException catch (e) {
      // Rename across devices; anything else (missing source, occupied
      // destination, permissions) must surface.
      if (!posix.isCrossDevice(e)) rethrow;
      await tree.copyFile(_path, to, onBytes: await _counter(run, () => io.File(_path).length()));
      await tree.preserveFileMeta(_path, to);
      await io.File(_path).delete();
    }
    return File._(to);
  });

  /// Replace the content with UTF-8 [text], atomically; writes to one path
  /// land in call order. Creates missing parents. Returns this file. Bytes go through the one [Writer] path:
  /// `await (Reader.of(bytes) > file)`.
  Future<File> write(String text) async {
    await _inOrder(() async {
      await _ensureParent(_path);
      await _atomicWrite(Stream.value(utf8.encode(text)));
    });
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

  /// Set the modification time to [time] (now by default), creating an
  /// empty file when none is there, as `touch` does. Follows links. Returns
  /// this, so a download keeps its post's date: `await file.touch(posted)`.
  Future<File> touch([DateTime? time]) async {
    final f = io.File(_path);
    try {
      await f.setLastModified(time ?? DateTime.now());
    } on io.FileSystemException catch (e) {
      if (e is! io.PathNotFoundException && !_missing(e)) rethrow;
      await _ensureParent(_path);
      await f.create();
      await f.setLastModified(time ?? DateTime.now());
    }
    return this;
  }

  /// Run [body] holding an exclusive OS lock on this file (created when
  /// missing), then release it, and return what [body] returned: one cron
  /// run at a time. Another holder fails at once with
  /// [LockedException] `locked by another process`, or, with [timeout],
  /// after retrying that long. The OS drops the lock if the process dies;
  /// the file itself stays (deleting it would race the next run).
  Future<T> lock<T>(Future<T> Function() body, {Duration? timeout}) async {
    // OS locks never conflict within one process, so holders here are
    // tracked too: two lock() bodies in one script exclude each other, in
    // call order (claimed before the first await).
    final key = p.canonicalize(_path);
    final until = timeout == null ? null : DateTime.now().add(timeout);
    Future<void> retry(String holder) async {
      if (until == null || DateTime.now().isAfter(until)) {
        throw LockedException('locked by $holder', _path);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    while (!_locked.add(key)) {
      await retry('this process');
    }
    try {
      await _ensureParent(_path);
      final raf = await io.File(_path).open(mode: io.FileMode.append);
      try {
        while (true) {
          try {
            await raf.lock(io.FileLock.exclusive);
            break;
          } on io.FileSystemException {
            await retry('another process');
          }
        }
        try {
          return await body();
        } finally {
          await raf.unlock();
        }
      } finally {
        await raf.close();
      }
    } finally {
      _locked.remove(key);
    }
  }

  /// Paths this process holds a [lock] on.
  static final _locked = <String>{};

  @override
  Origin origin() => Origin(path: _path, name: p.basename(_path));

  @override
  Stream<List<int>> stream() => io.File(_path).openRead();

  /// The bytes; [or] is returned when the file does not exist (every other
  /// failure still throws).
  @override
  Future<List<int>> bytes({List<int>? or}) => orMissing(this, or, (_) => io.File(_path).readAsBytes());

  /// UTF-8 text (malformed bytes replaced); [or] is returned when the file
  /// does not exist (every other failure still throws).
  @override
  Future<String> text({String? or}) => orMissing(this, or, (_) => super.text());

  @override
  Future<void> consume(Stream<List<int>> input) => _inOrder(() async {
    await _ensureParent(_path);
    await _atomicWrite(input);
  });

  /// Runs [body] after every earlier write to this path in this process,
  /// claimed at call time, so unawaited writes land in call order.
  Future<void> _inOrder(Future<void> Function() body) {
    final key = p.canonicalize(_path);
    final done = (_writes[key] ?? Future<void>.value()).then((_) => body());
    final tail = done.catchError((_) {});
    _writes[key] = tail;
    tail.whenComplete(() {
      if (identical(_writes[key], tail)) _writes.remove(key);
    });
    return done;
  }

  /// The last pending write per canonical path.
  static final _writes = <String, Future<void>>{};

  Future<void> _atomicWrite(Stream<List<int>> input) async {
    // Ctrl-C fails a write in flight (the temp goes, `finally` runs); one
    // begun after it (saving state) runs.
    input = exit.guard(input);
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
    var tmp = tree.tmpPath(target);
    var tmpFile = io.File(tmp);
    for (var attempt = 0; ; attempt++) {
      try {
        await tmpFile.create(exclusive: true);
        break;
      } on io.PathExistsException {
        if (attempt >= 4) rethrow;
        tmp = tree.tmpPath(target);
        tmpFile = io.File(tmp);
      } on io.FileSystemException catch (e) {
        // A read-only or missing folder: say which file, not the hidden temp.
        final os = e.osError ?? const io.OSError();
        throw switch (e) {
          io.PathAccessException() => io.PathAccessException(target, os, e.message),
          io.PathNotFoundException() => io.PathNotFoundException(target, os, e.message),
          _ => io.FileSystemException(e.message, target, e.osError),
        };
      }
    }
    // A signal that ends the process skips `finally`: the exit hook
    // removes the temp file.
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
      // Small chunks (a network body) are batched to 64 KiB per write, and
      // the bytes are fsynced before the rename: a crash right after it
      // must not leave the new name pointing at empty blocks. (The folder
      // itself cannot be fsynced: `dart:io` cannot open one.)
      final raf = await tmpFile.open(mode: io.FileMode.write);
      try {
        final pending = BytesBuilder(copy: false);
        await for (final chunk in input) {
          pending.add(chunk);
          if (pending.length >= 65536) await raf.writeFrom(pending.takeBytes());
        }
        if (pending.isNotEmpty) await raf.writeFrom(pending.takeBytes());
        await raf.flush();
      } finally {
        await raf.close();
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

/// A folder. As a [Writer] it stores a reader under its `origin().name()`:
/// `await (http.get(u) & bar > Fs.dir('out'))` writes `out/<name>`, and a
/// `resume: true` client skips or resumes it as `> dir.file(name)` does.
final class Dir extends Entry with Writer implements Folder {
  Dir._(super.path) : super._();

  /// A file handle under this folder. No I/O.
  @override
  File file(String name) => File._(p.join(_path, name));

  /// Bytes with no reader have no name: `Reader >` names the file, so
  /// write to [file] when calling this directly.
  @override
  Future<void> consume(Stream<List<int>> input) async =>
      throw ContentException('a stream has no name to store it under in $_path: write to dir.file(name) instead');

  /// A folder handle under this folder. No I/O.
  Dir dir(String name) => Dir._(p.join(_path, name));

  /// Typed entries, sorted by relative path (depth-first). Never descends
  /// through links. Without [match], the children; [match] keeps the
  /// entries whose path relative to this folder matches a glob, and its
  /// shape sets the depth: `*` and `?` stay within one folder, each `/`
  /// goes one level deeper (`'*/*.jpg'` is the jpgs one folder down), and
  /// `**` crosses any number (`'**'` is the whole tree, `'**/*.{jpg,png}'`
  /// every image). A [Task] that counts the entries found
  /// (`& Console.bar('scan')`).
  Task<List<Entry>> list({String? match}) => task((run) => _list(match, run));

  Future<List<Entry>> _list(String? match, Run run) async {
    final pattern = match == null ? null : glob(match);
    // Levels to walk: one per path segment, any number for `**`.
    final depth = match == null ? 1 : (match.contains('**') ? null : '/'.allMatches(match).length + 1);
    final t = await io.FileSystemEntity.type(_path, followLinks: false);
    if (t != io.FileSystemEntityType.directory) {
      throw io.FileSystemException('not a directory', _path);
    }
    // Entries come back as `_path` + separator + relative name: cut the
    // prefix once per entry instead of `p.relative` (a getcwd each time on
    // a relative path; 25x slower than the listing itself).
    final cut = _path.endsWith('/') || _path.endsWith(r'\') ? _path.length : _path.length + 1;
    final found = <(String, Entry)>[];
    // The whole tree in one OS walk, or level by level down to [depth].
    final Stream<io.FileSystemEntity> walk;
    if (depth == null || depth == 1) {
      walk = io.Directory(_path).list(recursive: depth == null, followLinks: false);
    } else {
      walk = () async* {
        var level = [io.Directory(_path)];
        for (var d = 1; d <= depth && level.isNotEmpty; d++) {
          final next = <io.Directory>[];
          for (final dir in level) {
            await for (final e in dir.list(followLinks: false)) {
              if (e is io.Directory && d < depth) next.add(e);
              yield e;
            }
          }
          level = next;
        }
      }();
    }
    await for (final e in walk) {
      final rel = (e.path.startsWith(_path) ? e.path.substring(cut) : p.relative(e.path, from: _path)).replaceAll(
        r'\',
        '/',
      );
      if (pattern != null && !pattern.hasMatch(rel)) continue;
      // With followLinks:false the stream never descends through links,
      // and its runtime type already tells links apart: no extra stat.
      final Entry entry = switch (e) {
        io.Link() => Link._(e.path),
        io.File() => File._(e.path),
        _ => Dir._(e.path),
      };
      found.add((rel.replaceAll('/', '\x00'), entry)); // separators sort lowest: a/b before a-b
      if (run.watched) run.report(found.length, null, Unit.items);
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, e) in found) e];
  }

  /// How many files are under this folder (recursively, links not
  /// followed) and their bytes. In-flight toolkit files are left out:
  /// download partials (`x.part`, `x.part.tag`), atomic-write temps
  /// (`.x.tmp…`) and `Image`/`Video.compress` encodes (`.x.compress`), so
  /// a folder mid-download counts what is finished. A missing folder is
  /// `(files: 0, bytes: 0)`.
  Future<({int files, int bytes})> size() async {
    if (await io.FileSystemEntity.type(_path, followLinks: false) == io.FileSystemEntityType.notFound) {
      return (files: 0, bytes: 0);
    }
    final sizes = <Future<int?>>[];
    await for (final e in io.Directory(_path).list(recursive: true, followLinks: false)) {
      if (e is! io.File) continue;
      final name = p.basename(e.path);
      if (name.endsWith('.part') || name.endsWith('.part.tag') || posix.isTmpName(name) || _isCompressTemp(name)) {
        continue;
      }
      // Lengths in parallel; a file gone since the listing is not counted.
      sizes.add(e.length().then<int?>((n) => n, onError: (Object _) => null));
    }
    var files = 0, bytes = 0;
    for (final n in await Future.wait(sizes)) {
      if (n == null) continue;
      files++;
      bytes += n;
    }
    return (files: files, bytes: bytes);
  }

  /// `mkdir -p`. A no-op when the folder exists. Returns this.
  Future<Dir> create() async {
    await io.Directory(_path).create(recursive: true);
    return this;
  }

  @override
  Future<bool> exists() async => await io.FileSystemEntity.type(_path) == io.FileSystemEntityType.directory;

  @override
  Future<void> delete() => _delete(_path, io.FileSystemEntityType.directory);

  /// With [match] only the entries whose path matches the glob are copied
  /// (read as [list] reads it: `'**/*.dart'`), with the folders above them;
  /// files keep their modes and times, links stay links.
  @override
  Task<Dir> copy(String to, {String? match}) => task((run) async {
    final kind = await _checkSource(_path, to, io.FileSystemEntityType.directory);
    // A handle on a link copies the folder it points at (`cp -P` and the
    // walk below would copy the link itself).
    final from = kind == io.FileSystemEntityType.link ? await io.Directory(_path).resolveSymbolicLinks() : _path;
    await _ensureParent(to);
    await _removeDestLink(to);
    if (match != null) {
      await _copyMatching(from, to, match, run);
      return Dir._(to);
    }
    // One `cp -pPR` keeps modes, times and links with a single fork. It
    // only matches the merge semantics for a fresh destination (into an
    // existing tree `cp` would nest instead), so an existing target, a
    // missing `cp`, or Windows falls back to the in-process loop below.
    // Watched, the copy streams in-process instead, so it can count.
    final onBytes = await _counter(run, () => tree.treeBytes(from));
    if (onBytes == null && await io.FileSystemEntity.type(to, followLinks: false) == io.FileSystemEntityType.notFound) {
      if (await posix.copyTreeWithCp(from, to)) return Dir._(to);
    }
    await tree.copyTree(from, to, onBytes: onBytes);
    return Dir._(to);
  });

  @override
  Task<Dir> move(String to) => task((run) async {
    if (await _checkSource(_path, to, io.FileSystemEntityType.directory) == io.FileSystemEntityType.link) {
      await Link._(_path).move(to);
      return Dir._(to);
    }
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
      await tree.copyTree(_path, to, onBytes: await _counter(run, () => tree.treeBytes(_path)));
      await io.Directory(_path).delete(recursive: true);
    }
    return Dir._(to);
  });
}

/// `Dir.copy(to, match:)`: the entries of [from] that [match] matches, into
/// [to] with the folders above them. A link on the way in [to] is replaced
/// by a folder, and one at a file's path by the file: nothing is written
/// through a link.
Future<void> _copyMatching(String from, String to, String match, Run run) async {
  final cut = from.endsWith('/') || from.endsWith(r'\') ? from.length : from.length + 1;
  final found = await Dir._(from)._list(match, Run());
  // Normalised, so the walk up from a member stops exactly at the root
  // (`dst/`, `a/../dst`): above it, a link is the caller's and stays.
  final root = p.normalize(to);
  final made = <String>{root};
  await io.Directory(root).create();
  Future<void> folder(String dir) async {
    if (!made.add(dir)) return;
    await folder(p.dirname(dir));
    if (await io.FileSystemEntity.isLink(dir)) await io.Link(dir).delete();
    await io.Directory(dir).create();
  }

  final files = <(String, String)>[];
  for (final e in found) {
    final dest = p.join(root, e._path.substring(cut));
    await folder(e is Dir ? dest : p.dirname(dest));
    if (e is Link) {
      await Link._(dest)._create(await io.Link(e._path).target());
    } else if (e is File) {
      files.add((e._path, dest));
    }
  }
  final onBytes = await _counter(run, () async {
    var n = 0;
    for (final (src, _) in files) {
      n += await io.File(src).length();
    }
    return n;
  });
  // A few files at a time: thousands at once would run out of descriptors.
  final next = files.iterator;
  Future<void> lane() async {
    while (next.moveNext()) {
      final (src, dest) = next.current;
      if (await io.FileSystemEntity.isLink(dest)) await io.Link(dest).delete();
      await tree.copyFile(src, dest, onBytes: onBytes);
      await tree.preserveFileMeta(src, dest);
    }
  }

  await Future.wait([for (var i = 0; i < 8; i++) lane()]);
}

/// When [run] is watched, report 0 of the [total] and return what counts
/// each copied chunk; null when nothing watches (the fast OS copy).
Future<void Function(int bytes)?> _counter(Run run, Future<int> Function() total) async {
  if (!run.watched) return null;
  final all = await total();
  var done = 0;
  run.report(0, all, Unit.bytes);
  return (int n) => run.report(done += n, all, Unit.bytes);
}

/// A symlink.
final class Link extends Entry {
  Link._(super.path) : super._();

  /// The stored target string.
  Future<String> target() => io.Link(_path).target();

  /// Follow the chain to what is finally there, or null when broken (a
  /// missing target or a loop); any other failure, such as permission
  /// denied, throws. Returns a handle AT THE TARGET path (not the link's
  /// own path).
  Future<Entry?> resolve() async {
    String resolved;
    try {
      resolved = await io.Link(_path).resolveSymbolicLinks();
    } on io.PathNotFoundException {
      return null;
    } on io.FileSystemException catch (e) {
      if (_broken.contains(e.osError?.errorCode)) return null;
      rethrow;
    }
    final t = await io.FileSystemEntity.type(resolved, followLinks: false);
    return switch (t) {
      io.FileSystemEntityType.file => File._(resolved),
      io.FileSystemEntityType.directory => Dir._(resolved),
      io.FileSystemEntityType.link => Link._(resolved),
      _ => null,
    };
  }

  // Make the link, replacing an existing link or file atomically: a temp
  // link is created next to the target and renamed over it.
  Future<Link> _create(String target) async {
    await _ensureParent(_path);
    final tmp = tree.tmpPath(_path);
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
  Future<void> delete() => _delete(_path, io.FileSystemEntityType.link);

  @override
  Task<Link> copy(String to) => task((_) async {
    await _checkSource(_path, to, io.FileSystemEntityType.link);
    return Link._(to)._create(await target());
  });

  @override
  Task<Link> move(String to) => task((_) async {
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
  });
}

/// Future mirrors (rule 4). The extension name is import-only; never reference it. Sync members come back as Futures.
/// [Reader]/[Writer]/[Closeable] members come from `Future<Reader>`.
extension EntryFuture on Future<Entry> {
  Future<DateTime> modified() async => (await this).modified();
  Future<String> get path async => (await this).path;
  Future<String> relative(Dir dir) async => (await this).relative(dir);
  Future<String> name() async => (await this).name();
  Future<Dir> parent() async => (await this).parent();
  Future<bool> exists() async => (await this).exists();
  Future<void> delete() async => (await this).delete();
  Task<Entry> copy(String to) => task((run) async => (await this).copy(to) & relay(run));
  Task<Entry> move(String to) => task((run) async => (await this).move(to) & relay(run));
}

/// Future mirrors for [File].
extension FileFuture on Future<File> {
  Future<DateTime> modified() async => (await this).modified();
  Future<String> text({String? or}) async => (await this).text(or: or);
  Future<T> lock<T>(Future<T> Function() body, {Duration? timeout}) async => (await this).lock(body, timeout: timeout);
  Future<List<int>> bytes({List<int>? or}) async => (await this).bytes(or: or);
  Future<String> get path async => (await this).path;
  Future<String> relative(Dir dir) async => (await this).relative(dir);
  Future<String> name() async => (await this).name();
  Future<Dir> parent() async => (await this).parent();
  Future<bool> exists() async => (await this).exists();
  Future<void> delete() async => (await this).delete();
  Task<File> copy(String to) => task((run) async => (await this).copy(to) & relay(run));
  Task<File> move(String to) => task((run) async => (await this).move(to) & relay(run));
  Future<File> write(String text) async => (await this).write(text);
  Future<File> append(String text) async => (await this).append(text);
  Future<int> size() async => (await this).size();
  Future<File> touch([DateTime? time]) async => (await this).touch(time);
}

/// Future mirrors for [Dir].
extension DirFuture on Future<Dir> {
  Future<DateTime> modified() async => (await this).modified();
  Future<String> get path async => (await this).path;
  Future<String> relative(Dir dir) async => (await this).relative(dir);
  Future<String> name() async => (await this).name();
  Future<Dir> parent() async => (await this).parent();
  Future<bool> exists() async => (await this).exists();
  Future<void> delete() async => (await this).delete();
  Task<Dir> copy(String to, {String? match}) => task((run) async => (await this).copy(to, match: match) & relay(run));
  Task<Dir> move(String to) => task((run) async => (await this).move(to) & relay(run));
  Future<File> file(String name) async => (await this).file(name);
  Future<Dir> dir(String name) async => (await this).dir(name);
  Task<List<Entry>> list({String? match}) => task((run) async => (await this).list(match: match) & relay(run));
  Future<({int files, int bytes})> size() async => (await this).size();
  Future<Dir> create() async => (await this).create();
}

/// Future mirrors for [Link].
extension LinkFuture on Future<Link> {
  Future<DateTime> modified() async => (await this).modified();
  Future<String> get path async => (await this).path;
  Future<String> relative(Dir dir) async => (await this).relative(dir);
  Future<String> name() async => (await this).name();
  Future<Dir> parent() async => (await this).parent();
  Future<bool> exists() async => (await this).exists();
  Future<void> delete() async => (await this).delete();
  Task<Link> copy(String to) => task((run) async => (await this).copy(to) & relay(run));
  Task<Link> move(String to) => task((run) async => (await this).move(to) & relay(run));
  Future<String> target() async => (await this).target();
  Future<Entry?> resolve() async => (await this).resolve();
}

/// The errors besides not-found that mean a link chain is broken: ENOTDIR
/// and ELOOP (macOS 62, Linux 40). Windows: see docs/PLAN.md W14.
final _broken = io.Platform.isWindows ? const <int>{} : {20, io.Platform.isMacOS ? 62 : 40};

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
/// A delete that fails throws: copying on would write through the link.
Future<void> _removeDestLink(String to) async {
  if (await io.FileSystemEntity.type(to, followLinks: false) == io.FileSystemEntityType.link) {
    await io.Link(to).delete();
  }
}

/// Throw before creating anything when the source is missing or of the wrong
/// kind, and reject a destination inside (or equal to) the source. Must run
/// before [_ensureParent] so a missing source never leaves an empty
/// destination. A file or folder [expected] is judged through links (a link
/// to a file is a file); a link is judged as itself. Symlinks are resolved so
/// `link->real` + `to=real/sub` is still a self-copy. Returns what is at
/// [from] itself (`link` for a link to the expected kind).
Future<io.FileSystemEntityType> _checkSource(String from, String to, io.FileSystemEntityType expected) async {
  final own = await io.FileSystemEntity.type(from, followLinks: false);
  final t = own == io.FileSystemEntityType.link && expected != io.FileSystemEntityType.link
      ? await io.FileSystemEntity.type(from)
      : own;
  if (t == io.FileSystemEntityType.notFound) await _notFound(from);
  if (t != expected) throw io.FileSystemException('source is $t, not $expected', from);
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
  return own;
}

/// Throw the OS's own "not found" for [path] (its errno and message).
Future<Never> _notFound(String path) async {
  io.OSError? os;
  try {
    await io.File(path).resolveSymbolicLinks();
  } on io.FileSystemException catch (e) {
    os = e.osError;
  }
  throw io.PathNotFoundException(path, os ?? io.OSError('No such file or directory', 2));
}

/// Remove what is at [path] when it is a [kind] (a [File]/[Dir] handle on a
/// link to its kind, or a broken link, removes the link and never the
/// target). Nothing there is a no-op; another kind throws.
Future<void> _delete(String path, io.FileSystemEntityType kind) async {
  const link = io.FileSystemEntityType.link, missing = io.FileSystemEntityType.notFound;
  try {
    final own = await io.FileSystemEntity.type(path, followLinks: false);
    if (own == missing) return;
    final t = own == link && kind != link ? await io.FileSystemEntity.type(path) : own;
    if (t != kind && !(own == link && t == missing)) {
      throw io.FileSystemException('is a $t, not a $kind', path);
    }
    if (own == link) {
      await io.Link(path).delete();
    } else if (kind == io.FileSystemEntityType.directory) {
      await io.Directory(path).delete(recursive: true);
    } else {
      await io.File(path).delete();
    }
  } on io.FileSystemException catch (e) {
    // Gone in between: still a no-op.
    if (e is! io.PathNotFoundException && !_missing(e)) rethrow;
  }
}

/// A "not found" OS error: `ENOENT` (2) on POSIX; `ERROR_FILE_NOT_FOUND` (2)
/// or `ERROR_PATH_NOT_FOUND` (3) on Windows.
bool _missing(io.FileSystemException e) {
  final code = e.osError?.errorCode;
  return code == 2 || (code == 3 && !posix.isPosix);
}

final _driveRoot = RegExp(r'^[A-Za-z]:[\\/]?$');

/// The string as given, without trailing separators (the root keeps one).
/// Windows drive roots (`C:\`, `C:/`) keep their separator.
String _strip(String path) {
  if (path.length <= 3 && _driveRoot.hasMatch(path)) return path;
  if (path.length > 1) {
    var end = path.length;
    while (end > 1 && (path.codeUnitAt(end - 1) == 0x2f || path.codeUnitAt(end - 1) == 0x5c)) {
      end--;
    }
    if (end != path.length) return path.substring(0, end);
  }
  return path;
}

/// An `Image`/`Video.compress` encode in flight (`.photo.jpg.compress`).
bool _isCompressTemp(String name) => name.startsWith('.') && name.endsWith('.compress');
