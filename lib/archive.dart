/// Archives and gzip, in pure Dart.
///
/// | format | archive | unarchive |
/// |---|---|---|
/// | zip | ✓ (streamed, zip64; AES-256 with `password:`) | ✓ (AES, legacy ZipCrypto) |
/// | tar, tgz | ✓ (streamed) | ✓ (streamed; `.tar.xz` too) |
/// | 7z | ✓ (Deflate; AES-256 hides names) | ✓ (LZMA, LZMA2, PPMd, Deflate, BCJ, AES) |
/// | RAR4, RAR5 | — (the compressor is proprietary) | ✓ (solid, filters, PPMd, AES) |
///
/// Unarchiving zip, 7z and RAR holds the archive in memory (their directory
/// or solid stream needs it whole) and decodes on its own isolate; tar,
/// tgz and `.tar.xz` stream one member at a time (xz decodes on its own
/// isolate too). Ctrl-C and screen redraws stay live either way. File
/// modes and mtimes are kept; links are kept when they point inside the
/// folder.
///
/// ```dart
/// await (Archive.archive(['site', 'README.md']) > Fs.file('site.zip'));  // like zip -r
/// await (Archive.archive(['.'], dir: 'site', format: .tgz) > Fs.file('site.tgz')); // the contents, streamed
/// await (Archive.archive(['docs'], format: .sevenzip, password: pw) > Fs.file('docs.7z'));
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
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'core.dart';
export 'core.dart';

import 'shell.dart' show Shell;
import 'src/exit.dart' as exit;
import 'src/posix.dart' as posix;
import 'src/rar.dart' as rarlib;
import 'src/sevenzip.dart' as sevenzip;
import 'src/tool.dart';
import 'src/tree.dart' as tree;
import 'src/xz.dart' as xz;
import 'src/zip.dart' as zip;

/// Formats [Archive.archive] writes. [Archive.unarchive] reads these and
/// RAR and `.tar.xz` (the magic bytes decide); RAR is read-only, its
/// compressor being proprietary.
enum ArchiveFormat {
  /// Deflate, streamed (zip64 past 4 GiB or 65,535 members); WinZip AES-256
  /// with a password.
  zip,

  /// Plain tar, streamed.
  tar,

  /// Gzipped tar, streamed.
  tgz,

  /// 7z (deflate; AES-256 with the names hidden, with a password). Built in
  /// memory, up to 4 GiB.
  sevenzip,
}

/// Entry point: archive files and folders, unarchive a stream, gzip on
/// the way.
abstract final class Archive {
  /// A [Reader] of an archive holding [paths] (files and folders, each with
  /// its whole tree), named relative to [dir] (default: the working
  /// folder, as `Shell.run(dir:)`), like `zip -r out.zip site README.md`.
  /// `['.']` is the contents of [dir]: `Archive.archive(['.'], dir: 'site')`.
  /// Built when read.
  ///
  /// With [password] the files are encrypted: zip as WinZip AES-256 (what
  /// every modern tool reads), 7z as AES-256 with the names hidden too. Tar
  /// has no encryption, so a password with tar or tgz is an [ArgumentError].
  ///
  /// A path outside [dir] is an [ArgumentError]. A link is stored as a link
  /// when it points inside [dir]; one pointing outside, and a FIFO, socket
  /// or device, is a [ContentException]: an archive never silently drops
  /// entries.
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
  /// replaced). The format comes from the magic bytes; one this module
  /// cannot read (bzip2, zstd, lz4, …) is named in the [ContentException].
  /// Symlinks and hardlinks are kept when they resolve inside [dir] (a
  /// hardlink lands as a copy); one that points outside fails by name.
  /// [password] opens encrypted archives (zip AES or legacy ZipCrypto, 7z
  /// AES, RAR4/RAR5); an encrypted member without it, or with the wrong one,
  /// is a [ContentException] before anything lands in [dir].
  static Writer unarchive(String dir, {String? password}) => _Unpacker(dir, password);

  /// Streaming gzip compression.
  static Pipe gzip() => _GzipPipe(compress: true);

  /// Streaming gzip decompression. Bad or truncated data fails the run with
  /// a [ContentException].
  static Pipe gunzip() => _GzipPipe(compress: false);
}

/// One member to pack: its name in the archive, where it is, whether it is
/// a folder, and a link's target.
typedef _Member = ({String name, String path, bool dir, String? link});

/// What a member is.
enum _Kind { file, dir, symlink, hardlink }

/// One member of an in-memory archive as read: its bytes (a link's target)
/// decode on demand.
typedef _Entry = ({String name, int mode, _Kind kind, DateTime? mtime, Uint8List Function() data});

/// A link member, placed once every other member is in: links go in last,
/// so no member is ever written through one.
typedef _Link = ({String name, String target, bool hard});

/// Archives bigger than this (7z, RAR) go to 7-Zip instead of memory.
const _inMemoryMax = 32 << 20;

/// 7-Zip's staging folder inside the temp tree; removed before the merge.
const _stageName = '.dart_toolkit_7z~';

