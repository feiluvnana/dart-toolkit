part of '../../archive.dart';

/// An archive or compressed-stream format, as a destination's extension names it and as
/// [Archive.detect] reads it from a file's content. The order is the native library's code.
///
/// {@category Files}
enum ArchiveFormat {
  zip('.zip'),
  sevenZip('.7z'),
  tar('.tar'),
  tarGz('.tar.gz'),
  tarXz('.tar.xz'),
  tarZst('.tar.zst'),
  tarBz2('.tar.bz2'),

  /// Read only: an archive is never written as RAR.
  rar('.rar'),
  gz('.gz'),
  xz('.xz'),
  zst('.zst'),
  bz2('.bz2');

  final String extension;

  const ArchiveFormat(this.extension);

  /// Whether this is one compressed file rather than a container: gzip, xz, zstd, bzip2.
  bool get isStream => index >= gz.index;

  /// The format [path]'s name says, or `null`: `.tgz`, `.txz`, `.tzst` and `.tbz2` are their
  /// tar forms.
  static ArchiveFormat? of(String path) {
    final lower = path.toLowerCase();
    for (final (short, format) in const [('.tgz', tarGz), ('.txz', tarXz), ('.tzst', tarZst), ('.tbz2', tarBz2)]) {
      if (lower.endsWith(short)) return format;
    }
    // The tar forms before the streams they end in.
    for (final format in values) {
      if (lower.endsWith(format.extension)) return format;
    }
    return null;
  }
}

/// One entry of an archive.
///
/// {@category Files}
final class ArchiveEntry {
  /// The path inside the archive, `/`-separated; a folder ends in `/`.
  final String name;
  final int size;
  final int compressedSize;
  final bool isDir;
  final bool isEncrypted;
  final DateTime? modified;

  const ArchiveEntry({
    required this.name,
    required this.size,
    required this.compressedSize,
    required this.isDir,
    this.isEncrypted = false,
    this.modified,
  });

  @override
  String toString() => '$name ($size bytes)';
}

/// An archive read without extracting it: its [entries], one [entry]'s bytes, or all of them
/// in one pass with [contents].
///
/// ```dart
/// final archive = await Archive.read('x.zip');
/// for (final e in archive.entries) print(e);
/// final readme = await archive.entry('docs/readme.md');
/// await for (final (:entry, :bytes) in archive.contents(only: '*.jpg')) { … }
/// ```
///
/// {@category Files}
final class Archive {
  /// The archive's file.
  final Path path;

  /// Every entry, folders included, in archive order.
  final List<ArchiveEntry> entries;

  final Secret? _password;
  final bool _unsafe;

  Archive._(this.path, this.entries, this._password, this._unsafe);

  /// The archive at [path], listed on a worker isolate; its format is read from the file. A
  /// [password] opens an encrypted one; [unsafe] lifts the size cap reads are held to (200×
  /// the archive, at least 1 GiB). Nothing there is a [PathNotFoundException]; what is not an
  /// archive a [FormatException]; a wrong or missing password a [PasswordException].
  static Task<Archive> read(String path, {Secret? password, bool unsafe = false}) {
    final at = p.absolute(path);
    return TaskInternals.start(Path(path), FileBridge.label(path), (work) async {
      await _there(at);
      final pw = password?.reveal;
      final listed = await NativeBridge.main.run(work, _listCall(at, pw));
      return Archive._(Path(path), _entriesOf(listed), password, unsafe);
    });
  }

  /// The format of the file at [path], read from its content (a compressed stream's first
  /// block is decoded to tell a tarball), else from its name; `null` when it is neither. A
  /// missing file is a [PathNotFoundException].
  static Future<ArchiveFormat?> detect(String path) async {
    final at = p.absolute(path);
    await _there(at);
    final code = NativeBridge.main.withText(at, _N.format);
    return code <= 0 ? null : ArchiveFormat.values[code - 1];
  }

