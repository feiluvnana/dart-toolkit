/// Archives and gzip: zip, tar, gzip and xz in Dart, 7-Zip (downloaded once
/// on first use when PATH has none) for 7z writes and big or exotic reads.
///
/// | format | archive | unarchive |
/// |---|---|---|
/// | zip | ✓ (streamed, zip64; AES-256 with `password:`) | ✓ (AES, legacy ZipCrypto) |
/// | tar, tgz | ✓ (streamed) | ✓ (streamed; `.tar.xz` too) |
/// | 7z | ✓ (7-Zip: LZMA2; AES-256 hides names) | ✓ (LZMA, LZMA2, PPMd, Deflate, BCJ, AES) |
/// | RAR4, RAR5 | — (the compressor is proprietary) | ✓ (solid, filters, PPMd, AES) |
/// | `.tar.bz2` `.tar.zst` `.tar.Z` `.tar.lzma`, cab, ar, xar | — | ✓ (through 7-Zip) |
///
/// Unarchiving a zip, 7z or RAR up to 32 MiB holds it in memory (its
/// directory or solid stream needs it whole) and decodes on its own isolate
/// under a fixed budget; a bigger zip is spooled to a temp file and read a
/// member at a time, a bigger 7z/RAR goes to 7-Zip, which streams to disk. Tar, tgz and `.tar.xz` stream one member at a time
/// (xz decodes on its own isolate too). Ctrl-C and screen redraws stay
/// live either way. File modes and mtimes are kept; links are kept when
/// they point inside the folder.
///
/// ```dart
/// await (Archive.archive(['site', 'README.md']) > Fs.file('site.zip'));  // like zip -r
/// await (Archive.archive(['.'], dir: 'site', format: .tgz) > Fs.file('site.tgz')); // the contents, streamed
/// await (Archive.archive(['docs'], format: .sevenzip, password: pw) > Fs.file('docs.7z'));
/// await (http.get(url) > Archive.unarchive('vendor', password: pw)); // any format above
/// await (http.get(url) | Archive.gunzip() > Fs.file('dump.sql'));    // a truncated stream fails
/// final pkg = await (http.get(tgz) | Archive.member('package/package.json')).json();
/// ```
///
/// Public surface is exactly: [Archive], [ArchiveFormat].
/// - `Archive.archive()` is a [Reader] of the archive, `unarchive()` a [Writer].
/// - `Archive.gzip()`/`gunzip()` are streaming [Pipe]s; `member(name)` is a
///   [Pipe] to one member's bytes.
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

import 'shell.dart' show ExitException, Shell;
import 'src/exit.dart' as exit;
import 'src/format.dart' show Unit;
import 'src/glob.dart';
import 'src/posix.dart' as posix;
import 'src/progress.dart' show Run, working, writing;
import 'src/rar.dart' as rarlib;
import 'src/sevenzip.dart' as sevenzip;
import 'src/tool.dart';
import 'src/tree.dart' as tree;
import 'src/unpack.dart' as un;
import 'src/xz.dart' as xz;
import 'src/zip.dart' as zip;

part 'src/tar.dart';

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

  /// 7z, written by 7-Zip into a temp file (LZMA2 on every core; AES-256
  /// with the names hidden, with a password).
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
  /// merging into what is there: a member replaces a file (or link) at its
  /// path, like `unzip -o`, and other files stay. With [match] only the
  /// members whose path matches the glob land, read as `Dir.list(match:)`
  /// reads it (`'bin/*'`, `'**/*.so'`), with the folders above them. The format comes from the magic bytes; one this module
  /// cannot read (lz4, lzip, …) is named in the [ContentException].
  /// Symlinks and hardlinks are kept when they resolve inside [dir] (a
  /// hardlink lands as a copy); one that points outside fails by name.
  /// [password] opens encrypted archives (zip AES or legacy ZipCrypto, 7z
  /// AES, RAR4/RAR5); an encrypted member without it, or with the wrong one,
  /// is a [PasswordException] before anything lands in [dir]. [max] caps
  /// the bytes written (hardlink copies included): past it the unpack fails
  /// with a [ContentException] and nothing lands; a 7-Zip extraction (big
  /// 7z/RAR, cab, ar, xar) is counted as its output moves in.
  static Writer unarchive(String dir, {String? password, int? max, String? match}) {
    if (max != null && max < 0) throw ArgumentError.value(max, 'max', 'must not be negative');
    return _Unpacker(dir, password, max, match == null ? null : glob(match));
  }

  /// A [Pipe] from an archive stream to the bytes of its member at the path
  /// [name] (`'package/package.json'`; a leading `./` is ignored), so one
  /// file is read without unpacking the rest:
  /// `(http.get(u) | Archive.member('package/package.json')).json()`. A tar
  /// (also gzipped, xz…) streams, stops at the member's end and takes the
  /// first member at that path; zip, 7z and RAR decode only that member. No
  /// such member, or a folder or link there, is a [ContentException].
  static Pipe member(String name) => _MemberPipe(name);

  /// Streaming gzip compression.
  static Pipe gzip() => _GzipPipe(compress: true);

  /// Streaming gzip decompression. Bad or truncated data fails the run with
  /// a [ContentException].
  static Pipe gunzip() => _GzipPipe(compress: false);
}

