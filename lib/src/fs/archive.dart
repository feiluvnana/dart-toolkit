part of '../../fs.dart';

/// Every container format the package knows, and the extension that names each one.
///
/// `archiveTo` writes all but [rar], which is read-only: the format's licence forbids
/// writing it. Reading never needs this enum — `extractTo` and `archiveEntries` read the
/// file's magic number — so it is here for `archiveTo`'s destination and for [of].
///
/// {@category Files}
enum Archive {
  zip('.zip'),
  sevenZip('.7z'),
  tar('.tar'),
  tarGz('.tar.gz'),
  tarXz('.tar.xz'),
  tarZst('.tar.zst'),
  tarBz2('.tar.bz2'),
  rar('.rar');

  final String extension;
  const Archive(this.extension);

  /// Whether [archiveTo] can write this format.
  bool get isWritable => this != rar;

  /// The format for [path], by extension, or `null`.
  ///
  /// This reads the name, not the file. What a file actually is, the native library
  /// decides from its first bytes when it is read.
  static Archive? of(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.tgz')) return tarGz;
    if (lower.endsWith('.txz')) return tarXz;
    if (lower.endsWith('.tzst')) return tarZst;
    if (lower.endsWith('.tbz2')) return tarBz2;
    for (final a in values) {
      if (lower.endsWith(a.extension)) return a;
    }
    return null;
  }
}

/// Single-stream codecs for `compressTo` and `decompressTo`.
///
/// {@category Files}
enum Compression {
  gzip('.gz'),
  xz('.xz'),
  zstd('.zst'),
  bzip2('.bz2');

  final String extension;
  const Compression(this.extension);
}

/// One entry of any archive.
///
/// {@category Files}
final class ArchiveEntry {
  /// The path inside the archive, `/`-separated; a directory ends in `/`.
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

/// Archives on [Path]: zip, 7z, rar (read), tar and its gz, xz, zstd and bzip2 forms, with a
/// password where the format has one. All of it runs in the native library; where it did not
/// load every call throws [UnsupportedError] with the reason.
///
/// ```dart
/// await src.archiveTo('backup.7z', password: 'pw');
/// await 'release.tar.zst'.path.extractTo(dir);
/// for (final e in await 'photos.rar'.path.archiveEntries(password: 'pw')) print(e);
/// ```
///
/// {@category Files}
extension PathArchiveExtensions on Path {
  /// Archives this file or directory into [destination]; the format is [destination]'s
  /// extension. [level] is the codec's own scale; `null` is its default. Returns the file.
  ///
  /// zip and 7z take a [password] (AES-256); tar does not and throws [ArgumentError].
  /// [Archive.rar] cannot be written and throws [ArgumentError] too.
  Future<File> archiveTo(String destination, {String? password, int? level}) async {
    final format = Archive.of(destination) ?? _unknown(destination);
    if (!format.isWritable) {
      throw ArgumentError('${format.name} can only be read; write .zip or .7z instead');
    }
    if (format != Archive.zip && format != Archive.sevenZip && password != null) {
      throw ArgumentError('${format.name} has no encryption; use zip or 7z');
    }
    await Isolate.run(() => _NativeArchive.create(format, path, destination, password, level ?? -1));
    return File(destination);
  }

  /// Extracts the archive at this path into [destination], restoring permissions and times;
  /// [only] extracts just the entries that match a [glob] pattern: `only: '**/*.txt'`.
  ///
  /// The format comes from the file's magic number, so a renamed or extension-less archive
  /// still extracts; the name is only consulted when the bytes are inconclusive, which is
  /// what tells a `.tar.gz` from a lone `.gz`.
  ///
  /// An archive is assumed to come from somewhere else, so by default it may not write more
  /// than 200 times its own size (at least 1 GiB), setuid, setgid and sticky bits are
  /// dropped, and a link that leads out of [destination] is refused. [trusted] lifts all
  /// three; nothing lifts the refusal of an entry named outside [destination].
  ///
  /// Throws [FormatException] on a corrupt archive, a wrong [password] or one of the refusals
  /// above, [UnsupportedError] when the native library did not load.
  Future<Directory> extractTo(String destination, {String? password, String? only, bool trusted = false}) async {
    await Isolate.run(() => _NativeArchive.extract(path, destination, password, only, _flags(trusted)));
    return Directory(destination);
  }

  /// The contents of the one entry [name] — `'a/b.txt'`, as [archiveEntries] lists it — read
  /// without extracting anything else. The size cap is [extractTo]'s, and [trusted] lifts it.
  Future<Uint8List> entry(String name, {String? password, bool trusted = false}) =>
      Isolate.run(() => _NativeArchive.read(path, name, password, _flags(trusted)));

  /// The entries of the archive at this path, without extracting; the format is read from
  /// the file itself, as in [extractTo].
  Future<List<ArchiveEntry>> archiveEntries({String? password}) async {
    return Isolate.run(() => _NativeArchive.list(path, password));
  }

  /// Compresses this file into [destination] with [codec], read from the extension by default.
  Future<File> compressTo(String destination, {Compression? codec, int? level}) async {
    final c = codec ?? _codecOf(destination);
    await Isolate.run(() => _NativeArchive.compress(c, path, destination, level ?? -1));
    return File(destination);
  }