  /// The bytes of the entry [name], as [entries] lists it, read without extracting anything
  /// else; a [MissingException] when there is none.
  Task<Uint8List> entry(String name) {
    final at = p.absolute(path), pw = _password?.reveal, flags = _flags(_unsafe);
    return TaskInternals.start(path, '${FileBridge.label(path)}: $name', (work) async {
      try {
        return await NativeBridge.main.run(work, _readCall(at, name, pw, flags));
      } on FormatException catch (e) {
        if (e.message.endsWith(': no entry $name')) throw MissingException('entry $name', where: path);
        rethrow;
      }
    });
  }

  /// Every file with its bytes, in archive order, in one pass: a solid 7z or a compressed tar
  /// is decoded once, where an [entry] per file decodes everything before it again. [only] is
  /// a glob of the names wanted; folders and links are left out. The size cap holds over the
  /// whole pass.
  ///
  /// The archive is read on a native thread, one file ahead of the listener; a paused
  /// subscription holds it there, and a cancelled one or the enclosing [Cancel.scope] stops it.
  Stream<({ArchiveEntry entry, Uint8List bytes})> contents({String? only}) =>
      _contents(p.absolute(path), _password?.reveal, only, _flags(_unsafe));

  @override
  String toString() => 'Archive($path, ${entries.length} entries)';
}

/// The wrong or missing password for an archive: [message] names the archive, and for a wrong
/// one what the format said. A [FormatException], so code that catches those still does.
///
/// ```dart
/// for (final password in passwords) {
///   try {
///     return await rar.unarchive(into: dir, password: password);
///   } on PasswordException {
///     continue;
///   }
/// }
/// ```
///
/// {@category Files}
final class PasswordException extends FormatException {
  const PasswordException(super.message);

  @override
  String toString() => 'PasswordException: $message';
}

/// Archiving and extracting a [Path].
///
/// ```dart
/// await dir.archive(to: 'backup.zip').show('Packing');
/// await Path('x.zip').unarchive(into: 'out', password: pw);
/// ```
///
/// {@category Files}
extension PathArchiveExtensions on Path {
  /// This folder or file archived [to] a file whose extension names the format: `.zip`, `.7z`,
  /// `.tar`, `.tar.gz` (`.tgz`), `.tar.xz`, `.tar.zst`, `.tar.bz2`; or this one file compressed
  /// as a single stream: `.gz`, `.xz`, `.zst`, `.bz2`. Answers the archive.
  ///
  /// [only] is a glob of the files under this folder to take, as `files(only:)` reads it.
  /// [password] encrypts a zip (AES-256) or a 7z. [level] is the codec's own scale (zip and
  /// gzip 0–9, zip 0 storing; xz and 7z 0–9; bzip2 1–9; zstd up to 22); without it, the
  /// codec's default.
  ///
  /// The archive is built beside its destination and renamed over it, so a failure or a
  /// cancel leaves what was there; [conflict] settles a destination already there
  /// ([Conflict.skip] by default: `Done(fresh: false)`). An archive written inside the folder
  /// it archives leaves itself out. [original] then keeps this file or folder (the default),
  /// or moves to the trash or deletes it (with [only], just the files taken).
  ///
  /// A destination with no known extension, `.rar`, [only] on a file, or [password] or [only]
  /// on a single stream is an [ArgumentError]; so is a folder to a single stream.
  Task<Path> archive({
    required String to,
    String? only,
    Secret? password,
    int? level,
    Original original = Original.keep,
    Conflict conflict = Conflict.skip,
  }) {
    final format =
        ArchiveFormat.of(to) ??
        (throw ArgumentError.value(to, 'to', 'Invalid archive name: no format has its extension'));
    if (format == ArchiveFormat.rar) throw ArgumentError.value(to, 'to', 'Invalid archive name: RAR is read only');
    if (format.isStream && (only != null || password != null)) {
      throw ArgumentError('Cannot compress to $to with ${only != null ? 'only:' : 'password:'}: it holds one file');
    }
    if (level != null && level < 0 && format != ArchiveFormat.zst && format != ArchiveFormat.tarZst) {
      throw ArgumentError.value(level, 'level', 'Invalid level: negative');
    }
    final src = p.absolute(this), dest = p.absolute(to);
    if (original != Original.keep && (p.equals(src, dest) || p.isWithin(src, dest))) {
      throw ArgumentError('Cannot ${original.name} $this once archived: $to is inside it');
    }
    return TaskInternals.start(this, FileBridge.label(this), (work) async {
      final type = await FileSystemEntity.type(src);
      if (type == FileSystemEntityType.notFound) throw FileBridge.notFound(src, 'Cannot archive');
      final isDir = type == FileSystemEntityType.directory;
      if (format.isStream && isDir) throw ArgumentError('Cannot compress the folder $this to $to: it holds one file');
      if (!isDir && only != null) throw ArgumentError.value(only, 'only', 'Invalid filter for $this, a file');
      final target = FileBridge.settle(
        dest,
        conflict,
        verb: 'archive',
        subject: this,
        source: conflict == Conflict.newer ? (await FileStat.stat(src)).modified : null,
      );
      if (target == null) {
        TaskInternals.stale(work);
        return Path(to);
      }
      try {
        final picked = only == null ? null : await Path(src).files(only: only).toList();
        final temp = FileBridge.temp(target);
        work.defer(() => _gone(temp));
        void report(NativeReport r) => work
          ..amount(r.bytes, total: r.bytesTotal == 0 ? null : r.bytesTotal)
          ..step(r.name);
        await NativeBridge.main.run(
          work,
          format.isStream
              ? _compressCall(format.index - ArchiveFormat.gz.index, src, temp, level ?? -1)
              : _createCall(format.index, src, target, temp, password?.reveal, _names(src, picked), level ?? -1),
          onProgress: report,
        );
        await FileBridge.rename(File(temp), target);
        await _dispose(original, src, picked);
        return Path(target == dest ? to : target);
      } finally {
        FileBridge.release(target);
      }
    });
  }

