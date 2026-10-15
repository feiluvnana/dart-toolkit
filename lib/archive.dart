/// Archives and gzip, in pure Dart.
///
/// | format | archive | unarchive |
/// |---|---|---|
/// | zip | ✓ (AES-256 with `password:`) | ✓ (AES, legacy ZipCrypto) |
/// | tar, tgz | ✓ (streamed) | ✓ (streamed; `.tar.xz` too) |
/// | 7z | ✓ (Deflate; AES-256 hides names) | ✓ (LZMA, LZMA2, PPMd, Deflate, BCJ, AES) |
/// | RAR4, RAR5 | — (the compressor is proprietary) | ✓ (solid, filters, PPMd, AES) |
///
/// Zip, 7z and RAR stay in memory (their directory or solid stream needs
/// the whole archive); tar and tgz stream one member at a time.
///
/// ```dart
/// await (Archive.archive(['site', 'README.md']) > Fs.file('site.zip'));        // like zip -r
/// await (Archive.archive(['.'], dir: 'site', format: .tgz) > Fs.file('site.tgz')); // the contents, streamed
/// await (Archive.archive(['docs'], format: .sevenZip, password: pw) > Fs.file('docs.7z'));
/// await (http.get(url) > Archive.unarchive('vendor', password: pw)); // any format above
/// await (http.get(url) | Archive.gunzip() > Fs.file('dump.sql'));    // a truncated stream fails
/// ```
///
/// Public surface is exactly: [Archive], [ArchiveFormat].
/// - `Archive.archive()` is a [Reader] of the archive, `unarchive()` a [Writer].
/// - `Archive.gzip()`/`gunzip()` are streaming [Pipe]s.
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
import 'src/posix.dart' as posix;
import 'src/rar.dart' as rarlib;
import 'src/sevenzip.dart' as sevenzip;
import 'src/tree.dart' as tree;
import 'src/xz.dart' as xz;
import 'src/zip.dart' as zip;

/// Formats [Archive.archive] writes. [Archive.unarchive] reads these and
/// RAR (the magic bytes decide); RAR is read-only, its compressor being
/// proprietary.
enum ArchiveFormat {
  /// Deflate; WinZip AES-256 with a password. In memory, up to 4 GiB.
  zip,

  /// Plain tar, streamed.
  tar,

  /// Gzipped tar, streamed: the format for big trees.
  tgz,

  /// 7z (deflate; AES-256 with the names hidden, with a password). In memory.
  sevenZip,
}

/// Entry point: archive files and folders, unarchive a stream, gzip on
/// the way.
abstract final class Archive {
  /// A [Reader] of an archive holding [paths] (files and folders, each with
  /// its whole tree), named relative to [dir] (default: the working
  /// folder, as `Shell.run(dir:)`), like `zip -r out.zip site README.md`. `['.']` is the contents
  /// of [dir]: `Archive.archive(['.'], dir: 'site')`. Built when read.
  ///
  /// With [password] the files are encrypted: zip as WinZip AES-256 (what
  /// every modern tool reads), 7z as AES-256 with the names hidden too. Tar
  /// has no encryption, so a password with tar or tgz is an [ArgumentError].
  ///
  /// A path outside [dir] is an [ArgumentError]; links are refused with a
  /// [ContentException], the same as [unarchive]: an archive never silently
  /// drops entries.
  static Reader archive(
    List<String> paths, {
    ArchiveFormat format = ArchiveFormat.zip,
    String dir = '.',
    String? password,
  }) {
    if (password != null && (format == ArchiveFormat.tar || format == ArchiveFormat.tgz)) {
      throw ArgumentError.value(format, 'format', 'tar has no encryption: use zip for a password');
    }
    return _Packed(paths, dir, format, password);
  }

  /// A [Writer] extracting what it is given into [dir], creating it and
  /// merging into what is there (a file already there is kept, never
  /// replaced). The format comes from the magic bytes.
  /// [password] opens encrypted archives (zip AES or legacy ZipCrypto, 7z
  /// AES, RAR4/RAR5); an encrypted member without it, or with the wrong one,
  /// is a [ContentException] before anything lands in [dir].
  static Writer unarchive(String dir, {String? password}) => _Unpacker(dir, password);

  /// Streaming gzip compression.
  static Pipe gzip() => _GzipPipe(compress: true);

  /// Streaming gzip decompression. Bad data fails the run with a
  /// [ContentException].
  static Pipe gunzip() => _GzipPipe(compress: false);
}

/// One member to pack: its name in the archive, where it is, and whether
/// it is a folder.
typedef _Member = ({String name, String path, bool dir});

/// One member of an in-memory archive as read: its bytes decode on demand.
typedef _Entry = ({String name, int mode, bool isDir, bool isLink, Uint8List Function() data});

/// Runs one step of an in-memory reader. A [ContentException] passes; any
/// other failure (a RangeError from a damaged header, an OutOfMemoryError
/// from a hostile size) is damage too, rethrown naming [what].
T _guard<T>(String what, T Function() body) {
  try {
    return body();
  } on ContentException {
    rethrow;
  } catch (e) {
    throw ContentException('corrupt archive: $what: $e', null, null, e);
  }
}

final class _Packed with Reader {
  _Packed(this._paths, this._from, this._format, this._password);

  final List<String> _paths;
  final String _from;
  final ArchiveFormat _format;
  final String? _password;