/// Every path whose mode is set after the merge: path, mode, folder.
typedef _Modes = List<(String, int, bool)>;

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
    switch (_format) {
      case ArchiveFormat.zip:
        yield* zip.zipStream(_zipSources(), password: _password);
      case ArchiveFormat.sevenzip:
        yield* _sevenzip();
      case ArchiveFormat.tar:
        yield* _tarStream();
      case ArchiveFormat.tgz:
        yield* _tarStream().transform(io.gzip.encoder);
    }
  }

  /// Every member, depth-first by name. A folder brings its whole tree; '.'
  /// is [_from]'s contents (a link to a folder is followed there). Names
  /// are relative to [_from]; a path outside it is an [ArgumentError], a
  /// missing one a [io.PathNotFoundException]. A link pointing outside
  /// [_from] is refused, and so are the atomic-write temps of a writer
  /// saving into the tree itself.
  Future<List<_Member>> _members() async {
    var base = p.normalize(p.absolute(_from));
    if (await io.FileSystemEntity.isLink(base) && await io.FileSystemEntity.isDirectory(base)) {
      base = await io.Directory(base).resolveSymbolicLinks();
    }
    final out = <String, _Member>{};
    Future<void> add(String path) async {
      final t = await io.FileSystemEntity.type(path, followLinks: false);
      final rel = p.relative(path, from: base).replaceAll('\\', '/');
      if (t == io.FileSystemEntityType.notFound) throw io.PathNotFoundException(path, const io.OSError());
      if (posix.isTmpName(p.basename(path))) return;
      if (t == io.FileSystemEntityType.link) {
        final target = (await io.Link(path).target()).replaceAll('\\', '/');
        final to = p.normalize(p.join(p.dirname(path), target));
        if (_absolute(target) || to != base && !p.isWithin(base, to)) {
          throw ContentException('archive refuses a link that points outside dir: $path -> $target');
        }
        out[rel] = (name: rel, path: path, dir: false, link: target);
      } else if (t == io.FileSystemEntityType.directory) {
        if (rel != '.') out[rel] = (name: '$rel/', path: path, dir: true, link: null);
        await for (final e in io.Directory(path).list(followLinks: false)) {
          await add(e.path);
        }
      } else if (t == io.FileSystemEntityType.file) {
        out[rel] = (name: rel, path: path, dir: false, link: null);
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

  /// [m]'s permission bits, size and mtime; folders stay traversable, a
  /// link is 0777 with no size. A member gone since it was listed is a
  /// [io.PathNotFoundException].
  static Future<(int, int, DateTime)> _stat(_Member m) async {
    final st = await io.FileStat.stat(m.path);
    if (m.link != null) {
      return (0x1FF, 0, st.type == io.FileSystemEntityType.notFound ? DateTime.now() : st.modified);
    }
    if (st.type == io.FileSystemEntityType.notFound) throw io.PathNotFoundException(m.path, const io.OSError());
    var mode = st.mode & 0x1FF;
    if (m.dir && mode != 0 && (mode & 0x49) == 0) mode |= 0x49;
    return (mode, m.dir ? 0 : st.size, st.modified);
  }

  Stream<zip.ZipSource> _zipSources() async* {
    for (final m in await _members()) {
      final (mode, size, mtime) = await _stat(m);
      yield (
        name: m.name,
        mode: mode,
        mtime: mtime,
        size: size,
        open: size == 0 ? null : () => io.File(m.path).openRead(0, size + 1),
        link: m.link,
      );
    }
  }

  /// 7-Zip writes it (LZMA2 on every core, links kept, AES with the
  /// names hidden when a password is set) into a temp file, since 7z's
  /// header sits after the data; then the file streams out. The members are
  /// ours: files, links and empty folders, so temps never slip in.
  Stream<List<int>> _sevenzip() async* {
    final members = await _members();
    final names = <String>[];
    for (final m in members) {
      final name = m.dir ? m.name.substring(0, m.name.length - 1) : m.name;
      if (name.contains('\n') || name.contains('\r')) {
        throw ContentException('7z cannot list a name with a line break: $name');
      }
      if (!m.dir || !members.any((o) => o != m && o.name.startsWith(m.name))) names.add(name);
    }
    var base = p.normalize(p.absolute(_from));
    if (await io.FileSystemEntity.isLink(base) && await io.FileSystemEntity.isDirectory(base)) {
      base = await io.Directory(base).resolveSymbolicLinks();
    }
    final work = await io.Directory.systemTemp.createTemp('dart_toolkit_7z_');
    try {
      final list = p.join(work.path, 'list.txt');
      final out = p.join(work.path, 'out.7z');
      await io.File(list).writeAsString(names.map((n) => '$n\n').join());
      final pw = _password;
      // A password goes on stdin (asked twice), never in the process list.
      final make = Shell.filter([
        await tool(Tool.sevenzip),
        'a',
        '-t7z',
        '-mx=5',
        '-snl',
        '-scsUTF-8',
        '-bso0',
        '-bsp0',
        '-y',
        if (pw != null) ...['-p', '-mhe=on'],
        out,
        '@$list',
      ], dir: base);
      try {
        await make.transform(Stream.value(pw == null ? const <int>[] : utf8.encode('$pw\n$pw\n'))).drain<void>();
      } on io.ProcessException catch (e) {
        throw io.FileSystemException('7-Zip failed: ${e.message}', base);
      }
      yield* io.File(out).openRead();
    } finally {
      await work.delete(recursive: true).catchError((_) => work);
    }
  }

  /// Streams a tar: one 512-byte header per member, file bytes straight
  /// from disk, two zero blocks at the end. Holds one member at a time,
  /// never the archive.
  Stream<List<int>> _tarStream() async* {
    for (final m in await _members()) {
      final (mode, size, mtime) = await _stat(m);
      // Streamed from disk: the stat size goes in the header, exactly that
      // many bytes follow (a file that shrinks mid-pack is an error).
      for (final chunk in _tarHeader(
        name: m.name,
        size: size,
        mode: mode,
        mtime: mtime,
        typeflag: m.link != null ? _tarSymlink : (m.dir ? _tarDir : _tarFile),
        link: m.link ?? '',
      )) {
        yield chunk;
      }
      if (size == 0) continue;
      var sent = 0;
      await for (final chunk in io.File(m.path).openRead(0, size)) {
        sent += chunk.length;
        yield chunk;
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
  final _modes = <(String, int, bool)>[];
  final _folded = <String, String>{};
  final _links = <_Link>[];

  // Every file this unpack wrote: an existing file under a path not in
  // here means the filesystem folded two member names into one (macOS
  // normalises NFC and NFD café.txt to the same file).
  final _written = <String>{};

  var _umask = 0x12; // 022 until the temp folder tells us
  io.RandomAccessFile? _out; // the tar file member being written

  // The isolate decoding an in-memory archive, and when it is gone: an
  // interrupt stops it before the temp folder goes.
  Isolate? _worker;
  Future<Object?>? _workerGone;

  Future<void> start() async {
    await tmp.create(recursive: true);
    // A fresh folder is 0777 & ~umask: read the umask off it, then close
    // the folder (0700): a 0600 member must not be readable while it is
    // being written.
    _umask = posix.isPosix ? ~(await tmp.stat()).mode & 0x1FF : 0;
    if (posix.isPosix) await posix.chmod(tmp.path, 0x1c0);
  }

  /// Sandbox-checks [name] and returns its path in the temp folder, with
  /// parents created; null for a bare root entry.
  Future<String?> _prepare(String name, {bool file = false}) async {
    _checkMember(name, _folded);
    final dest = _dest(tmp.path, name);
    if (dest == null) return null;
    await io.Directory(p.dirname(dest)).create(recursive: true);
    if (file && _written.add(dest) && await io.File(dest).exists()) {
      throw ContentException('archive members collide on this filesystem: $name');
    }
    return dest;
  }

  /// Zip, 7z and RAR stay in memory: zip's directory and 7z's header sit
  /// at the end, a 7z solid folder decodes as one. The archive decodes and
  /// lands in the temp tree on its own isolate ([_unpackBytes]).
  Future<void> inMemory(Stream<List<int>> input, _Format format, String? password) async {
    final acc = BytesBuilder(copy: false);
    await for (final chunk in input) {
      acc.add(chunk);
    }
    _modes.addAll(await _isolated(_unpackJob(acc.takeBytes(), format, password, tmp.path)));
  }

  /// [work]'s result, computed on its own isolate (registered, so an
  /// interrupt can stop it); its error is rethrown here.
  Future<R> _isolated<R>(FutureOr<R> Function() work) async {
    final port = RawReceivePort();
    final result = Completer<Object?>();
    port.handler = (Object? m) {
      port.close();
      result.complete(m);
    };
    try {
      _worker = await Isolate.spawn(
        _isolateMain,
        (work, port.sendPort),
        onExit: port.sendPort,
        onError: port.sendPort,
        debugName: 'unarchive',
      );
    } catch (_) {
      port.close();
      rethrow;
    }
    _workerGone = result.future;
    final m = await result.future;
    _worker = null;
    return switch (m) {
      (final Object? value,) => value as R,
      (final Object e, final String stack) => Error.throwWithStackTrace(e, StackTrace.fromString(stack)),
      // An uncaught error or a vanished isolate is a decoder bug or a
      // resource limit, never a verdict on the data.
      [final Object? e, final Object? stack] => Error.throwWithStackTrace(
        StateError('the archive decoder crashed: $e'),
        StackTrace.fromString('$stack'),
      ),
      _ => throw StateError('the archive decoder stopped (out of memory?)'),
    };
  }

  /// 7z and RAR up to [_inMemoryMax] decode in Dart. A bigger one, or one
  /// using a method the Dart decoders lack (BCJ2, RAR 1.5, VM filters), goes
  /// to 7-Zip from a temp file: no whole archive or solid folder in memory,
  /// LZMA2 on every core. Windows' 7zr reads 7z only, so RAR stays in Dart.
  Future<void> solid(Stream<List<int>> input, _Format format, String? password) async {
    final native = format == _Format.sevenzip || !io.Platform.isWindows;
    final acc = BytesBuilder(copy: false);
    final it = StreamIterator(input);
    var big = false;
    while (await it.moveNext()) {
      acc.add(it.current);
      if (native && acc.length > _inMemoryMax) {
        big = true;
        break;
      }
    }
    if (big) {
      final head = acc.takeBytes();
      Stream<List<int>> all() async* {
        yield head;
        while (await it.moveNext()) {
          yield it.current;
        }
      }

      return _native(all(), password);
    }
    final bytes = acc.takeBytes();
    try {
      _modes.addAll(await _isolated(_unpackJob(bytes, format, password, tmp.path)));
    } on ContentException catch (e) {
      if (!native || !e.message.startsWith('unsupported')) rethrow;
      // Start over clean: the Dart decoder may have landed some members.
      await tmp.delete(recursive: true);
      _modes.clear();
      _links.clear();
      _folded.clear();
      _written.clear();
      await start();
      await _native(Stream.value(bytes), password);
    }
  }

  /// [input] through 7-Zip: staged inside the temp tree, then every entry
  /// is sandbox-checked and moved in exactly as the Dart decoders' are.
  Future<void> _native(Stream<List<int>> input, String? password) async {
    final stage = io.Directory(p.join(tmp.path, _stageName));
    final out = p.join(stage.path, 'out');
    try {
      await io.Directory(out).create(recursive: true);
      final src = io.File(p.join(stage.path, 'in'));
      final sink = src.openWrite();
      try {
        await sink.addStream(input);
      } finally {
        await sink.close();
      }
      final exe = await tool(Tool.sevenzip);
      // A password goes on stdin, never in the process list; without one a
      // bare `-p` (the empty password) keeps 7-Zip from asking.
      final unpack = Shell.filter([exe, 'x', '-y', '-bso0', '-bsp0', if (password == null) '-p', '-o$out', src.path]);
      final done = Completer<void>();
      final sub = unpack
          .transform(Stream.value(password == null ? const <int>[] : utf8.encode('$password\n')))
          .listen(
            null,
            onError: (Object e, StackTrace st) {
              if (!done.isCompleted) done.completeError(e, st);
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
            cancelOnError: true,
          );
      final cancel = _cancel = Completer<void>();
      unawaited(
        cancel.future.then((_) async {
          await sub.cancel(); // kills 7-Zip and what it started
          if (!done.isCompleted) done.completeError(const ContentException('corrupt archive: stopped'));
        }),
      );
      try {
        await done.future;
      } on io.ProcessException catch (e) {
        final err = e.message.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
        final why = err.isEmpty ? 'exit ${e.errorCode}' : err.sublist(err.length > 3 ? err.length - 3 : 0).join(' / ');
        throw ContentException(
          why.contains('Wrong password') ? 'wrong password or corrupt archive' : 'corrupt archive: $why',
        );
      } finally {
        _cancel = null;
      }
      // Listed first: moving entries out while listing would skip some.
      for (final e in await io.Directory(out).list(recursive: true, followLinks: false).toList()) {
        final name = p.relative(e.path, from: out).replaceAll('\\', '/');
        if (e is io.Link) {
          _checkMember(name, _folded);
          _links.add((name: name, target: (await e.target()).replaceAll('\\', '/'), hard: false));
        } else if (e is io.Directory) {
          final d = await _prepare(name);
          if (d != null) await io.Directory(d).create(recursive: true);
        } else if (e is io.File) {
          final dest = await _prepare(name, file: true);
          if (dest != null) await e.rename(dest);
        }
      }
    } finally {
      _cancel = null;
      if (await stage.exists()) await stage.delete(recursive: true);
    }
    _modes.addAll(_placeLinks(tmp.path, _links, _modes));
  }

  /// Completes to stop a running 7-Zip.
  Completer<void>? _cancel;

  /// Stops the decoding isolate, if any, and waits until it is gone.
  Future<void> stop() async {
    final c = _cancel;
    if (c != null && !c.isCompleted) c.complete();
    final w = _worker;
    if (w == null) return;
    w.kill(priority: Isolate.immediate);
    await _workerGone?.timeout(const Duration(seconds: 2), onTimeout: () => null);
  }

  /// Stream tar events to the temp tree.
  Future<void> tar(Stream<_TarEvent> events) async {
    String? dest;
    var mode = 0;
    DateTime? mtime;
    // macOS tar adds an AppleDouble `._name` (xattrs) beside members; one
    // is decided on its first 4 bytes (however they are chunked) and
    // dropped, as bsdtar does.
    String? appleDouble;
    final head = <int>[];
    var skipping = false;
    Future<void> open(String name) async {
      dest = await _prepare(name, file: true);
      if (dest != null) _out = await io.File(dest!).open(mode: io.FileMode.write);
    }

    await for (final ev in events) {
      switch (ev) {
        case _TarHeader(kind: _Kind.symlink || _Kind.hardlink):
          _checkMember(ev.name, _folded);
          _links.add((name: ev.name, target: ev.link, hard: ev.kind == _Kind.hardlink));
        case _TarHeader():
          mode = ev.mode;
          mtime = ev.mtime;
          skipping = false;
          dest = null;
          if (ev.kind == _Kind.dir) {
            final d = await _prepare(ev.name);
            if (d == null) break;
            await io.Directory(d).create(recursive: true);
            _modes.add((d, mode, true));
          } else if (p.posix.basename(ev.name).startsWith('._')) {
            appleDouble = ev.name;
            head.clear();
          } else {
            await open(ev.name);
          }
        case _TarBody() when skipping:
          break;
        case _TarBody():
          final pending = appleDouble;
          if (pending == null) {
            await _out?.writeFrom(ev.bytes);
            break;
          }
          head.addAll(ev.bytes);
          if (head.length < 4) break;
          appleDouble = null;
          if (_isAppleDouble(head)) {
            skipping = true;
            break;
          }
          await open(pending);
          await _out?.writeFrom(head);
        case _TarEnd():
          final pending = appleDouble;
          if (pending != null) {
            appleDouble = null;
            await open(pending);
            await _out?.writeFrom(head);
          }
          await _out?.close();
          _out = null;
          final d = dest;
          if (d != null) {
            _modes.add((d, mode, false));
            final t = mtime;
            if (t != null) await io.File(d).setLastModified(t);
          }
          dest = null;
      }
    }
    _modes.addAll(_placeLinks(tmp.path, _links, _modes));
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
    final existing = await _checkCollisions(tmp.path, d);
    // Modes go through the umask like `tar` does. File modes go on in the
    // temp tree, so a file is never in the target with looser ones (a
    // rename keeps them); a file kept from the target drops its member and
    // is never re-moded.
    final mask = ~_umask & 0x1FF;
    final files = <String>[], fileModes = <int>[];
    final dirs = <String>[], dirModes = <int>[];
    for (final (path, mode, isDir) in _modes) {
      var m = mode & 0x1FF;
      if (m == 0) continue;
      if (isDir) {
        // Folder modes go on after the merge (a read-only member folder
        // would refuse the merge's renames), only on folders this unpack
        // made; never leave one untraversable (S_IXUSR).
        final at = p.join(d, p.relative(path, from: tmp.path));
        if (existing.contains(at)) continue;
        dirs.add(at);
        dirModes.add((m | 0x40) & mask);
      } else {
        files.add(path);
        fileModes.add(m & mask);
      }
    }
    await posix.chmodBatched(posix.groupByMode(files, fileModes));
    await io.Directory(d).create(recursive: true);
    await for (final e in tmp.list(recursive: false, followLinks: false)) {
      await _moveInto(e.path, p.join(d, p.basename(e.path)));
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
      switch (srcType) {
        case io.FileSystemEntityType.directory:
          await io.Directory(src).rename(dest);
        case io.FileSystemEntityType.link:
          await io.Link(src).rename(dest);
        default:
          await io.File(src).rename(dest);
      }
    } on io.FileSystemException catch (e) {
      // Only a rename across devices copies then deletes; anything else
      // (permissions) is the caller's error, not a reason to copy.
      if (!posix.isCrossDevice(e)) rethrow;
      switch (srcType) {
        case io.FileSystemEntityType.directory:
          await tree.copyTree(src, dest);
          await io.Directory(src).delete(recursive: true);
        case io.FileSystemEntityType.link:
          await io.Link(dest).create(await io.Link(src).target());
          await io.Link(src).delete();
        default:
          await io.File(src).copy(dest);
          await tree.preserveFileMeta(src, dest);
          await io.File(src).delete();
      }
    }
  }
}

/// The isolate side of [_Extraction._isolated]: the result as a 1-record,
/// a failure as (error, stack).
Future<void> _isolateMain((FutureOr<Object?> Function(), SendPort) m) async {
  final (work, reply) = m;
  Object? message;
  try {
    message = (await work(),);
  } catch (e, st) {
    message = (e, '$st');
  }
  try {
    Isolate.exit(reply, message);
  } catch (_) {
    // An error that cannot cross isolates goes as its text, keeping its kind.
    Isolate.exit(reply, switch (message) {
      (final ContentException e, final String st) => (ContentException(e.message), st),
      (final Object e, final String st) => (StateError('$e'), st),
      _ => (StateError('the archive decoder result cannot cross isolates'), ''),
    });
  }
}

/// A job for [_Extraction._isolated] capturing only what it needs.
_Modes Function() _unpackJob(Uint8List bytes, _Format format, String? password, String tmp) =>
    () => _unpackBytes(bytes, format, password, tmp);

/// Unpacks the zip, 7z or RAR in [bytes] into [tmp] (runs on the worker
/// isolate): every name and link is checked first, then each member is
/// decoded and written in turn (any damage it hits named after it), links
/// last. Returns the modes to set.
_Modes _unpackBytes(Uint8List bytes, _Format format, String? password, String tmp) {
  final entries = _entries(bytes, format, password);
  final folded = <String, String>{};
  final links = <_Link>[];
  for (final e in entries) {
    _checkMember(e.name, folded);
    if (e.kind == _Kind.symlink || e.kind == _Kind.hardlink) {
      final target = utf8.decode(_guard(e.name, e.data), allowMalformed: true);
      links.add((name: e.name, target: target, hard: e.kind == _Kind.hardlink));
    }
  }
  final modes = <(String, int, bool)>[];
  final written = <String>{};
  final made = <String>{tmp};
  for (final e in entries) {
    if (e.kind == _Kind.symlink || e.kind == _Kind.hardlink) continue;
    final dest = _dest(tmp, e.name);
    if (dest == null) continue;
    final parent = p.dirname(dest);
    if (made.add(parent)) io.Directory(parent).createSync(recursive: true);
    if (e.kind == _Kind.dir) {
      if (made.add(dest)) io.Directory(dest).createSync(recursive: true);
      modes.add((dest, e.mode, true));
      continue;
    }
    if (written.add(dest) && io.File(dest).existsSync()) {
      throw ContentException('archive members collide on this filesystem: ${e.name}');
    }
    io.File(dest).writeAsBytesSync(_guard(e.name, e.data));
    final t = e.mtime;
    if (t != null) io.File(dest).setLastModifiedSync(t);
    modes.add((dest, e.mode, false));
  }
  modes.addAll(_placeLinks(tmp, links, modes));
  return modes;
}

/// The members of the [format] archive in [b]; damage in the directory
/// names the archive.
List<_Entry> _entries(Uint8List b, _Format format, String? pw) {
  _Kind kind({required bool dir, bool link = false, bool hard = false}) =>
      dir ? _Kind.dir : (link ? (hard ? _Kind.hardlink : _Kind.symlink) : _Kind.file);
  switch (format) {
    case _Format.zip:
      return _guard(
        'zip',
        () => [
          for (final f in zip.readZip(b))
            (
              name: f.name,
              mode: f.mode,
              kind: kind(dir: f.isDir, link: f.isLink),
              mtime: f.mtime,
              data: () => f.data(password: pw),
            ),
        ],
      );
    case _Format.sevenzip:
      return _guard(
        '7z',
        () => [
          for (final e in sevenzip.readSevenzip(b, password: pw))
            (name: e.name, mode: e.mode, kind: kind(dir: e.isDir, link: e.isLink), mtime: e.mtime, data: e.data),
        ],
      );
    case _Format.rar:
      return _guard(
        'RAR',
        () => [
          for (final e in rarlib.readRar(b, password: pw))
            (
              name: e.name,
              mode: e.mode,
              kind: kind(dir: e.isDir, link: e.isLink, hard: e.isHardLink),
              mtime: e.mtime,
              data: e.data,
            ),
        ],
      );
    default:
      throw StateError('$format is streamed');
  }
}

/// [name]'s path inside [tmp]; null for a bare root entry. Split on both
/// separators so member names work on every platform; '.' segments name
/// nothing (a '.' member is the target itself, whose mode an archive never
/// sets).
String? _dest(String tmp, String name) {
  final parts = _parts(name);
  return parts.isEmpty ? null : p.joinAll([tmp, ...parts]);
}

/// A member path's segments, without empty and '.' ones.
List<String> _parts(String path) => [
  for (final s in path.replaceAll('\\', '/').split('/'))
    if (s.isNotEmpty && s != '.') s,
];

/// An absolute path on any OS: `/x`, `\x`, `C:`.
bool _absolute(String path) => path.startsWith('/') || path.startsWith('\\') || RegExp(r'^[A-Za-z]:').hasMatch(path);

/// The member path [parts] lead to from the root, following every symlink
/// of the archive ([symlinks], name to target) on the way, as the OS would
/// once they exist; null when the walk leaves the root or loops.
List<String>? _resolve(List<String> parts, Map<String, String> symlinks, [int depth = 0]) {
  final at = <String>[];
  for (final s in parts) {
    if (s == '..') {
      if (at.isEmpty) return null;
      at.removeLast();
      continue;
    }
    at.add(s);
    final target = symlinks[at.join('/')];
    if (target == null) continue;
    if (depth >= 32 || _absolute(target)) return null;
    at.removeLast();
    final to = _resolve([...at, ..._parts(target)], symlinks, depth + 1);
    if (to == null) return null;
    at
      ..clear()
      ..addAll(to);
  }
  return at;
}

/// Puts [links] into [tmp], where every other member already is. A
/// symlink must resolve inside the root through the archive's own links
/// (its target is kept as written); a hardlink must name a file of the
/// archive and lands as a copy of it, with its mode ([modes]) and mtime.
/// Anything else fails by name before the first link is made. A link never
/// replaces a member, and nothing is placed through a link. Returns the
/// modes of the copies. Shared by every format, and by any extractor that
/// fills [tmp] itself.
_Modes _placeLinks(String tmp, List<_Link> links, _Modes modes) {
  if (links.isEmpty) return const [];
  final symlinks = {
    for (final l in links)
      if (!l.hard) _parts(l.name).join('/'): l.target,
  };
  final out = <(String, int, bool)>[];
  final planned = <(_Link, String, List<String>)>[];
  for (final l in links) {
    final at = _parts(l.name);
    if (at.isEmpty) throw ContentException('archive link has no name: ${l.name}');
    final to = _absolute(l.target)
        ? null
        : _resolve(l.hard ? _parts(l.target) : [...at.sublist(0, at.length - 1), ..._parts(l.target)], symlinks);
    if (to == null) throw ContentException('archive link points outside the folder: ${l.name} -> ${l.target}');
    planned.add((l, p.joinAll([tmp, ...at]), to));
  }
  final modeOf = {
    for (final (path, mode, isDir) in modes)
      if (!isDir) path: mode,
  };
  bool throughLink(String dest) {
    for (var d = p.dirname(dest); d.length > tmp.length; d = p.dirname(d)) {
      if (io.FileSystemEntity.typeSync(d, followLinks: false) == io.FileSystemEntityType.link) return true;
    }
    return false;
  }

  // Copies first (their sources are plain files), then the symlinks.
  for (final hard in [true, false]) {
    for (final (l, dest, to) in planned) {
      if (l.hard != hard) continue;
      final type = io.FileSystemEntity.typeSync(dest, followLinks: false);
      if (type == io.FileSystemEntityType.link && !hard) {
        io.Link(dest).deleteSync(); // a repeated link member: the last one wins
      } else if (type != io.FileSystemEntityType.notFound || throughLink(dest)) {
        throw ContentException('archive link collides with a member: ${l.name}');
      }
      io.Directory(p.dirname(dest)).createSync(recursive: true);
      if (!hard) {
        io.Link(dest).createSync(l.target);
        continue;
      }
      final src = p.joinAll([tmp, ...to]);
      if (io.FileSystemEntity.typeSync(src, followLinks: false) != io.FileSystemEntityType.file) {
        throw ContentException('archive hardlink target is not a file of the archive: ${l.name} -> ${l.target}');
      }
      io.File(src).copySync(dest);
      io.File(dest).setLastModifiedSync(io.File(src).lastModifiedSync());
      out.add((dest, modeOf[src] ?? 0, false));
    }
  }
  return out;
}

final _badPart = RegExp(r'[<>:"|?*\x00-\x1f]');
final _reserved = RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$', caseSensitive: false);

/// Rejects, on every OS, any name that would not extract the same way on
/// Linux, macOS and Windows: escapes, device names, characters and
/// trailing dots/spaces Windows rewrites, and members (or folders) that
/// differ only in case. [folded] remembers each path seen, case-folded.
void _checkMember(String name, Map<String, String> folded) {
  if (name.isEmpty) {
    throw const ContentException('archive member has an empty name');
  }
  if (_absolute(name)) {
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

/// What the magic bytes say an input is.
enum _Format {
  zip,
  sevenzip,
  rar,
  xz,
  gzip,
  tar,
  // Through 7-Zip (not on Windows, whose 7zr reads 7z only): compressed
  // tars streamed via its stdout, and containers it unpacks itself.
  bzip2,
  zstd,
  compress,
  lzma,
  cab,
  ar,
  xar,
}

/// 7-Zip's `-t` name for the streamed formats.
const _sevenzipType = {_Format.bzip2: 'bzip2', _Format.zstd: 'zstd', _Format.compress: 'Z', _Format.lzma: 'lzma'};

/// Formats this module does not read, by their magic bytes, so the error
/// names them instead of calling them a bad tar.
/// Formats 7-Zip reads for us, by magic.
const _viaSevenzip = <_Format, List<int>>{
  _Format.bzip2: [0x42, 0x5A, 0x68], // BZh
  _Format.zstd: [0x28, 0xB5, 0x2F, 0xFD],
  _Format.compress: [0x1F, 0x9D],
  _Format.lzma: [0x5D, 0x00, 0x00],
  _Format.cab: [0x4D, 0x53, 0x43, 0x46], // MSCF
  _Format.ar: [0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E, 0x0A], // !<arch>\n
  _Format.xar: [0x78, 0x61, 0x72, 0x21], // xar!
};

/// Formats nothing here reads, named in the error.
const _unsupported = <String, List<int>>{
  'lz4': [0x04, 0x22, 0x4D, 0x18],
  'lzip': [0x4C, 0x5A, 0x49, 0x50], // LZIP
};

/// The format of the input starting with [head] (its first 512 bytes, or
/// all of a shorter one). Anything else is a [ContentException] naming it
/// when it is known.
_Format _sniff(List<int> head) {
  bool starts(List<int> magic) {
    if (head.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (head[i] != magic[i]) return false;
    }
    return true;
  }

  if (starts(const [0x1F, 0x8B])) return _Format.gzip;
  if (starts(const [0x50, 0x4B])) return _Format.zip;
  if (starts(const [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) return _Format.sevenzip;
  if (starts(const [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) && head.length >= 7 && head[6] <= 1) return _Format.rar;
  if (starts(const [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])) return _Format.xz;
  for (final MapEntry(key: format, value: magic) in _viaSevenzip.entries) {
    if (!starts(magic)) continue;
    if (io.Platform.isWindows) throw ContentException('unsupported archive format on Windows: ${format.name}');
    return format;
  }
  for (final MapEntry(key: name, value: magic) in _unsupported.entries) {
    if (starts(magic)) {
      throw ContentException(
        'unsupported archive format: $name (zip, tar, tgz, .tar.xz/.bz2/.zst, 7z, RAR, cab, ar and xar are)',
      );
    }
  }
  // A tar opens with a checksummed header, or (empty) with zero blocks.
  if (head.length >= 512 && (_tarChecksumOk(head, 0) || head.every((b) => b == 0))) return _Format.tar;
  throw ContentException(
    head.length < 2 ? 'corrupt archive: unknown format' : 'unknown archive format (not zip, tar, gzip, xz, 7z or RAR)',
  );
}

final class _Unpacker with Writer {
  _Unpacker(this._dir, this._password);

  final String _dir;
  final String? _password;

  @override
  Future<void> consume(Stream<List<int>> input) async {
    // Sniff the format from the magic bytes without consuming them: peek
    // one tar block, then hand on the chunks as they came.
    final it = StreamIterator(input);
    try {
      final peeked = <List<int>>[];
      final head = <int>[];
      while (head.length < 512 && await it.moveNext()) {
        final c = it.current;
        peeked.add(c);
        head.addAll(c.take(512 - head.length));
      }
      Stream<List<int>> rest() async* {
        yield* Stream.fromIterable(peeked);
        peeked.clear();
        while (await it.moveNext()) {
          yield it.current;
        }
      }

      final format = _sniff(head);
      // Normalise the target; the temp folder is a SIBLING of the target,
      // never inside it. Use the absolute path so '.' (whose dirname is
      // '.') still gets a sibling outside itself.
      final d = p.normalize(_dir);
      final x = _Extraction(io.Directory(tree.tmpPath(p.normalize(p.absolute(d)))));
      // An interrupt skips `finally`: the exit hook stops the decoder, then
      // removes the temp folder.
      final token = exit.onExit(() async {
        await x.stop();
        try {
          await x.tmp.delete(recursive: true);
        } catch (_) {}
      });
      try {
        await x.start();
        switch (format) {
          case _Format.zip:
            await x.inMemory(rest(), format, _password);
          case _Format.sevenzip || _Format.rar:
            await x.solid(rest(), format, _password);
          case _Format.xz:
            await x.tar(_parseTar(_offloaded(rest(), xz.xzStream), container: 'xz'));
          case _Format.gzip:
            await x.tar(_parseTar(_gunzipChecked(rest(), tar: true), container: 'gzip'));
          case _Format.bzip2 || _Format.zstd || _Format.compress || _Format.lzma:
            final unpack = Shell.filter([await tool(Tool.sevenzip), 'x', '-si', '-so', '-t${_sevenzipType[format]}']);
            // Only 7-Zip's own failure means bad data: a source error (a
            // dropped connection) passes through for retry and resume.
            final tarBytes = unpack.transform(rest()).handleError((Object e) {
              final why = (e as io.ProcessException).message.trim().split('\n').last;
              throw ContentException('corrupt archive: ${format.name} data: $why', null, null, e);
            }, test: (e) => e is io.ProcessException);
            await x.tar(_parseTar(tarBytes, container: format.name));
          case _Format.cab || _Format.ar || _Format.xar:
            await x._native(rest(), _password);
          case _Format.tar:
            // Tar streams straight to the temp sibling: links, escapes and
            // truncation fail here, before the merge.
            await x.tar(_parseTar(rest()));
        }
        await x.merge(d);
      } finally {
        await x.stop();
        await x.dispose();
        exit.offExit(token);
      }
    } finally {
      await it.cancel();
    }
  }
}

/// [input] through [transform] on its own isolate, so a CPU-bound decoder
/// never stalls this one (Ctrl-C, redraws). The worker pulls input and
/// keeps a few outputs in flight: memory stays bounded whichever side is
/// slower. Cancelling the result stops it.
Stream<Uint8List> _offloaded(Stream<List<int>> input, Stream<Uint8List> Function(Stream<List<int>>) transform) async* {
  final port = ReceivePort();
  final source = StreamIterator(input);
  final worker = await Isolate.spawn(_offloadMain, (transform, port.sendPort), onExit: port.sendPort);
  SendPort? to;
  // Input is read beside the message loop, so outputs keep flowing while a
  // slow source is awaited; a read error comes round as the worker's would.
  var reads = Future<void>.value();
  void read() => reads = reads.then((_) async {
    try {
      to!.send(await source.moveNext() ? source.current : null);
    } catch (e, st) {
      port.sendPort.send((e, '$st'));
    }
  });
  try {
    await for (final m in port) {
      switch (m) {
        case SendPort():
          to = m;
        case 'more':
          read();
        case Uint8List():
          yield m;
          to!.send(true);
        case 'done':
          return;
        case (final Object e, final String stack):
          Error.throwWithStackTrace(e, StackTrace.fromString(stack));
        default:
          throw StateError('the archive decoder stopped (out of memory?)');
      }
    }
  } finally {
    port.close();
    worker.kill(priority: Isolate.immediate);
    await source.cancel();
  }
}

/// The worker side of [_offloaded]: two input chunks asked ahead, up to
/// four outputs in flight.
Future<void> _offloadMain((Stream<Uint8List> Function(Stream<List<int>>), SendPort) m) async {
  final (transform, reply) = m;
  final inbox = RawReceivePort();
  final queue = <List<int>?>[];
  var asked = 0, ended = false;
  Completer<void>? arrived, credit;
  var inFlight = 0;
  void ask() {
    while (!ended && asked + queue.length < 2) {
      asked++;
      reply.send('more');
    }
  }

  inbox.handler = (Object? msg) {
    if (msg == true) {
      inFlight--;
      credit?.complete();
      credit = null;
      return;
    }
    asked--;
    if (msg == null) ended = true;
    queue.add(msg as List<int>?);
    arrived?.complete();
    arrived = null;
  };
  reply.send(inbox.sendPort);
  Stream<List<int>> input() async* {
    while (true) {
      ask();
      while (queue.isEmpty) {
        await (arrived = Completer<void>()).future;
      }
      final got = queue.removeAt(0);
      if (got == null) return;
      yield got;
    }
  }

  try {
    await for (final out in transform(input())) {
      if (out.isEmpty) continue;
      while (inFlight >= 4) {
        await (credit = Completer<void>()).future;
      }
      inFlight++;
      reply.send(out);
    }
    reply.send('done');
  } catch (e, st) {
    try {
      reply.send((e, '$st'));
    } catch (_) {
      reply.send((e is ContentException ? ContentException(e.message) : StateError('$e'), '$st'));
    }
  } finally {
    inbox.close();
  }
}

// ---------------------------------------------------------------------------
// In-house streaming tar. Headers are 512 bytes; file data follows, padded
// to a 512 multiple; the archive ends at the first all-zero block (a clean
// EOF there counts too). Pax extended headers (`x`, and global `g`) and GNU
// long names and link names (`L`, `K`) override the header's; pax `mtime`
// overrides its seconds. Symlinks and hardlinks come out as headers for
// [_placeLinks].
// ---------------------------------------------------------------------------

/// AppleDouble magic: `00 05 16 07`.
bool _isAppleDouble(List<int> b) => b.length >= 4 && b[0] == 0 && b[1] == 5 && b[2] == 0x16 && b[3] == 7;

/// Tar typeflags we write and read.
const _tarFile = 0x30; // '0'
const _tarSymlink = 0x32; // '2'
const _tarDir = 0x35; // '5'

/// What [_parseTar] emits: a member header, its body in chunks (files
/// only), then the end of the member.
sealed class _TarEvent {}

final class _TarHeader extends _TarEvent {
  _TarHeader(this.name, this.mode, this.mtime, this.kind, [this.link = '']);
  final String name;
  final int mode;
  final DateTime? mtime;
  final _Kind kind;

  /// A link's target.
  final String link;
}

final class _TarBody extends _TarEvent {
  _TarBody(this.bytes);
  final Uint8List bytes;
}

final class _TarEnd extends _TarEvent {}

/// Header chunks for one member: an optional pax extended header when the
/// name needs more than ustar's split `prefix/name` can hold (or a [link]
/// target more than 100 bytes), then the 512-byte header itself.
List<List<int>> _tarHeader({
  required String name,
  required int size,
  required int mode,
  required DateTime mtime,
  required int typeflag,
  String link = '',
}) {
  final out = <List<int>>[];
  final records = <int>[];
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
      records.addAll(_paxRecord('path', name));
      headerName = _truncateUtf8(name, 100);
    }
  }
  if (utf8.encode(link).length > 100) records.addAll(_paxRecord('linkpath', link));
  if (records.isNotEmpty) {
    final padded = Uint8List((records.length + 511) ~/ 512 * 512);
    padded.setRange(0, records.length, records);
    out.add(
      _rawHeader(
        name: '././@PaxHeader',
        size: records.length,
        mode: 0,
        mtime: mtime,
        typeflag: 0x78, // 'x'
      ),
    );
    out.add(padded);
  }
  out.add(
    _rawHeader(
      name: headerName,
      size: size,
      mode: mode,
      mtime: mtime,
      typeflag: typeflag,
      prefix: prefix,
      link: _truncateUtf8(link, 100),
    ),
  );
  return out;
}

List<int> _rawHeader({
  required String name,
  required int size,
  required int mode,
  required DateTime mtime,
  required int typeflag,
  String prefix = '',
  String link = '',
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
  _writeField(buf, 157, 100, utf8.encode(link));
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
/// header or body at EOF or a bad checksum is a [ContentException]. When
/// [input] came out of a [container] (gzip, xz) that opens with no tar
/// header, the error says so.
Stream<_TarEvent> _parseTar(Stream<List<int>> input, {String? container}) async* {
  final head = BytesBuilder(copy: false);
  final metaBuf = BytesBuilder(copy: false);
  var remaining = 0; // body bytes still to come
  var pad = 0; // padding bytes still to skip
  var metaFlag = 0; // typeflag of the pax/GNU record being collected, else 0
  var emit = false; // forward the current body as events
  var seen = 0; // members yielded so far
  String? pendingPath; // pax `x` / GNU `L`: name override for the next entry
  String? globalPath; // pax `g`: name override for every following entry
  String? pendingLink; // pax `linkpath` / GNU `K`: link target for the next entry
  int? pendingSize; // pax `size`: size override for the next entry
  DateTime? pendingMtime; // pax `mtime`: for the next entry

  Never fail(String message, {bool notTar = false}) {
    // Data that decodes but opens with a bad header is not a tar at all.
    if (notTar && container != null && seen == 0) {
      throw ContentException('corrupt archive: $container data is not a tar archive');
    }
    throw ContentException(message);
  }

  void finishMeta() {
    final data = metaBuf.takeBytes();
    if (metaFlag == 0x78 || metaFlag == 0x67) {
      // Pax extended ('x') or global ('g') header: `path=` renames,
      // `linkpath=` is a link's target, `mtime=` (seconds, maybe
      // fractional) its time.
      final records = _parsePax(data);
      if (records.keys.any((k) => k.startsWith('GNU.sparse.'))) {
        throw ContentException('sparse tar member unsupported: ${records['GNU.sparse.name'] ?? records['path']}');
      }
      final linkpath = records['linkpath'];
      if (metaFlag == 0x78 && linkpath != null && linkpath.isNotEmpty) pendingLink = linkpath;
      final secs = double.tryParse(records['mtime'] ?? '');
      if (metaFlag == 0x78 && secs != null && secs.isFinite && secs.abs() < 8e12) {
        pendingMtime = DateTime.fromMillisecondsSinceEpoch((secs * 1000).round());
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
    } else if (metaFlag == 0x4c || metaFlag == 0x4b) {
      // GNU long name or link name: the data is the next entry's.
      var text = utf8.decode(data, allowMalformed: true);
      while (text.endsWith('\x00')) {
        text = text.substring(0, text.length - 1);
      }
      if (text.isEmpty) {
        // nothing to override
      } else if (metaFlag == 0x4c) {
        pendingPath = text;
      } else {
        pendingLink = text;
      }
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
        metaFlag = typeflag;
        emit = false;
        if (size == 0 && metaFlag != 0) finishMeta();
        continue;
      }
      var name = _tarString(h, 0, 100);
      final prefix = _tarString(h, 345, 155);
      if (prefix.isNotEmpty) name = '$prefix/$name';
      name = pendingPath ?? globalPath ?? name;
      final link = pendingLink ?? _tarString(h, 157, 100);
      final secs = _tarOctal(h, 136, 12);
      final mtime = pendingMtime ?? (secs > 0 ? DateTime.fromMillisecondsSinceEpoch(secs * 1000) : null);
      pendingPath = pendingLink = pendingMtime = null;
      // Old (V7) tars mark a folder with a regular type and a trailing '/';
      // '7' (contiguous file) is a regular file everywhere but on old
      // Masscomp systems.
      final regular = typeflag == 0x30 || typeflag == 0 || typeflag == 0x37;
      if (typeflag == 0x35 || regular && name.endsWith('/')) {
        seen++;
        emit = false;
        yield _TarHeader(name, _tarMode(h), mtime, _Kind.dir);
      } else if (regular) {
        seen++;
        emit = true;
        yield _TarHeader(name, _tarMode(h), mtime, _Kind.file);
        if (size == 0) yield _TarEnd();
      } else if (typeflag == 0x31 || typeflag == 0x32) {
        // A link's data, if any, is skipped.
        seen++;
        emit = false;
        yield _TarHeader(name, _tarMode(h), mtime, typeflag == 0x31 ? _Kind.hardlink : _Kind.symlink, link);
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
/// With [tar], zero bytes after the member (tape blocking, some writers'
/// padding) are dropped when zlib rejects them as a next member's header,
/// the bytes before them end in the member's size field, and the output is
/// a whole tar ending in its zero blocks; anywhere else they are data.
Stream<List<int>> _gunzipChecked(Stream<List<int>> input, {bool tar = false}) async* {
  final z = io.RawZLibFilter.inflateFilter(gzip: true);
  var compressed = 0;
  var held = 0; // trailing input zeros not yet fed
  var tail = <int>[]; // the last 8 input bytes fed
  var total = 0, zeroTail = 0; // output so far, and the zero run it ends in
  List<List<int>> drain({bool end = false}) {
    final out = <List<int>>[];
    for (List<int>? piece; (piece = z.processed(end: end)) != null;) {
      out.add(piece!);
      if (!tar) continue;
      var k = piece.length;
      while (k > 0 && piece[k - 1] == 0) {
        k--;
      }
      zeroTail = k == 0 ? zeroTail + piece.length : piece.length - k;
      total += piece.length;
    }
    return out;
  }

  List<List<int>> feed(List<int> bytes, int end) {
    z.process(bytes, 0, end);
    final out = drain();
    if (tar) {
      final all = [...tail, ...bytes.sublist(end < 8 ? 0 : end - 8, end)];
      tail = all.sublist(all.length < 8 ? 0 : all.length - 8);
    }
    return out;
  }

  // The member's last bytes are its size mod 2^32, little-endian; its zero
  // high bytes may sit among the zeros.
  bool endsInSize() {
    final size = [for (var k = 0; k < 4; k++) total >> (8 * k) & 0xFF];
    var n = 4;
    while (n > 0 && size[n - 1] == 0) {
      n--;
    }
    if (tail.length < n) return false;
    for (var k = 0; k < n; k++) {
      if (tail[tail.length - n + k] != size[k]) return false;
    }
    return true;
  }

  try {
    await for (final chunk in input) {
      if (chunk.isEmpty) continue;
      compressed += chunk.length;
      var end = chunk.length;
      if (tar) {
        while (end > 0 && chunk[end - 1] == 0) {
          end--;
        }
        if (end == 0) {
          held += chunk.length;
          continue;
        }
        if (held > 0) yield* Stream.fromIterable(feed(Uint8List(held), held));
        held = chunk.length - end;
      }
      yield* Stream.fromIterable(feed(chunk, end));
    }
    if (compressed == 0) throw const ContentException('bad gzip data: empty (not a gzip stream)');
    if (held > 0) {
      try {
        yield* Stream.fromIterable(feed(Uint8List(held), held));
      } on FormatException {
        // zlib read the zeros as the next member's header: padding, when
        // the member ended where they start and the tar before it is whole.
        if (zeroTail >= 1024 && total % 512 == 0 && endsInSize()) return;
        rethrow;
      }
    }
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