  /// This archive or compressed file extracted [into] a folder, made when missing; answers the
  /// folder. A container (zip, 7z, RAR, a tar in any form) is read from its content, not its
  /// name; a single stream (`x.gz`) lands at `into/x`.
  ///
  /// Everything is extracted beside [into] first and moved in, so a failure or a cancel leaves
  /// [into] as it was. Folders merge, and [conflict] settles each file already there
  /// ([Conflict.skip] by default; [Conflict.fail] refuses before anything moves). [flatten]
  /// puts every file at [into]'s top, two of one name settled by [conflict]. [only] is a glob
  /// of the entries to take.
  ///
  /// Containment holds unless [unsafe]: no entry or link leads out of [into], no link is
  /// followed, setuid, setgid and sticky are dropped, and the output is capped at 200× the
  /// archive (at least 1 GiB). A refused or corrupt archive is a [FormatException], a wrong
  /// password a [PasswordException]. [original] then keeps the archive (the default), or moves
  /// to the trash or deletes it, every part of a RAR volume set.
  ///
  /// A later part of a RAR set (`x.part2.rar`) is no archive: a [FormatException] naming the
  /// first. [password], [flatten] or [only] on a single stream is an [ArgumentError].
  Task<Path> unarchive({
    required String into,
    Secret? password,
    String? only,
    bool flatten = false,
    Original original = Original.keep,
    Conflict conflict = Conflict.skip,
    bool unsafe = false,
  }) {
    final src = p.absolute(this), dest = p.absolute(into), flags = _flags(unsafe);
    return TaskInternals.start(this, FileBridge.label(this), (work) async {
      await _there(src);
      _refuseLaterPart(src);
      final code = NativeBridge.main.withText(src, _N.format);
      if (code <= 0) throw FormatException('Invalid archive in $this: not an archive, and its name does not say');
      final format = ArchiveFormat.values[code - 1];
      final pw = password?.reveal;
      void report(NativeReport r) {
        // Without a byte count, the entries are the measure.
        if (r.bytesTotal > 0) {
          work.amount(r.bytes, total: r.bytesTotal);
        } else {
          work.amount(r.completed, total: r.total > 0 ? r.total : null, unit: Unit.items);
        }
        if (r.name.isNotEmpty) work.step(r.name);
      }

      if (format.isStream) {
        if (password != null || flatten || only != null) {
          throw ArgumentError(
            'Cannot unarchive $this with ${password != null
                ? 'password:'
                : flatten
                ? 'flatten:'
                : 'only:'}: it holds one file',
          );
        }
        await Directory(dest).create(recursive: true);
        final name = p.basename(src);
        final out = p.join(
          dest,
          name.length > format.extension.length && name.toLowerCase().endsWith(format.extension)
              ? name.substring(0, name.length - format.extension.length)
              : name,
        );
        final target = FileBridge.settle(
          out,
          conflict,
          verb: 'unarchive',
          subject: this,
          source: await _modified(src, conflict),
        );
        if (target == null) {
          TaskInternals.stale(work);
          return Path(into);
        }
        try {
          final temp = FileBridge.temp(target);
          work.defer(() => _gone(temp));
          await NativeBridge.main.run(work, _decompressCall(src, temp, flags), onProgress: report);
          await FileBridge.rename(File(temp), target);
        } finally {
          FileBridge.release(target);
        }
      } else {
        // Inside a folder that is there, so the moves in are renames on its own volume even when
        // it is a mount point or a link to another one; beside it otherwise, renamed in whole.
        final there = await FileSystemEntity.type(dest) != FileSystemEntityType.notFound;
        final stage = FileBridge.temp(there ? p.join(dest, p.basename(src)) : dest);
        work.defer(() => _gone(stage));
        await NativeBridge.main.run(work, _extractCall(src, stage, pw, only, flags), onProgress: report);
        if (!flatten && !there) {
          await Directory(p.dirname(dest)).create(recursive: true);
          await FileBridge.rename(Directory(stage), dest);
        } else if (!await _merge(work, stage, dest, conflict, flatten, this)) {
          TaskInternals.stale(work);
        }
      }
      await _dispose(original, src, null, volumes: true);
      return Path(into);
    });
  }
}