/// One member to pack: its name in the archive, where it is, whether it is
/// a folder, and a link's target.
typedef _Member = ({String name, String path, bool dir, String? link});

/// Archives bigger than this (7z, RAR) go to 7-Zip instead of memory.
const _inMemoryMax = 32 << 20;

/// 7-Zip's staging folder inside the temp tree; removed before the merge.
const _stageName = '.dart_toolkit_7z~';

final class _Packed with Reader {
  _Packed(this._paths, this._from, this._format, this._password) {
    working[this] = _pack;
  }

  final List<String> _paths;
  final String _from;
  final ArchiveFormat _format;
  final String? _password;

  /// `archive.zip`, `archive.tgz` …: the name a multipart part takes.
  @override
  Origin origin() => Origin(name: 'archive.${_format == ArchiveFormat.sevenzip ? '7z' : _format.name}');

  @override
  Stream<List<int>> stream() => _pack(null);

  /// Watched, a probe hears the input bytes packed against the total input
  /// size: the archive's own bytes say nothing about how far it is.
  Stream<List<int>> _pack(Run? run) async* {
    final members = await _members();
    void Function(int bytes)? packed;
    void Function(int pct)? percent;
    if (run != null) {
      var total = 0, done = 0;
      for (final m in members) {
        if (!m.dir && m.link == null) total += (await _stat(m)).$2;
      }
      run.report(0, total, Unit.bytes);
      packed = (n) => run.report(done = done + n > total ? total : done + n, total, Unit.bytes);
      percent = (pct) => run.report(total * pct ~/ 100, total, Unit.bytes);
    }
    switch (_format) {
      case ArchiveFormat.zip:
        yield* zip.zipStream(_zipSources(members, packed), password: _password);
      case ArchiveFormat.sevenzip:
        yield* _sevenzip(members, percent);
      case ArchiveFormat.tar:
        yield* _tarStream(members, packed);
      case ArchiveFormat.tgz:
        yield* _tarStream(members, packed).transform(io.gzip.encoder);
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
        if (un.absolute(target) || to != base && !p.isWithin(base, to)) {
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

  Stream<zip.ZipSource> _zipSources(List<_Member> members, void Function(int)? packed) async* {
    for (final m in members) {
      final (mode, size, mtime) = await _stat(m);
      yield (
        name: m.name,
        mode: mode,
        mtime: mtime,
        size: size,
        open: size == 0 ? null : () => _counted(io.File(m.path).openRead(0, size + 1), packed),
        link: m.link,
      );
    }
  }

  static Stream<List<int>> _counted(Stream<List<int>> bytes, void Function(int)? packed) =>
      packed == null ? bytes : bytes.map((c) {
        packed(c.length);
        return c;
      });

  /// 7-Zip writes it (LZMA2 on every core, links kept, AES with the
  /// names hidden when a password is set) into a temp file, since 7z's
  /// header sits after the data; then the file streams out. The members are
  /// ours: files, links and empty folders, so temps never slip in.
  Stream<List<int>> _sevenzip(List<_Member> members, void Function(int pct)? percent) async* {
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
    // A signal that ends the process skips `finally`: the exit hook
    // removes the work folder.
    final token = exit.onExit(() => work.delete(recursive: true).then((_) {}, onError: (_) {}));
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
        percent == null ? '-bsp0' : '-bsp1',
        '-y',
        if (pw != null) ...['-p', '-mhe=on'],
        out,
        '@$list',
      ], dir: base);
      try {
        final progress = make.transform(Stream.value(pw == null ? const <int>[] : utf8.encode('$pw\n$pw\n')));
        await (percent == null ? progress.drain<void>() : _percents(progress, percent));
      } on ExitException catch (e) {
        throw io.FileSystemException('7-Zip failed: ${e.message}', base);
      }
      yield* io.File(out).openRead();
    } finally {
      exit.offExit(token);
      await work.delete(recursive: true).catchError((_) => work);
    }
  }