  @override
  Stream<List<int>> stream() async* {
    if (_format == ArchiveFormat.zip || _format == ArchiveFormat.sevenZip) {
      // Zip and 7z stay in memory: their directory sits at the end.
      yield await _build();
      return;
    }
    var tar = _tarStream();
    if (_format == ArchiveFormat.tgz) tar = tar.transform(io.gzip.encoder);
    yield* tar;
  }

  /// Every member, depth-first by name. A folder brings its whole tree; '.'
  /// is [_from]'s contents. Names are relative to [_from]; a path outside it
  /// is an [ArgumentError], a missing one a [io.PathNotFoundException].
  /// Links are refused (an archive never silently drops entries), and so
  /// are the atomic-write temps of a writer saving into the tree itself.
  Future<List<_Member>> _members() async {
    final base = p.normalize(p.absolute(_from));
    final out = <String, _Member>{};
    Future<void> add(String path) async {
      final t = await io.FileSystemEntity.type(path, followLinks: false);
      final rel = p.relative(path, from: base).replaceAll('\\', '/');
      if (t == io.FileSystemEntityType.link) throw ContentException('archive refuses links: $path');
      if (t == io.FileSystemEntityType.notFound) throw io.PathNotFoundException(path, const io.OSError());
      if (posix.isTmpName(p.basename(path))) return;
      if (t == io.FileSystemEntityType.directory) {
        if (rel != '.') out[rel] = (name: '$rel/', path: path, dir: true);
        await for (final e in io.Directory(path).list(followLinks: false)) {
          await add(e.path);
        }
      } else if (t == io.FileSystemEntityType.file) {
        out[rel] = (name: rel, path: path, dir: false);
      } else {
        // A FIFO, socket or device: refused, never silently left out.
        throw ContentException('archive refuses special files: $path');
      }
    }

    for (final given in _paths) {
      final path = p.normalize(p.join(base, given));
      if (path != base && !p.isWithin(base, path)) {
        throw ArgumentError.value(given, 'paths', 'must be inside dir ($_from)');
      }
      await add(path);
    }
    final members = out.values.toList();
    tree.sortByRelative(members, (m) => m.path, base);
    return members;
  }

  /// [m]'s permission bits and stat; folders stay traversable. A member
  /// gone since it was listed is a [io.PathNotFoundException].
  static Future<(int, io.FileStat)> _stat(_Member m) async {
    final st = await io.FileStat.stat(m.path);
    if (st.type == io.FileSystemEntityType.notFound) throw io.PathNotFoundException(m.path, const io.OSError());
    var mode = st.mode & 0x1FF;
    if (m.dir && mode != 0 && (mode & 0x49) == 0) mode |= 0x49;
    return (mode, st);
  }

  Future<List<int>> _build() async {
    final members = <(String, int, List<int>, DateTime)>[];
    for (final m in await _members()) {
      final (mode, st) = await _stat(m);
      members.add((m.name, mode, m.dir ? const <int>[] : await io.File(m.path).readAsBytes(), st.modified));
    }
    return _format == ArchiveFormat.zip
        ? zip.writeZip(members, password: _password)
        : sevenzip.writeSevenZip([
            for (final (name, mode, data, _) in members) (name, mode, data),
          ], password: _password);
  }

  /// Streams a tar: one 512-byte header per member, file bytes straight
  /// from disk, two zero blocks at the end. Holds one member at a time,
  /// never the archive.
  Stream<List<int>> _tarStream() async* {
    for (final m in await _members()) {
      final (mode, st) = await _stat(m);
      final mtime = st.modified;
      // Streamed from disk: the stat size goes in the header, exactly that
      // many bytes follow (a file that shrinks mid-pack is an error).
      final size = m.dir ? 0 : st.size;
      for (final chunk in _tarHeader(
        name: m.name,
        size: size,
        mode: mode,
        mtime: mtime,
        typeflag: m.dir ? _tarDir : _tarFile,
      )) {
        yield chunk;
      }
      if (m.dir) continue;
      var sent = 0;
      if (size > 0) {
        await for (final chunk in io.File(m.path).openRead(0, size)) {
          sent += chunk.length;
          yield chunk;
        }
      }
      if (sent != size) {
        throw io.FileSystemException('file changed while packing', m.path);
      }
      final pad = (512 - size % 512) % 512;
      if (pad != 0) yield Uint8List(pad);
    }
    // End-of-archive marker.
    yield Uint8List(1024);
  }
}

/// One unpack's temp tree: members land here sandbox-checked, then merge
/// into the target. Holds the modes to apply after the merge.
final class _Extraction {
  _Extraction(this.tmp);

  final io.Directory tmp;

  // Modes collected during extraction: one `chmod <mode> p1 p2 …` per
  // distinct mode afterwards (usually 2–3 forks per archive, not one per
  // member), chunked under ARG_MAX inside `chmodBatched`.
  final _paths = <String>[];
  final _modes = <int>[];
  final _isDir = <bool>[];
  final _folded = <String, String>{};

  // Every file this unpack wrote: an existing file under a path not in
  // here means the filesystem folded two member names into one (macOS
  // normalises NFC and NFD café.txt to the same file).
  final _written = <String>{};

  var _umask = 0x12; // 022 until the temp folder tells us
  io.RandomAccessFile? _out; // the tar file member being written