/// Nothing, or a [PathNotFoundException] when [path] is not there: checked first, so a missing
/// file never reads as a damaged one.
Future<void> _there(String path) async {
  if (await FileSystemEntity.type(path) == FileSystemEntityType.notFound) {
    throw FileBridge.notFound(path, 'Cannot open');
  }
}

/// [path]'s modification time when [conflict] compares it, else `null`.
Future<DateTime?> _modified(String path, Conflict conflict) async =>
    conflict == Conflict.newer ? (await FileStat.stat(path)).modified : null;

/// [path] deleted, whatever it is; one already gone is no matter. On Windows a read-only file
/// is made writable first.
Future<void> _gone(String path) async {
  try {
    switch (await FileSystemEntity.type(path, followLinks: false)) {
      case FileSystemEntityType.notFound:
        return;
      case FileSystemEntityType.directory:
        await Path(path).delete(recursive: true);
      default:
        await Path(path).delete();
    }
  } on FileSystemException catch (_) {} // not ours to delete after all: left
}

/// What [Original] asks of the source once it has been replaced: [picked] are the files taken
/// (all of [src] when `null`); with [volumes], every part of a RAR set goes.
Future<void> _dispose(Original original, String src, List<Path>? picked, {bool volumes = false}) async {
  if (original == Original.keep) return;
  final paths = picked ?? (volumes ? await _volumes(src) : [Path(src)]);
  for (final path in paths) {
    switch (original) {
      case Original.trash:
        await path.trash();
      case Original.delete:
        await path.delete(recursive: true);
      case Original.keep:
    }
  }
}

/// [picked], under [root], as the native walk takes them: relative names, each after a NUL, so
/// that none at all is not mistaken for everything; `null` for everything.
String? _names(String root, List<Path>? picked) {
  if (picked == null) return null;
  // The listing's paths are under its normalized root: a cut, not `p.relative` per file.
  final base = p.normalize(root);
  final cut = base.endsWith(p.separator) ? base.length : base.length + 1;
  return '\x00${picked.map((f) => f.substring(cut)).join('\x00')}';
}

/// The native flags: unsafe, and whether `only` folds case as the platform's paths do.
int _flags(bool unsafe) => (unsafe ? 1 : 0) | (Platform.isMacOS || Platform.isWindows ? 2 : 0);