  /// Decompresses this single-stream file into [destination].
  ///
  /// The codec is read from the file's magic number unless [codec] names one, so a stream
  /// saved without its extension still decompresses. Throws [FormatException] when the
  /// bytes are none of gzip, xz, zstd or bzip2, or decompress to more than [extractTo]'s cap
  /// — which leaves nothing at [destination] — unless [trusted].
  Future<File> decompressTo(String destination, {Compression? codec, bool trusted = false}) async {
    await Isolate.run(() => _NativeArchive.decompress(codec, path, destination, _flags(trusted)));
    return File(destination);
  }

  /// The native flags: trusted, and whether [extractTo]'s `only` folds case as [glob] does.
  static int _flags(bool trusted) => (trusted ? 1 : 0) | (Platform.isMacOS || Platform.isWindows ? 2 : 0);

  static Compression _codecOf(String path) {
    for (final c in Compression.values) {
      if (path.toLowerCase().endsWith(c.extension)) return c;
    }
    throw ArgumentError(
      'No codec for "$path"; extensions are ${Compression.values.map((c) => c.extension).join(', ')}',
    );
  }

  static Never _unknown(String path) => throw ArgumentError(
    'No archive format for "$path"; extensions are ${Archive.values.map((a) => a.extension).join(', ')}',
  );
}

typedef _U8 = Pointer<Uint8>;
typedef _Text = (_U8, int);

/// The archive functions of `dart_toolkit_native`, by file path.
final class _NativeArchive {
  static final _lib = NativeBridge.require('archives');
  static final _list = _lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, _U8, IntPtr, Pointer<_U8>, Pointer<IntPtr>),
        int Function(_U8, int, _U8, int, Pointer<_U8>, Pointer<IntPtr>)
      >('tk_archive_list');
  static final _extract = _lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr, Uint32),
        int Function(_U8, int, _U8, int, _U8, int, _U8, int, int)
      >('tk_archive_extract');
  static final _read = _lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, _U8, IntPtr, _U8, IntPtr, Uint32, Pointer<_U8>, Pointer<IntPtr>),
        int Function(_U8, int, _U8, int, _U8, int, int, Pointer<_U8>, Pointer<IntPtr>)
      >('tk_archive_read');
  static final _create = _lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr, Int32),
        int Function(int, _U8, int, _U8, int, _U8, int, int)
      >('tk_archive_create');
  static final _compress = _lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, Int32),
        int Function(int, _U8, int, _U8, int, int)
      >('tk_compress');
  static final _decompress = _lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, Uint32),
        int Function(int, _U8, int, _U8, int, int)
      >('tk_decompress');

  /// [texts] as UTF-8 in one native allocation, each as a pointer and a length; `null`, and
  /// the empty string with it, is a null pointer.
  static R _with<R>(List<String?> texts, R Function(List<_Text> args) body) {
    final encoded = [for (final t in texts) utf8.encode(t ?? '')];
    return NativeBridge.withBytes([for (final e in encoded) ...e], (base, _) {
      final args = <_Text>[];
      var at = 0;
      for (final e in encoded) {
        args.add(e.isEmpty ? (nullptr, 0) : (base + at, e.length));
        at += e.length;
      }
      return body(args);
    });
  }

  static void _check(int code) {
    if (code < 0) throw FormatException(NativeBridge.lastError());
  }

  /// What the library allocated, or its error as a [FormatException].
  static Uint8List _take(int Function(Pointer<_U8> out, Pointer<IntPtr> len) body) {
    try {
      return NativeBridge.take(body);
    } on StateError catch (e) {
      throw FormatException(e.message);
    }
  }

  static List<ArchiveEntry> list(String path, String? password) {
    final data = _with([
      path,
      password,
    ], (a) => _take((out, len) => _list(a[0].$1, a[0].$2, a[1].$1, a[1].$2, out, len)));
    return [
      for (final e in (jsonDecode(utf8.decode(data)) as List).cast<Map<String, Object?>>())
        ArchiveEntry(
          name: e['name'] as String,
          size: e['size'] as int,
          compressedSize: e['compressed'] as int,
          isDir: e['dir'] as bool,
          isEncrypted: e['encrypted'] as bool,
          modified: e['modified'] == null ? null : DateTime.fromMillisecondsSinceEpoch((e['modified'] as int) * 1000),
        ),
    ];
  }

  static void extract(String path, String dest, String? password, String? only, int flags) =>
      _with([path, dest, password, only], (a) {
        final [(p, pl), (d, dl), (pw, pwl), (o, ol)] = a;
        _check(_extract(p, pl, d, dl, pw, pwl, o, ol, flags));
      });

  static Uint8List read(String path, String name, String? password, int flags) => _with([path, name, password], (a) {
    final [(p, pl), (n, nl), (pw, pwl)] = a;
    return _take((out, len) => _read(p, pl, n, nl, pw, pwl, flags, out, len));
  });

  static void create(Archive format, String src, String dest, String? password, int level) =>
      _with([src, dest, password], (a) {
        final [(s, sl), (d, dl), (pw, pwl)] = a;
        _check(_create(format.index, s, sl, d, dl, pw, pwl, level));
      });

  static void compress(Compression codec, String src, String dest, int level) => _with([src, dest], (a) {
    final [(s, sl), (d, dl)] = a;
    _check(_compress(codec.index, s, sl, d, dl, level));
  });

  /// A `null` codec asks the library to read the stream's magic number.
  static const _detect = 0xFFFFFFFF;

  static void decompress(Compression? codec, String src, String dest, int flags) => _with([src, dest], (a) {
    final [(s, sl), (d, dl)] = a;
    _check(_decompress(codec?.index ?? _detect, s, sl, d, dl, flags));
  });
}