  Future<void> start() async {
    await tmp.create(recursive: true);
    // A fresh folder is 0777 & ~umask: read the umask off it, then close
    // the folder (0700): a 0600 member must not be readable while it is
    // being written.
    _umask = posix.isPosix ? ~(await tmp.stat()).mode & 0x1FF : 0;
    if (posix.isPosix) await posix.chmod(tmp.path, 0x1c0);
  }

  void _keepMode(String path, int mode, {required bool isDir}) {
    var m = mode & 0x1FF;
    if (m == 0) return;
    if (isDir) m |= 0x40; // never leave a folder untraversable (S_IXUSR)
    _paths.add(path);
    _modes.add(m);
    _isDir.add(isDir);
  }

  /// Sandbox-checks [name] (unless the in-memory readers already [checked]
  /// every member) and returns its path in the temp folder, with parents
  /// created; null for a bare root entry.
  Future<String?> _prepare(String name, {bool file = false, bool checked = false}) async {
    if (!checked) _Unpacker._checkMember(name, _folded);
    // Split on both separators so member names work on every platform.
    // '.' segments name nothing: a '.' member is the target itself, whose
    // mode an archive never sets.
    final relParts = name.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty && s != '.');
    if (relParts.isEmpty) return null;
    final dest = p.joinAll([tmp.path, ...relParts]);
    await io.Directory(p.dirname(dest)).create(recursive: true);
    if (file && _written.add(dest) && await io.File(dest).exists()) {
      throw ContentException('archive members collide on this filesystem: $name');
    }
    return dest;
  }

  /// One member of an in-memory archive, already checked; [data] gives its
  /// bytes, any damage it hits named after the member.
  Future<void> _writeMember(String name, int mode, {required bool isDir, Uint8List Function()? data}) async {
    final dest = await _prepare(name, file: !isDir, checked: true);
    if (dest == null) return;
    if (isDir) {
      await io.Directory(dest).create(recursive: true);
    } else {
      await io.File(dest).writeAsBytes(data == null ? Uint8List(0) : _guard(name, data));
    }
    _keepMode(dest, mode, isDir: isDir);
  }

  /// Zip, 7z and RAR stay in memory: zip's directory and 7z's header sit
  /// at the end, a RAR solid run decodes as one. [read] lists the members
  /// of the [format] archive; damage it hits names the archive, damage in a
  /// member's bytes names the member.
  Future<void> inMemory(Stream<List<int>> input, String format, List<_Entry> Function(Uint8List) read) async {
    final acc = BytesBuilder(copy: false);
    await for (final chunk in input) {
      acc.add(chunk);
    }
    final bytes = acc.takeBytes();
    final entries = _guard(format, () => read(bytes));
    // Check every member before writing anything.
    for (final e in entries) {
      _Unpacker._checkMember(e.name, _folded);
      if (e.isLink) throw ContentException('archive member is a link: ${e.name}');
    }
    for (final e in entries) {
      // One member decoded at a time.
      await _writeMember(e.name, e.mode, isDir: e.isDir, data: e.isDir ? null : e.data);
    }
  }

  /// Stream tar events to the temp tree.
  Future<void> tar(Stream<_TarEvent> events) async {
    String? dest;
    var mode = 0;
    // macOS tar adds an AppleDouble `._name` (xattrs) beside members; one
    // is decided on its first bytes and dropped, as bsdtar does.
    String? appleDouble;
    var skipping = false;
    await for (final ev in events) {
      switch (ev) {
        case _TarHeader():
          mode = ev.mode;
          skipping = false;
          if (!ev.isDir && p.posix.basename(ev.name).startsWith('._')) {
            appleDouble = ev.name;
            dest = null;
            break;
          }
          dest = await _prepare(ev.name, file: !ev.isDir);
          if (dest == null) break;
          if (ev.isDir) {
            await io.Directory(dest).create(recursive: true);
            _keepMode(dest, mode, isDir: true);
            dest = null;
          } else {
            _out = await io.File(dest).open(mode: io.FileMode.write);
          }
        case _TarBody() when skipping:
          break;
        case _TarBody():
          final pending = appleDouble;
          if (pending != null) {
            appleDouble = null;
            if (_isAppleDouble(ev.bytes)) {
              skipping = true;
              break;
            }
            dest = await _prepare(pending, file: true);
            if (dest != null) _out = await io.File(dest).open(mode: io.FileMode.write);
          }
          await _out?.writeFrom(ev.bytes);
        case _TarEnd():
          final empty = appleDouble;
          if (empty != null) {
            appleDouble = null;
            dest = await _prepare(empty, file: true);
            if (dest != null) await io.File(dest).writeAsBytes(const []);
          }
          await _out?.close();
          _out = null;
          if (dest != null) _keepMode(dest, mode, isDir: false);
          dest = null;
      }
    }
  }

  /// Never delete the target: create it and merge each top-level
  /// member in (rename, copy fallback). Existing files are kept: a member
  /// at the same path is dropped. Every file/folder collision fails before
  /// the first rename, so a failed unpack leaves the target as it was.
  Future<void> merge(String d) async {
    // A target that is a link to a folder merges into that folder: checked
    // through the link, the collisions (and the files kept) went unseen.
    if (await io.FileSystemEntity.isLink(d) && await io.FileSystemEntity.isDirectory(d)) {
      d = await io.Directory(d).resolveSymbolicLinks();
    }
    final existing = await _Unpacker._checkCollisions(tmp.path, d);
    // Modes go through the umask like `tar` does. File modes go on in the
    // temp tree, so a file is never in the target with looser ones (a
    // rename keeps them); a file kept from the target drops its member and
    // is never re-moded.
    final mask = ~_umask & 0x1FF;
    final files = <String>[], fileModes = <int>[];
    for (var i = 0; i < _paths.length; i++) {
      if (_isDir[i]) continue;
      files.add(_paths[i]);
      fileModes.add(_modes[i] & mask);
    }
    await posix.chmodBatched(posix.groupByMode(files, fileModes));
    await io.Directory(d).create(recursive: true);
    await for (final e in tmp.list(recursive: false, followLinks: false)) {
      await _Unpacker._moveInto(e.path, p.join(d, p.basename(e.path)));
    }
    // Folder modes go on after the merge (a read-only member folder would
    // refuse the merge's renames), only on folders this unpack made.
    final dirs = <String>[], dirModes = <int>[];
    for (var i = 0; i < _paths.length; i++) {
      if (!_isDir[i]) continue;
      final path = p.join(d, p.relative(_paths[i], from: tmp.path));
      if (existing.contains(path)) continue;
      dirs.add(path);
      dirModes.add(_modes[i] & mask);
    }
    await posix.chmodBatched(posix.groupByMode(dirs, dirModes));
  }

  Future<void> dispose() async {
    try {
      await _out?.close();
    } catch (_) {}
    try {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    } catch (_) {}
  }
}