/// What was extracted into [stage] moved into [dest]: a folder onto a folder merges, anything
/// else is settled by [conflict], and a link already in [dest] is never walked through: it is in
/// conflict with what would go there. [flatten]ed, every file and link lands in [dest] itself.
/// [Conflict.fail] checks every name before anything moves. Answers whether anything moved.
Future<bool> _merge(Work work, String stage, String dest, Conflict conflict, bool flatten, String archive) async {
  await Directory(dest).create(recursive: true);
  work.step('merging');
  Never taken(String to) => throw PathExistsException(to, const OSError(), 'Cannot unarchive $archive: $to exists');
  if (flatten) {
    final moves = [
      await for (final e in Directory(stage).list(recursive: true, followLinks: false))
        if (e is! Directory) (e, p.join(dest, p.basename(e.path))),
    ];
    if (conflict == Conflict.fail) {
      final names = <String>{};
      for (final (_, to) in moves) {
        if (!names.add(to) || await FileSystemEntity.type(to, followLinks: false) != FileSystemEntityType.notFound) {
          taken(to);
        }
      }
    }
    var moved = false;
    for (final (from, to) in moves) {
      // A folder of that name is no file to replace or skip for: the file takes a free name.
      final policy = await FileSystemEntity.isDirectory(to) ? Conflict.rename : conflict;
      moved = await _land(from, to, policy, archive) || moved;
    }
    return moved;
  }
  if (conflict == Conflict.fail) {
    if (await _clash(stage, dest) case final to?) taken(to);
  }
  return _mergeInto(stage, dest, conflict, archive);
}

/// The first path under [to] that something under [from] would land on, other than a folder
/// on a folder.
Future<String?> _clash(String from, String to) async {
  await for (final entry in Directory(from).list(followLinks: false)) {
    final target = p.join(to, p.basename(entry.path));
    final there = await FileSystemEntity.type(target, followLinks: false);
    if (there == FileSystemEntityType.notFound) continue;
    if (entry is Directory && there == FileSystemEntityType.directory) {
      if (await _clash(entry.path, target) case final taken?) return taken;
      continue;
    }
    return target;
  }
  return null;
}

/// [from]'s entries moved into the folder [to]: a folder onto nothing in one rename, onto a
/// folder merged, onto anything else settled as a whole by [conflict], as a file is.
Future<bool> _mergeInto(String from, String to, Conflict conflict, String archive) async {
  var moved = false;
  await for (final entry in Directory(from).list(followLinks: false)) {
    final target = p.join(to, p.basename(entry.path));
    final there = await FileSystemEntity.type(target, followLinks: false);
    if (entry is Directory && there == FileSystemEntityType.directory) {
      moved = await _mergeInto(entry.path, target, conflict, archive) || moved;
    } else {
      moved = await _land(entry, target, conflict, archive) || moved;
    }
  }
  return moved;
}

/// [entry] renamed to [to], or beside it, as [conflict] settles it; a file is renamed over
/// what it replaces, while a folder replacing a file or a link takes its place. Answers whether
/// it moved.
Future<bool> _land(FileSystemEntity entry, String to, Conflict conflict, String archive) async {
  final target = FileBridge.settle(
    to,
    conflict,
    verb: 'unarchive',
    subject: archive,
    source: await _modified(entry.path, conflict),
  );
  if (target == null) return false;
  try {
    if (entry is Directory &&
        await FileSystemEntity.type(target, followLinks: false) != FileSystemEntityType.notFound) {
      await _gone(target);
    }
    await FileBridge.rename(entry, target);
    return true;
  } finally {
    FileBridge.release(target);
  }
}

final _partOf = RegExp(r'^(.*)\.part(\d+)\.rar$', caseSensitive: false);
final _oldPart = RegExp(r'^.*\.r\d\d$', caseSensitive: false);

/// A later part of a RAR volume set is no archive: extracting it names the first part.
void _refuseLaterPart(String path) {
  final name = p.basename(path);
  final first = switch (_partOf.firstMatch(name)) {
    final m? when int.parse(m[2]!) > 1 => '${m[1]}.part${'1'.padLeft(m[2]!.length, '0')}.rar',
    _ => _oldPart.firstMatch(name) == null ? null : '${name.substring(0, name.length - 4)}.rar',
  };
  if (first != null) throw FormatException('Invalid RAR in $path: a later part of a volume set; unarchive $first');
}