  /// Streams a tar: one 512-byte header per member, file bytes straight
  /// from disk, two zero blocks at the end. Holds one member at a time,
  /// never the archive.
  Stream<List<int>> _tarStream(List<_Member> members, void Function(int)? packed) async* {
    for (final m in members) {
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
        packed?.call(chunk.length);
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
  _Extraction(this.tmp, int? max, this.match) : budget = un.Budget(max);

  final io.Directory tmp;

  /// The members to land (`match:`); null for all.
  final RegExp? match;

  /// What may still be written (`max:`).
  final un.Budget budget;

  // Modes collected during extraction: one `chmod <mode> p1 p2 …` per
  // distinct mode afterwards (usually 2–3 forks per archive, not one per
  // member), chunked under ARG_MAX inside `chmodBatched`.
  final _modes = <(String, int, bool)>[];
  final _folded = <String, String>{};
  final _links = <un.Link>[];

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
    un.checkMember(name, _folded);
    final dest = un.destIn(tmp.path, name);
    if (dest == null) return null;
    await io.Directory(p.dirname(dest)).create(recursive: true);
    if (file && _written.add(dest) && await io.File(dest).exists()) {
      throw ContentException('archive members collide on this filesystem: $name');
    }
    return dest;
  }

  /// A zip up to [_inMemoryMax] stays in memory (its directory sits at the
  /// end); a bigger one is spooled to a file in the temp tree and read by
  /// offset, a member at a time. It decodes and lands in the temp tree on
  /// its own isolate.
  Future<void> unzip(Stream<List<int>> input, String? password) async {
    final head = <List<int>>[];
    var held = 0;
    final it = StreamIterator(input);
    while (await it.moveNext()) {
      head.add(it.current);
      held += it.current.length;
      if (held <= _inMemoryMax) continue;
      final stage = io.Directory(p.join(tmp.path, _stageName));
      try {
        final spool = io.File(p.join(stage.path, 'in'));
        await spool.create(recursive: true);
        Stream<List<int>> all() async* {
          yield* Stream.fromIterable(head);
          head.clear();
          while (await it.moveNext()) {
            yield it.current;
          }
        }

        await posix.writeAll(spool, all());
        _modes.addAll(await _isolated(_unzipFileJob(spool.path, password, tmp.path, budget.max, match)));
      } finally {
        if (await stage.exists()) await stage.delete(recursive: true);
      }
      return;
    }
    final acc = BytesBuilder(copy: false);
    head.forEach(acc.add);
    _modes.addAll(await _isolated(_unpackJob(acc.takeBytes(), _Format.zip, password, tmp.path, budget.max, match)));
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
      _modes.addAll(await _isolated(_unpackJob(bytes, format, password, tmp.path, budget.max, match)));
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
      await posix.writeAll(src, input);
      final exe = await tool(Tool.sevenzip);
      final run = this.run;
      // Watched: the extraction itself, as 7-Zip's percent of the archive.
      final size = run == null ? 0 : await src.length();
      final heard = _Percents((pct) => run?.report(size * pct ~/ 100, size, Unit.bytes));
      // A password goes on stdin, never in the process list; without one a
      // bare `-p` (the empty password) keeps 7-Zip from asking.
      final unpack = Shell.filter([
        exe,
        'x',
        '-y',
        '-bso0',
        run == null ? '-bsp0' : '-bsp1',
        if (password == null) '-p',
        '-o$out',
        src.path,
      ]);
      final done = Completer<void>();
      final sub = unpack
          .transform(Stream.value(password == null ? const <int>[] : utf8.encode('$password\n')))
          .listen(
            run == null ? null : heard.add,
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
      } on ExitException catch (e) {
        throw sevenZipFailure(e.message);
      } finally {
        _cancel = null;
      }
      // Listed first: moving entries out while listing would skip some.
      for (final e in await io.Directory(out).list(recursive: true, followLinks: false).toList()) {
        final name = p.relative(e.path, from: out).replaceAll('\\', '/');
        if (e is io.Link) {
          un.checkMember(name, _folded);
          _links.add((name: name, target: (await e.target()).replaceAll('\\', '/'), hard: false));
        } else if (e is io.Directory) {
          final d = await _prepare(name);
          if (d != null) await io.Directory(d).create(recursive: true);
        } else if (e is io.File) {
          final dest = await _prepare(name, file: true);
          if (dest == null) continue;
          budget.take(await e.length(), name);
          await e.rename(dest);
        }
      }
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
    _modes.addAll(un.placeLinks(tmp.path, _links, _modes, budget));
  }

  /// Completes to stop a running 7-Zip.
  Completer<void>? _cancel;

  /// The watched run this unpack reports its own work to, if any.
  Run? run;

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
        case _TarHeader(kind: un.Kind.symlink || un.Kind.hardlink):
          un.checkMember(ev.name, _folded);
          _links.add((name: ev.name, target: ev.link, hard: ev.kind == un.Kind.hardlink));
        case _TarHeader():
          mode = ev.mode;
          mtime = ev.mtime;
          skipping = false;
          dest = null;
          if (ev.kind == un.Kind.dir) {
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
            if (dest case final d?) budget.take(ev.bytes.length, d);
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
          budget.take(head.length, pending);
          await _out?.writeFrom(head);
        case _TarEnd():
          final pending = appleDouble;
          if (pending != null) {
            appleDouble = null;
            await open(pending);
            budget.take(head.length, pending);
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
    _modes.addAll(un.placeLinks(tmp.path, _links, _modes, budget));
  }

  /// Never delete the target: create it and merge each top-level
  /// member in (rename, copy fallback). A member replaces a file or link
  /// at its path (renamed over it, never written through it). Every
  /// file/folder collision fails before the first rename, so a failed
  /// unpack leaves the target as it was.
  Future<void> merge(String d) async {
    if (match != null) await _prune();
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

  /// Drop from the temp tree what [match] leaves out: files and links that
  /// do not match, then folders that neither match nor hold a member.
  Future<void> _prune() async {
    final pattern = match!;
    final dirs = <String>[];
    final gone = <String>{};
    for (final e in await tmp.list(recursive: true, followLinks: false).toList()) {
      final rel = p.relative(e.path, from: tmp.path).replaceAll('\\', '/');
      if (pattern.hasMatch(rel)) continue;
      if (e is io.Directory) {
        dirs.add(e.path);
      } else {
        await e.delete();
        gone.add(e.path);
      }
    }
    // Deepest first, so a folder emptied by its children goes too.
    dirs.sort((a, b) => b.length.compareTo(a.length));
    for (final dir in dirs) {
      if (await io.Directory(dir).list().isEmpty) {
        await io.Directory(dir).delete();
        gone.add(dir);
      }
    }
    _modes.removeWhere((m) => gone.contains(m.$1));
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
  /// target paths that already exist (folders there keep their modes).
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
  /// merging folders; a file or link member replaces a file or link there.
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
    if (destType != io.FileSystemEntityType.notFound && srcIsDir != destIsDir) {
      // Never delete on type collision: an archive file over an existing
      // dir (or vice versa) throws instead of rm -rf.
      throw io.FileSystemException('archive member collides with existing ${destIsDir ? 'directory' : 'file'}', dest);
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
      if (srcType == io.FileSystemEntityType.directory) {
        await tree.copyTree(src, dest);
        await io.Directory(src).delete(recursive: true);
        return;
      }
      // Made beside [dest] on its device, then renamed over it: whatever was
      // there (a file, a link, a hard-linked inode) is replaced by name,
      // never written through.
      final next = tree.tmpPath(dest);
      try {
        if (srcType == io.FileSystemEntityType.link) {
          await io.Link(next).create(await io.Link(src).target());
          await io.Link(next).rename(dest);
          await io.Link(src).delete();
        } else {
          await io.File(src).copy(next);
          await tree.preserveFileMeta(src, next);
          await io.File(next).rename(dest);
          await io.File(src).delete();
        }
      } catch (_) {
        if (srcType == io.FileSystemEntityType.link) {
          await io.Link(next).delete().catchError((_) => io.Link(next));
        } else {
          await io.File(next).delete().catchError((_) => io.File(next));
        }
        rethrow;
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
un.Modes Function() _unpackJob(Uint8List bytes, _Format format, String? password, String tmp, int? max, RegExp? match) =>
    () => un.unpackEntries(_entries(bytes, format, password), tmp, un.Budget(max), match);

/// A job unpacking the zip spooled at [path], read by offset.
un.Modes Function() _unzipFileJob(String path, String? password, String tmp, int? max, RegExp? match) => () {
  final f = io.File(path).openSync();
  try {
    Uint8List read(int at, int n) {
      f.setPositionSync(at);
      final out = Uint8List(n);
      var got = 0;
      for (int r; got < n && (r = f.readIntoSync(out, got)) > 0;) {
        got += r;
      }
      return got == n ? out : Uint8List.sublistView(out, 0, got);
    }

    return un.unpackEntries(
      _zipEntries(() => zip.readZipAt(f.lengthSync(), read), password),
      tmp,
      un.Budget(max),
      match,
    );
  } finally {
    f.closeSync();
  }
};

/// [members] (a zip's, read lazily) as entries; damage in the directory
/// names the archive.
List<un.Entry> _zipEntries(List<zip.ZipEntry> Function() members, String? pw) => un.guard(
  'zip',
  () => [
    for (final f in members())
      (
        name: f.name,
        mode: f.mode,
        kind: f.isDir ? un.Kind.dir : (f.isLink ? un.Kind.symlink : un.Kind.file),
        mtime: f.mtime,
        data: () => f.data(password: pw),
      ),
  ],
);

/// The members of the [format] archive in [b]; damage in the directory
/// names the archive.
List<un.Entry> _entries(Uint8List b, _Format format, String? pw) {
  un.Kind kind({required bool dir, bool link = false, bool hard = false}) =>
      dir ? un.Kind.dir : (link ? (hard ? un.Kind.hardlink : un.Kind.symlink) : un.Kind.file);
  switch (format) {
    case _Format.zip:
      return _zipEntries(() => zip.readZip(b), pw);
    case _Format.sevenzip:
      return un.guard(
        '7z',
        () => [
          for (final e in sevenzip.readSevenzip(b, password: pw))
            (name: e.name, mode: e.mode, kind: kind(dir: e.isDir, link: e.isLink), mtime: e.mtime, data: e.data),
        ],
      );
    case _Format.rar:
      return un.guard(
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
  _Unpacker(this._dir, this._password, this._max, this._match) {
    writing[this] = _consume;
  }

  final String _dir;
  final String? _password;
  final int? _max;
  final RegExp? _match;

  @override
  Future<void> consume(Stream<List<int>> input) => _consume(input, null);

  /// Watched, an archive 7-Zip extracts after reading it reports that
  /// extraction too.
  Future<void> _consume(Stream<List<int>> input, Run? run) async {
    // Ctrl-C fails an unpack in flight, so its temp folder goes.
    final it = StreamIterator(exit.guard(input));
    try {
      final (format, rest) = await _sniffed(it);
      // Normalise the target; the temp folder is a SIBLING of the target,
      // never inside it. Use the absolute path so '.' (whose dirname is
      // '.') still gets a sibling outside itself.
      final d = p.normalize(_dir);
      final x = _Extraction(io.Directory(tree.tmpPath(p.normalize(p.absolute(d)))), _max, _match)..run = run;
      // A signal that ends the process skips `finally`: the exit hook stops
      // the decoder, then removes the temp folder.
      final token = exit.onExit(() async {
        await x.stop();
        try {
          await x.tmp.delete(recursive: true);
        } catch (_) {}
      });
      // Ctrl-C stops the decoder (its input may be read already) and fails
      // the unpack before anything lands.
      var stopped = false;
      final stop = exit.onInterrupt(() {
        stopped = true;
        unawaited(x.stop());
      });
      try {
        await x.start();
        switch (format) {
          case _Format.zip:
            await x.unzip(rest, _password);
          case _Format.sevenzip || _Format.rar:
            await x.solid(rest, format, _password);
          case _Format.cab || _Format.ar || _Format.xar:
            await x._native(rest, _password);
          default:
            // Tar streams straight to the temp sibling: links, escapes and
            // truncation fail here, before the merge.
            await x.tar(await _tarEvents(format, rest));
        }
        if (stopped) throw const InterruptedException();
        await x.merge(d);
      } on Object {
        if (stopped) throw const InterruptedException();
        rethrow;
      } finally {
        exit.offInterrupt(stop);
        await x.stop();
        await x.dispose();
        exit.offExit(token);
      }
    } finally {
      await it.cancel();
    }
  }
}

/// The format of what [it] reads, sniffed from its magic bytes without
/// consuming them (one tar block is peeked), and every byte again.
Future<(_Format, Stream<List<int>>)> _sniffed(StreamIterator<List<int>> it) async {
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

  return (_sniff(head), rest());
}

/// The tar inside [bytes] of a tar-family [format] (tar, gzip, xz, and
/// bzip2/zstd/compress/lzma through 7-Zip) as events.
Future<Stream<_TarEvent>> _tarEvents(_Format format, Stream<List<int>> bytes) async {
  switch (format) {
    case _Format.xz:
      return _parseTar(_offloaded(bytes, xz.xzStream), container: 'xz');
    case _Format.gzip:
      return _parseTar(_gunzipChecked(bytes, tar: true), container: 'gzip');
    case _Format.bzip2 || _Format.zstd || _Format.compress || _Format.lzma:
      final unpack = Shell.filter([await tool(Tool.sevenzip), 'x', '-si', '-so', '-t${_sevenzipType[format]}']);
      // Only 7-Zip's own failure means bad data: a source error (a
      // dropped connection) passes through for retry and resume.
      final tarBytes = unpack.transform(bytes).handleError((Object e) {
        final why = (e as ExitException).message.trim().split('\n').last;
        throw ContentException('corrupt archive: ${format.name} data: $why', null, null, e);
      }, test: (e) => e is ExitException);
      return _parseTar(tarBytes, container: format.name);
    case _Format.tar:
      return _parseTar(bytes);
    case _Format.zip || _Format.sevenzip || _Format.rar || _Format.cab || _Format.ar || _Format.xar:
      throw StateError('${format.name} is not a tar');
  }
}

/// [Archive.member]: one member's bytes out of an archive stream. A tar
/// (plain or compressed) streams, and stops reading once the member ends;
/// any other format lands just that member in a temp folder first.
final class _MemberPipe with Pipe {
  _MemberPipe(String name) : _path = un.segments(name).join('/') {
    if (_path.isEmpty) throw ArgumentError.value(name, 'name', 'must name a member');
  }

  final String _path;

  @override
  Stream<List<int>> transform(Stream<List<int>> input) async* {
    final it = StreamIterator(input);
    try {
      final (format, rest) = await _sniffed(it);
      switch (format) {
        case _Format.zip || _Format.sevenzip || _Format.rar || _Format.cab || _Format.ar || _Format.xar:
          yield* _landed(rest);
        default:
          yield* _streamed(await _tarEvents(format, rest));
      }
    } finally {
      await it.cancel();
    }
  }

  Stream<List<int>> _streamed(Stream<_TarEvent> events) async* {
    var inside = false;
    await for (final ev in events) {
      switch (ev) {
        case _TarHeader(:final name) when un.segments(name).join('/') == _path:
          if (ev.kind != un.Kind.file) throw ContentException(_notFile(ev.kind));
          inside = true;
        case _TarBody() when inside:
          yield ev.bytes;
        case _TarEnd() when inside:
          return; // the rest of the archive is never read
        default:
          break;
      }
    }
    throw ContentException(_missing);
  }

  Stream<List<int>> _landed(Stream<List<int>> bytes) async* {
    final tmp = await io.Directory.systemTemp.createTemp('dart_toolkit_member_');
    final token = exit.onExit(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    try {
      await _Unpacker(tmp.path, null, null, RegExp('^${RegExp.escape(_path)}\$')).consume(bytes);
      final file = p.joinAll([tmp.path, ..._path.split('/')]);
      switch (await io.FileSystemEntity.type(file, followLinks: false)) {
        case io.FileSystemEntityType.file:
          yield* io.File(file).openRead();
        case io.FileSystemEntityType.notFound:
          throw ContentException(_missing);
        case io.FileSystemEntityType.link:
          throw ContentException(_notFile(un.Kind.symlink));
        default:
          throw ContentException(_notFile(un.Kind.dir));
      }
    } finally {
      exit.offExit(token);
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  String get _missing => 'no member "$_path" in the archive';

  String _notFile(un.Kind kind) =>
      'member "$_path" is a ${kind == un.Kind.dir ? 'folder' : 'link'} in the archive, not a file';
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

/// 7-Zip's `-bsp1` progress (`  42% 3 - name`, redrawn with backspaces)
/// as percentages.
final class _Percents {
  _Percents(this._on);

  final void Function(int pct) _on;
  static final _pct = RegExp(r'(\d{1,3})%');

  void add(List<int> chunk) {
    final last = _pct.allMatches(latin1.decode(chunk, allowInvalid: true)).lastOrNull;
    if (last != null) _on(int.parse(last[1]!).clamp(0, 100));
  }
}

/// [output]'s percentages to [on], until it ends.
Future<void> _percents(Stream<List<int>> output, void Function(int pct) on) =>
    output.forEach(_Percents(on).add);