final class _Unpacker with Writer {
  _Unpacker(this._dir, this._password);

  final String _dir;
  final String? _password;

  @override
  Future<void> consume(Stream<List<int>> input) async {
    // Sniff the format from the magic bytes without consuming them: peek
    // 8 bytes, then hand on the chunks as they came.
    final it = StreamIterator(input);
    final peeked = <List<int>>[];
    final head = <int>[];
    while (head.length < 8 && await it.moveNext()) {
      final c = it.current;
      peeked.add(c);
      head.addAll(c.take(8 - head.length));
    }
    Stream<List<int>> rest() async* {
      yield* Stream.fromIterable(peeked);
      peeked.clear();
      while (await it.moveNext()) {
        yield it.current;
      }
    }

    if (head.length < 2) {
      throw const ContentException('corrupt archive: unknown format');
    }
    final isGzip = head[0] == 0x1f && head[1] == 0x8b;
    final isZip = !isGzip && head[0] == 0x50 && head[1] == 0x4b;
    final is7z = sevenzip.isSevenZip(head);
    final isRar = rarlib.isRar(head);
    final isXz = xz.isXz(head);
    // Normalise the target; the temp folder is a SIBLING of the target,
    // never inside it. Use the absolute path so '.' (whose dirname is
    // '.') still gets a sibling outside itself.
    final d = p.normalize(_dir);
    final x = _Extraction(io.Directory(tree.tmpPath(p.normalize(p.absolute(d)))));
    // An interrupt skips `finally`: the exit hook removes the temp folder.
    final token = exit.onExit(() async {
      try {
        await x.tmp.delete(recursive: true);
      } catch (_) {}
    });
    try {
      await x.start();
      final pw = _password;
      if (isZip) {
        await x.inMemory(
          rest(),
          'zip',
          (b) => [
            for (final f in zip.readZip(b))
              (name: f.name, mode: f.mode, isDir: f.isDir, isLink: f.isLink, data: () => f.data(password: pw)),
          ],
        );
      } else if (is7z) {
        await x.inMemory(
          rest(),
          '7z',
          (b) => [
            for (final e in sevenzip.readSevenZip(b, password: pw))
              (name: e.name, mode: e.mode, isDir: e.isDir, isLink: false, data: e.data),
          ],
        );
      } else if (isRar) {
        await x.inMemory(
          rest(),
          'RAR',
          (b) => [
            for (final e in rarlib.readRar(b, password: pw))
              (name: e.name, mode: e.mode, isDir: e.isDir, isLink: e.isLink, data: e.data),
          ],
        );
      } else if (isXz) {
        // .tar.xz: the compressed bytes are held (xz's index sits at the end),
        // the tar streams out of the decoder a chunk at a time.
        final acc = BytesBuilder(copy: false);
        await for (final chunk in rest()) {
          acc.add(chunk);
        }
        final bytes = acc.takeBytes();
        Stream<List<int>> pieces() async* {
          final it = xz.xzChunks(bytes).iterator;
          while (_guard('xz', it.moveNext)) {
            yield it.current;
          }
        }

        await x.tar(_parseTar(pieces(), fromGzip: true));
      } else {
        // Tar and gzip-compressed tar stream straight to the temp sibling:
        // links, escapes and truncation fail here, before the merge.
        await x.tar(isGzip ? _parseTar(_gunzipChecked(rest()), fromGzip: true) : _parseTar(rest(), fromGzip: false));
      }
      await x.merge(d);
    } finally {
      await x.dispose();
      exit.offExit(token);
      await it.cancel();
    }
  }