/// The files of the archive at [path]: every part of a RAR volume set it opens, else itself.
Future<List<Path>> _volumes(String path) async {
  final dir = p.dirname(path), name = p.basename(path);
  final RegExp sibling;
  if (_partOf.firstMatch(name) case final m?) {
    sibling = RegExp('^${RegExp.escape(m[1]!)}\\.part\\d+\\.rar\$', caseSensitive: false);
  } else if (name.toLowerCase().endsWith('.rar')) {
    sibling = RegExp('^${RegExp.escape(name.substring(0, name.length - 4))}\\.r\\d\\d\$', caseSensitive: false);
  } else {
    return [Path(path)];
  }
  return [
    Path(path),
    await for (final e in Directory(dir).list(followLinks: false))
      if (e is File && p.basename(e.path) != name && sibling.hasMatch(p.basename(e.path))) Path(e.path),
  ];
}

// ---- the native calls

typedef _U8 = Pointer<Uint8>;

typedef _NativeContentsCb = Void Function(Int32 code, _U8 head, IntPtr headLen, _U8 data, IntPtr dataLen);

typedef _ContentsCb = Pointer<NativeFunction<_NativeContentsCb>>;

abstract final class _N {
  static final _lib = NativeBridge.main.require();
  static final format = _lib.lookupFunction<Int32 Function(_U8, IntPtr), int Function(_U8, int)>('tk_archive_format');
  static final list = _lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, _U8, IntPtr, Pointer<_U8>, Pointer<IntPtr>),
        int Function(_U8, int, _U8, int, Pointer<_U8>, Pointer<IntPtr>)
      >('tk_archive_list');
  static final extract = _lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr, Uint32, NativeProgress, _U8),
        int Function(_U8, int, _U8, int, _U8, int, _U8, int, int, NativeProgress, _U8)
      >('tk_archive_extract');
  static final read = _lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, _U8, IntPtr, _U8, IntPtr, Uint32, Pointer<_U8>, Pointer<IntPtr>, _U8),
        int Function(_U8, int, _U8, int, _U8, int, int, Pointer<_U8>, Pointer<IntPtr>, _U8)
      >('tk_archive_read');
  static final create = _lib
      .lookupFunction<
        Int32 Function(
          Uint32,
          _U8,
          IntPtr,
          _U8,
          IntPtr,
          _U8,
          IntPtr,
          _U8,
          IntPtr,
          _U8,
          IntPtr,
          Int32,
          NativeProgress,
          _U8,
        ),
        int Function(int, _U8, int, _U8, int, _U8, int, _U8, int, _U8, int, int, NativeProgress, _U8)
      >('tk_archive_create');
  static final compress = _lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, Int32, NativeProgress, _U8),
        int Function(int, _U8, int, _U8, int, int, NativeProgress, _U8)
      >('tk_compress');
  static final decompress = _lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, Uint32, NativeProgress, _U8),
        int Function(int, _U8, int, _U8, int, int, NativeProgress, _U8)
      >('tk_decompress');
  static final contents = _lib
      .lookupFunction<
        Pointer<Void> Function(_U8, IntPtr, _U8, IntPtr, _U8, IntPtr, Uint32, _ContentsCb),
        Pointer<Void> Function(_U8, int, _U8, int, _U8, int, int, _ContentsCb)
      >('tk_archive_contents');
  static final contentsMore = _lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'tk_archive_contents_more',
  );
  static final contentsFree = _lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'tk_archive_contents_free',
  );
  static final release = _lib.lookup<NativeFunction<Void Function(Pointer<Void>)>>('tk_release');
}

/// [texts] as UTF-8 in one native allocation; `null` and `''` are a null pointer.
R _with<R>(List<String?> texts, R Function(List<(_U8, int)> args) body) {
  final encoded = [for (final t in texts) utf8.encode(t ?? '')];
  return NativeBridge.main.withBytes([for (final e in encoded) ...e], (base, _) {
    final args = <(_U8, int)>[];
    var at = 0;
    for (final e in encoded) {
      args.add(e.isEmpty ? (nullptr, 0) : (base + at, e.length));
      at += e.length;
    }
    return body(args);
  });
}