  /// Throw when a member would put a file where the target has a folder, or
  /// a folder where it has a file (a link counts as a file). Returns the
  /// target paths that already exist (kept, modes and all).
  static Future<Set<String>> _checkCollisions(String tmp, String target) async {
    final existing = <String>{};
    if (await io.FileSystemEntity.type(target, followLinks: false) != io.FileSystemEntityType.directory) {
      return existing;
    }
    await for (final e in io.Directory(tmp).list(recursive: true, followLinks: false)) {
      final dest = p.join(target, p.relative(e.path, from: tmp));
      final dt = await io.FileSystemEntity.type(dest, followLinks: false);
      if (dt == io.FileSystemEntityType.notFound) continue;
      final destIsDir = dt == io.FileSystemEntityType.directory;
      if ((e is io.Directory) != destIsDir) {
        throw io.FileSystemException('archive member collides with existing ${destIsDir ? 'directory' : 'file'}', dest);
      }
      existing.add(dest);
    }
    return existing;
  }

  /// Move [src] (inside the temp dir) into [dest] (inside the target),
  /// merging folders; an existing file stays and the member is dropped
  /// (the temp tree goes when the unpack ends).
  static Future<void> _moveInto(String src, String dest) async {
    final srcType = await io.FileSystemEntity.type(src, followLinks: false);
    final destType = await io.FileSystemEntity.type(dest, followLinks: false);
    final srcIsDir = srcType == io.FileSystemEntityType.directory;
    final destIsDir = destType == io.FileSystemEntityType.directory;
    if (srcIsDir && destIsDir) {
      await for (final child in io.Directory(src).list(recursive: false, followLinks: false)) {
        await _moveInto(child.path, p.join(dest, p.basename(child.path)));
      }
      return;
    }
    if (destType != io.FileSystemEntityType.notFound) {
      if (srcIsDir != destIsDir) {
        // Never delete on type collision: an archive file over an existing
        // dir (or vice versa) throws instead of rm -rf.
        throw io.FileSystemException('archive member collides with existing ${destIsDir ? 'directory' : 'file'}', dest);
      }
      return;
    }
    try {
      if (srcType == io.FileSystemEntityType.directory) {
        await io.Directory(src).rename(dest);
      } else {
        await io.File(src).rename(dest);
      }
    } on io.FileSystemException catch (e) {
      // Only a rename across devices copies then deletes; anything else
      // (permissions) is the caller's error, not a reason to copy.
      if (!posix.isCrossDevice(e)) rethrow;
      if (srcType == io.FileSystemEntityType.directory) {
        await tree.copyTree(src, dest);
        await io.Directory(src).delete(recursive: true);
      } else {
        await io.File(src).copy(dest);
        await tree.preserveFileMeta(src, dest);
        await io.File(src).delete();
      }
    }
  }

  static final _badPart = RegExp(r'[<>:"|?*\x00-\x1f]');
  static final _reserved = RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$', caseSensitive: false);

  /// Rejects, on every OS, any name that would not extract the same way on
  /// Linux, macOS and Windows: escapes, device names, characters and
  /// trailing dots/spaces Windows rewrites, and members (or folders) that
  /// differ only in case. [folded] remembers each path seen, case-folded.
  static void _checkMember(String name, Map<String, String> folded) {
    if (name.isEmpty) {
      throw ContentException('archive member has an empty name');
    }
    if (name.startsWith('/') || name.startsWith('\\') || RegExp(r'^[A-Za-z]:').hasMatch(name)) {
      throw ContentException('archive member escapes: $name');
    }
    var path = '';
    for (final part in name.replaceAll('\\', '/').split('/')) {
      if (part == '..' ||
          part.endsWith('.') && part != '.' ||
          part.endsWith(' ') ||
          _badPart.hasMatch(part) ||
          _reserved.hasMatch(part)) {
        throw ContentException('archive member escapes: $name');
      }
      if (part.isEmpty || part == '.') continue;
      path = path.isEmpty ? part : '$path/$part';
      if ((folded[path.toLowerCase()] ??= path) != path) {
        throw ContentException('archive members differ only in case: $name');
      }
    }
  }
}

// ---------------------------------------------------------------------------
// In-house streaming tar. Headers are 512 bytes; file data follows, padded
// to a 512 multiple; the archive ends at the first all-zero block (a clean
// EOF there counts too). Pax extended headers (`x`, and global `g`) and GNU
// long names (`L`) override the header name; symlinks and hardlinks are
// refused with a ContentException, the same as zip.
// ---------------------------------------------------------------------------

/// AppleDouble magic: `00 05 16 07`.
bool _isAppleDouble(List<int> b) => b.length >= 4 && b[0] == 0 && b[1] == 5 && b[2] == 0x16 && b[3] == 7;

/// Tar typeflags we write and read.
const _tarFile = 0x30; // '0'
const _tarDir = 0x35; // '5'

/// What [_parseTar] emits: a member header, its body in chunks (files
/// only), then the end of the member.
sealed class _TarEvent {}

final class _TarHeader extends _TarEvent {
  _TarHeader(this.name, this.mode, {required this.isDir});
  final String name;
  final int mode;
  final bool isDir;
}

final class _TarBody extends _TarEvent {
  _TarBody(this.bytes);
  final Uint8List bytes;
}

final class _TarEnd extends _TarEvent {}

/// Header chunks for one member: an optional pax extended header when the
/// name needs more than ustar's split `prefix/name` can hold, then the
/// 512-byte header itself.
List<List<int>> _tarHeader({
  required String name,
  required int size,
  required int mode,
  required DateTime mtime,
  required int typeflag,
}) {
  final out = <List<int>>[];
  var headerName = name;
  var prefix = '';
  if (utf8.encode(name).length > 100) {
    final isDir = name.endsWith('/');
    final core = isDir ? name.substring(0, name.length - 1) : name;
    final slash = core.lastIndexOf('/');
    final tail = slash < 0 ? core : core.substring(slash + 1);
    final head = slash < 0 ? '' : core.substring(0, slash);
    final tailBytes = utf8.encode(isDir ? '$tail/' : tail).length;
    if (slash > 0 && tailBytes <= 100 && utf8.encode(head).length <= 155) {
      headerName = isDir ? '$tail/' : tail;
      prefix = head;
    } else {
      // A pax `path=` record carries the full name; the following header
      // carries a truncated one for readers without pax support.
      final record = _paxRecord('path', name);
      final padded = Uint8List((record.length + 511) ~/ 512 * 512);
      padded.setRange(0, record.length, record);
      out.add(
        _rawHeader(
          name: '././@PaxHeader',
          size: record.length,
          mode: 0,
          mtime: mtime,
          typeflag: 0x78, // 'x'
        ),
      );
      out.add(padded);
      headerName = _truncateUtf8(name, 100);
    }
  }
  out.add(_rawHeader(name: headerName, size: size, mode: mode, mtime: mtime, typeflag: typeflag, prefix: prefix));
  return out;
}

List<int> _rawHeader({
  required String name,
  required int size,
  required int mode,
  required DateTime mtime,
  required int typeflag,
  String prefix = '',
}) {
  final buf = Uint8List(512);
  _writeField(buf, 0, 100, utf8.encode(name));
  _writeOctal(buf, 100, 8, mode & 0xFFF);
  _writeOctal(buf, 108, 8, 0);
  _writeOctal(buf, 116, 8, 0);
  if (size > 0x1FFFFFFFF) {
    // 8 GiB and up: GNU base-256 (top bit set, big-endian value).
    buf[124] = 0x80;
    for (var i = 0; i < 8; i++) {
      buf[135 - i] = (size >> (8 * i)) & 0xFF;
    }
  } else {
    _writeOctal(buf, 124, 12, size);
  }
  final secs = mtime.millisecondsSinceEpoch ~/ 1000;
  _writeOctal(buf, 136, 12, secs < 0 ? 0 : secs);
  buf[156] = typeflag;
  buf.setRange(257, 263, 'ustar\x00'.codeUnits);
  buf[263] = 0x30; // '00'
  buf[264] = 0x30;
  _writeField(buf, 345, 155, utf8.encode(prefix));
  // The checksum covers the header with its own field read as spaces.
  var sum = 0;
  for (var i = 0; i < 512; i++) {
    sum += (i >= 148 && i < 156) ? 0x20 : buf[i];
  }
  _writeOctal(buf, 148, 8, sum, trailingSpace: true);
  return buf;
}

/// Raw bytes into a fixed field, truncated when too long (a 100-byte name
/// has no NUL terminator, which ustar allows).
void _writeField(List<int> buf, int offset, int length, List<int> bytes) {
  final n = bytes.length > length ? length : bytes.length;
  buf.setRange(offset, offset + n, bytes);
}

/// Zero-padded octal digits with a trailing NUL (`length` includes it); the
/// checksum field instead ends NUL + space.
void _writeOctal(List<int> buf, int offset, int length, int value, {bool trailingSpace = false}) {
  final width = trailingSpace ? length - 2 : length - 1;
  var digits = value.toRadixString(8);
  if (digits.length > width) digits = digits.substring(digits.length - width);
  for (var i = 0; i < width - digits.length; i++) {
    buf[offset + i] = 0x30;
  }
  for (var i = 0; i < digits.length; i++) {
    buf[offset + width - digits.length + i] = digits.codeUnitAt(i);
  }
  buf[offset + width] = 0;
  if (trailingSpace) buf[offset + width + 1] = 0x20;
}

/// One pax record: `<len> <key>=<value>\n`, where `<len>` counts itself.
List<int> _paxRecord(String key, String value) {
  final body = utf8.encode('$key=$value\n');
  var n = body.length + 2;
  while (true) {
    final head = utf8.encode('$n ');
    if (head.length + body.length == n) return [...head, ...body];
    n = head.length + body.length;
  }
}

/// Truncate to fit [maxBytes] UTF-8 bytes without splitting a character.
String _truncateUtf8(String s, int maxBytes) {
  if (utf8.encode(s).length <= maxBytes) return s;
  var end = s.length;
  while (end > 0 && utf8.encode(s.substring(0, end)).length > maxBytes) {
    end--;
  }
  return s.substring(0, end);
}

/// Largest pax / GNU long-name record accepted (they are buffered).
const _tarMetaMax = 1 << 20;