/// [code]'s failure, about [subject], as the exception it means; see [_failure].
void _check(int code, String subject, [String? password]) {
  if (code < 0) throw _failure(NativeBridge.main.lastError(), subject, password);
}

// Each of these is what a worker runs: only plain values cross with it.

Uint8List Function(NativeProgress, _U8) _listCall(String path, String? password) =>
    (_, _) => _with([path, password], (a) {
      final [(p0, pl), (pw, pwl)] = a;
      return _take(path, password, (out, len) => _N.list(p0, pl, pw, pwl, out, len));
    });

Uint8List Function(NativeProgress, _U8) _readCall(String path, String name, String? password, int flags) =>
    (_, stop) => _with([path, name, password], (a) {
      final [(p0, pl), (n, nl), (pw, pwl)] = a;
      return _take(path, password, (out, len) => _N.read(p0, pl, n, nl, pw, pwl, flags, out, len, stop));
    });

void Function(NativeProgress, _U8) _extractCall(String path, String dest, String? password, String? only, int flags) =>
    (progress, stop) => _with([path, dest, password, only], (a) {
      final [(p0, pl), (d, dl), (pw, pwl), (o, ol)] = a;
      _check(_N.extract(p0, pl, d, dl, pw, pwl, o, ol, flags, progress, stop), path, password);
    });

void Function(NativeProgress, _U8) _createCall(
  int format,
  String src,
  String dest,
  String out,
  String? password,
  String? names,
  int level,
) =>
    (progress, stop) => _with([src, dest, out, password, names], (a) {
      final [(s, sl), (d, dl), (o, ol), (pw, pwl), (n, nl)] = a;
      _check(_N.create(format, s, sl, d, dl, o, ol, pw, pwl, n, nl, level, progress, stop), src);
    });

void Function(NativeProgress, _U8) _compressCall(int codec, String src, String dest, int level) =>
    (progress, stop) => _with([src, dest], (a) {
      final [(s, sl), (d, dl)] = a;
      _check(_N.compress(codec, s, sl, d, dl, level, progress, stop), src);
    });

/// A codec of `0xFFFFFFFF` asks the library to read the stream's magic number.
void Function(NativeProgress, _U8) _decompressCall(String src, String dest, int flags) =>
    (progress, stop) => _with([src, dest], (a) {
      final [(s, sl), (d, dl)] = a;
      _check(_N.decompress(0xFFFFFFFF, s, sl, d, dl, flags, progress, stop), src);
    });

/// What the library allocated, or its failure, as [_check] reads it.
Uint8List _take(String subject, String? password, int Function(Pointer<_U8> out, Pointer<IntPtr> len) body) {
  try {
    return NativeBridge.main.take('read archive', body);
  } on NativeException catch (e) {
    throw _failure(e.message, subject, password);
  }
}

/// The entries `tk_archive_list` writes, each a record as [_entryAt] reads it.
List<ArchiveEntry> _entriesOf(Uint8List listed) {
  final entries = <ArchiveEntry>[];
  for (var at = 0; at < listed.length;) {
    final (entry, next) = _entryAt(listed, at);
    entries.add(entry);
    at = next;
  }
  return entries;
}

/// The entry recorded at [at] in [bytes], and where the next one starts: size, compressed
/// size and modified time (`i64::MIN` for none) as little-endian 64-bit numbers, a flags byte
/// (1 encrypted, 2 a folder), the name's length as a little-endian 32-bit number, the name.
(ArchiveEntry, int) _entryAt(Uint8List bytes, int at) {
  final d = ByteData.sublistView(bytes);
  final modified = d.getInt64(at + 16, Endian.little);
  final flags = bytes[at + 24];
  final end = at + 29 + d.getUint32(at + 25, Endian.little);
  return (
    ArchiveEntry(
      name: utf8.decode(Uint8List.sublistView(bytes, at + 29, end)),
      size: d.getInt64(at, Endian.little),
      compressedSize: d.getInt64(at + 8, Endian.little),
      isDir: flags & 2 != 0,
      isEncrypted: flags & 1 != 0,
      modified: modified == _noTime ? null : DateTime.fromMillisecondsSinceEpoch(modified * 1000),
    ),
    end,
  );
}