/// Streams tar events: file bytes are forwarded as they arrive (O(1) memory,
/// whatever the member size); only the 512-byte header and pax/GNU records
/// are buffered. A zero block or a clean EOF ends the archive; a partial
/// header or body at EOF or a bad checksum is a [ContentException].
Stream<_TarEvent> _parseTar(Stream<List<int>> input, {required bool fromGzip}) async* {
  final head = BytesBuilder(copy: false);
  final metaBuf = BytesBuilder(copy: false);
  var remaining = 0; // body bytes still to come
  var pad = 0; // padding bytes still to skip
  var metaFlag = 0; // typeflag of the pax/GNU record being collected, else 0
  var emit = false; // forward the current body as events
  var seen = 0; // members yielded so far
  String? pendingPath; // pax `x` / GNU `L`: name override for the next entry
  String? globalPath; // pax `g`: name override for every following entry
  int? pendingSize; // pax `size`: size override for the next entry

  Never fail(String message, {bool notTar = false}) {
    // Gzip that decodes but opens with a bad header is not a tar at all.
    if (notTar && fromGzip && seen == 0) {
      throw const ContentException('corrupt archive: gzip data is not a tar archive');
    }
    throw ContentException(message);
  }

  void finishMeta() {
    final data = metaBuf.takeBytes();
    if (metaFlag == 0x78 || metaFlag == 0x67) {
      // Pax extended ('x') or global ('g') header: `path=` renames,
      // `linkpath=` marks a link, which unpack refuses like zip does.
      final records = _parsePax(data);
      if (records.keys.any((k) => k.startsWith('GNU.sparse.'))) {
        throw ContentException('sparse tar member unsupported: ${records['GNU.sparse.name'] ?? records['path']}');
      }
      final linkpath = records['linkpath'];
      if (linkpath != null && linkpath.isNotEmpty) {
        throw ContentException('archive member is a link: ${records['path']}');
      }
      final renamed = records['path'];
      if (renamed != null && renamed.isNotEmpty) {
        if (metaFlag == 0x78) {
          pendingPath = renamed;
        } else {
          globalPath = renamed;
        }
      }
      if (metaFlag == 0x78) {
        final sz = int.tryParse(records['size'] ?? '');
        if (sz != null && sz >= 0) pendingSize = sz;
      }
    } else if (metaFlag == 0x4c) {
      // GNU long name: the data is the next entry's name.
      var text = utf8.decode(data, allowMalformed: true);
      while (text.endsWith('\x00')) {
        text = text.substring(0, text.length - 1);
      }
      if (text.isNotEmpty) pendingPath = text;
    }
    metaFlag = 0;
  }

  // After the end marker the rest is read and dropped, not cancelled: a
  // gzip trailer (or a hash checking at end of stream) runs only at EOF, so
  // a truncated .tar.gz fails instead of extracting.
  var ended = false;
  await for (final raw in input) {
    if (ended) continue;
    final c = raw is Uint8List ? raw : Uint8List.fromList(raw);
    var i = 0;
    while (i < c.length) {
      if (remaining > 0) {
        final n = remaining < c.length - i ? remaining : c.length - i;
        final piece = Uint8List.sublistView(c, i, i + n);
        i += n;
        remaining -= n;
        if (metaFlag != 0) {
          metaBuf.add(piece);
        } else if (emit) {
          yield _TarBody(piece);
        }
        if (remaining == 0) {
          if (metaFlag != 0) {
            finishMeta();
          } else if (emit) {
            yield _TarEnd();
          }
        }
        continue;
      }
      if (pad > 0) {
        final n = pad < c.length - i ? pad : c.length - i;
        i += n;
        pad -= n;
        continue;
      }
      final need = 512 - head.length;
      final n = need < c.length - i ? need : c.length - i;
      head.add(Uint8List.sublistView(c, i, i + n));
      i += n;
      if (head.length < 512) continue;
      final h = head.takeBytes();
      if (h.every((b) => b == 0)) {
        ended = true;
        break;
      }
      if (!_tarChecksumOk(h, 0)) {
        fail('corrupt archive: bad tar header', notTar: true);
      }
      var size = _tarSize(h, 0);
      if (size < 0) {
        fail('corrupt archive: bad tar size in header', notTar: true);
      }
      final typeflag = h[156];
      final isMeta = typeflag == 0x78 || typeflag == 0x67 || typeflag == 0x4c || typeflag == 0x4b;
      if (!isMeta && pendingSize != null) {
        size = pendingSize!;
        pendingSize = null;
      }
      pad = (512 - size % 512) % 512;
      remaining = size;
      if (isMeta) {
        if (size > _tarMetaMax) {
          fail('corrupt archive: tar record too large', notTar: true);
        }
        // GNU long linkname: the link itself errors below.
        metaFlag = typeflag == 0x4b ? 0 : typeflag;
        emit = false;
        if (size == 0 && metaFlag != 0) finishMeta();
        continue;
      }
      var name = _tarString(h, 0, 100);
      final prefix = _tarString(h, 345, 155);
      if (prefix.isNotEmpty) name = '$prefix/$name';
      name = pendingPath ?? globalPath ?? name;
      pendingPath = null;
      // Old (V7) tars mark a folder with a regular type and a trailing '/';
      // '7' (contiguous file) is a regular file everywhere but on old
      // Masscomp systems.
      final regular = typeflag == 0x30 || typeflag == 0 || typeflag == 0x37;
      if (typeflag == 0x35 || regular && name.endsWith('/')) {
        seen++;
        emit = false;
        yield _TarHeader(name, _tarMode(h), isDir: true);
      } else if (regular) {
        seen++;
        emit = true;
        yield _TarHeader(name, _tarMode(h), isDir: false);
        if (size == 0) yield _TarEnd();
      } else if (typeflag == 0x31 || typeflag == 0x32) {
        throw ContentException('archive member is a link: $name');
      } else {
        fail(
          'corrupt archive: unsupported tar entry '
          "'${String.fromCharCode(typeflag)}' for $name",
        );
      }
    }
  }
  if (!ended && (head.length != 0 || remaining != 0 || pad != 0)) {
    fail('corrupt archive: truncated tar', notTar: true);
  }
}

/// NUL-terminated string field, malformed UTF-8 replaced.
String _tarString(List<int> buf, int offset, int length) {
  var end = offset;
  while (end < offset + length && buf[end] != 0) {
    end++;
  }
  return utf8.decode(buf.sublist(offset, end), allowMalformed: true);
}

/// The mode field; a damaged one is no mode (the umask default), never the
/// 0777 that -1 & 0x1FF would give.
int _tarMode(List<int> h) {
  final m = _tarOctal(h, 100, 8);
  return m < 0 ? 0 : m;
}

/// Octal field (NUL/space padded); empty means 0 for mode/mtime.
int _tarOctal(List<int> buf, int offset, int length) {
  var value = 0;
  var digits = 0;
  for (var i = offset; i < offset + length; i++) {
    final b = buf[i];
    if (b == 0 || b == 0x20) continue;
    if (b < 0x30 || b > 0x37) return -1;
    value = value * 8 + (b - 0x30);
    digits++;
  }
  return digits == 0 ? 0 : value;
}

/// Size field: octal, or base-256 when the top bit is set. -1 when invalid.
int _tarSize(List<int> buf, int header) {
  const off = 124;
  if (buf[header + off] & 0x80 != 0) {
    var value = 0;
    for (var i = header + off + 1; i < header + off + 12; i++) {
      value = value * 256 + buf[i];
    }
    return value;
  }
  var value = 0;
  var digits = 0;
  for (var i = header + off; i < header + off + 12; i++) {
    final b = buf[i];
    if (b == 0 || b == 0x20) continue;
    if (b < 0x30 || b > 0x37) return -1;
    value = value * 8 + (b - 0x30);
    digits++;
  }
  return digits == 0 ? -1 : value;
}

/// The classic tar sniff, also the read-side validator: the octal value in
/// bytes 148..156 equals the sum of the 512 header bytes with the checksum
/// field itself read as spaces.
bool _tarChecksumOk(List<int> bytes, int offset) {
  if (bytes.length < offset + 512) return false;
  var stored = 0;
  var digits = 0;
  for (var i = offset + 148; i < offset + 156; i++) {
    final b = bytes[i];
    if (b == 0 || b == 0x20) continue;
    if (b < 0x30 || b > 0x37) return false;
    stored = stored * 8 + (b - 0x30);
    digits++;
  }
  if (digits == 0) return false;
  var sum = 0;
  for (var i = offset; i < offset + 512; i++) {
    sum += (i >= offset + 148 && i < offset + 156) ? 0x20 : bytes[i];
  }
  return sum == stored;
}

Map<String, String> _parsePax(Uint8List data) {
  final out = <String, String>{};
  var i = 0;
  while (i < data.length) {
    final space = data.indexOf(0x20, i);
    if (space < 0) break;
    final len = int.tryParse(utf8.decode(data.sublist(i, space)));
    if (len == null || len <= 0 || i + len > data.length) break;
    var record = utf8.decode(data.sublist(space + 1, i + len), allowMalformed: true);
    if (record.endsWith('\n')) record = record.substring(0, record.length - 1);
    final eq = record.indexOf('=');
    if (eq > 0) out[record.substring(0, eq)] = record.substring(eq + 1);
    i += len;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Gzip. zlib checks each member's CRC-32 and size, and goes on to the next
// member of a concatenated stream (bgzip, pigz -i, `cat a.gz b.gz`). What it
// never reports is input that stops inside a member: after the real input an
// empty gzip member is fed in. At a member boundary it decodes to nothing;
// inside a member it is read as more of that member, which fails or decodes
// to stray bytes, so a cut stream is caught however many members it had.
// ---------------------------------------------------------------------------

/// `gzip` of no bytes: the probe fed after the input.
const _emptyGzip = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0];

/// Streaming gzip decompression with a truncation check, constant memory.
Stream<List<int>> _gunzipChecked(Stream<List<int>> input) async* {
  final z = io.RawZLibFilter.inflateFilter(gzip: true);
  var compressed = 0;
  Iterable<List<int>> drain({bool end = false}) sync* {
    for (List<int>? out; (out = z.processed(end: end)) != null;) {
      yield out!;
    }
  }

  try {
    await for (final chunk in input) {
      if (chunk.isEmpty) continue;
      compressed += chunk.length;
      z.process(chunk, 0, chunk.length);
      yield* Stream.fromIterable(drain().toList());
    }
    if (compressed == 0) throw const ContentException('bad gzip data: empty (not a gzip stream)');
    if (compressed < 18) throw const ContentException('bad gzip data: truncated (no trailer)');
    z.process(_emptyGzip, 0, _emptyGzip.length);
    if (drain(end: true).any((out) => out.isNotEmpty)) {
      throw const ContentException('bad gzip data: truncated (the stream stops inside a member)');
    }
  } on ContentException {
    rethrow;
  } on FormatException catch (e) {
    // zlib's own "Filter error": the data, not the source, is bad.
    throw ContentException('bad gzip data: ${e.message} (truncated or corrupt)', null, null, e);
  }
}

final class _GzipPipe implements Pipe {
  _GzipPipe({required this.compress});

  final bool compress;

  @override
  void abort(Object error) {
    // Stateless: nothing to poison or release.
  }

  @override
  Stream<List<int>> transform(Stream<List<int>> input) =>
      compress ? input.transform(io.gzip.encoder) : _gunzipChecked(input);
}