/// `i64::MIN`: no modified time.
const _noTime = -0x8000000000000000;

/// The pass, heard by a listener on this isolate: the native thread reads one file ahead, and
/// each is asked for once the last is delivered and the subscription is not paused.
Stream<({ArchiveEntry entry, Uint8List bytes})> _contents(String path, String? password, String? only, int flags) {
  late final StreamController<({ArchiveEntry entry, Uint8List bytes})> out;
  late final NativeCallable<_NativeContentsCb> listener;
  var pass = nullptr.cast<Void>();
  var asked = false;
  void Function()? unhear;

  void ask() {
    if (asked || pass == nullptr || out.isPaused) return;
    asked = true;
    _N.contentsMore(pass);
  }

  // The thread stops at its next file; the listener stays open until it says it has.
  void end() {
    if (pass == nullptr) return;
    _N.contentsFree(pass);
    pass = nullptr;
    unhear?.call();
  }

  void heard(int code, _U8 head, int headLen, _U8 data, int dataLen) {
    if (code == 1) {
      final (entry, _) = _entryAt(NativeBridge.main.adopt(head, headLen), 0);
      // The library's own buffer, freed when the list is: no copy of a file's bytes.
      final bytes = data.asTypedList(dataLen, finalizer: _N.release, token: data.cast());
      asked = false;
      if (pass == nullptr) return;
      out.add((entry: entry, bytes: bytes));
      ask();
      return;
    }
    // The pass's last word: nothing calls after it.
    final failure = code < 0 ? utf8.decode(NativeBridge.main.adopt(head, headLen), allowMalformed: true) : null;
    listener.close();
    if (pass == nullptr) return;
    end();
    if (failure != null) out.addError(_failure(failure, path, password));
    out.close();
  }

  out = StreamController(
    onListen: () async {
      try {
        await _there(path);
      } on PathNotFoundException catch (e, st) {
        out
          ..addError(e, st)
          ..close();
        return;
      }
      listener = NativeCallable<_NativeContentsCb>.listener(heard);
      pass = _with([path, password, only], (a) {
        final [(p0, pl), (pw, pwl), (o, ol)] = a;
        return _N.contents(p0, pl, pw, pwl, o, ol, flags, listener.nativeFunction);
      });
      if (pass == nullptr) {
        listener.close();
        out
          ..addError(_failure(NativeBridge.main.lastError(), path, password))
          ..close();
        return;
      }
      if (Cancel.token case final token?) {
        unhear = token.onCancel(() {
          if (pass == nullptr) return;
          end();
          out
            ..addError(CancelledException.of(token))
            ..close();
        });
      }
      ask();
    },
    onResume: ask,
    onCancel: end,
  );
  return out.stream;
}

/// What the native library said about [subject], as the exception it means: a missing file is a
/// [PathNotFoundException], a full disk or another system error a [FileSystemException], a wrong
/// or missing password a [PasswordException], and anything else a [FormatException].
Exception _failure(String message, String subject, String? password) {
  final m = message.toLowerCase();
  if (NativeBridge.fileError(message, subject, '') case final os when os is! FormatException) return os;
  if (_missingPassword.any(m.contains)) return PasswordException('Invalid archive in $subject: missing password');
  // Without a password, a CRC or a corrupt stream is damage; with one, the likeliest cause is it.
  if (_wrongPassword.any(m.contains) || (password != null && _damage.any(m.contains))) {
    return PasswordException('Invalid archive in $subject: wrong password ($message)');
  }
  return FormatException('Invalid archive in $subject: $message');
}

const _missingPassword = ['password required', 'passwordrequired', 'password for encrypted archive not specified'];
const _wrongPassword = ['password provided is incorrect', 'wrong password', 'maybebadpassword'];
const _damage = ['file crc error', 'corrupted input data', 'checksum'];
