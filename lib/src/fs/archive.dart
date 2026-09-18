part of '../../fs.dart';

/// Container formats `archiveTo` writes; read from the destination's extension.
///
/// {@category Files}
enum Archive {
  zip('.zip'),
  sevenZip('.7z'),
  tar('.tar'),
  tarGz('.tar.gz'),
  tarXz('.tar.xz'),
  tarZst('.tar.zst'),
  tarBz2('.tar.bz2');

  final String extension;
  const Archive(this.extension);

  /// The format for [path], by extension, or `null`.
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
  Future<File> archiveTo(String destination, {String? password, int? level}) async {
    final format = Archive.of(destination) ?? _unknown(destination);
    if (format != Archive.zip && format != Archive.sevenZip && password != null) {
      throw ArgumentError('${format.name} has no encryption; use zip or 7z');
    }
    await Isolate.run(() => _NativeArchive.create(format, path, destination, password, level ?? -1));
    return File(destination);
  }

  /// Extracts the archive at this path into [destination], restoring permissions and times.
  ///
  /// Throws [FormatException] on a corrupt archive or a wrong [password], [UnsupportedError]
  /// for a format the native library is needed for and it did not load.
  Future<Directory> extractTo(String destination, {String? password}) async {
    await Isolate.run(() => _NativeArchive.extract(path, destination, password));
    return Directory(destination);
  }

  /// Extracts synchronously; see [extractTo].
  Directory extractToSync(String destination, {String? password}) {
    _NativeArchive.extract(path, destination, password);
    return Directory(destination);
  }

  /// The entries of the archive at this path, without extracting.
  Future<List<ArchiveEntry>> archiveEntries({String? password}) async {
    return Isolate.run(() => _NativeArchive.list(path, password));
  }

  /// Compresses this file into [destination] with [codec], read from the extension by default.
  Future<File> compressTo(String destination, {Compression? codec, int? level}) async {
    final c = codec ?? _codecOf(destination);
    await Isolate.run(() => _NativeArchive.compress(c, path, destination, level ?? -1));
    return File(destination);
  }

  /// Decompresses this single-stream file into [destination]; the codec is this path's extension.
  Future<File> decompressTo(String destination, {Compression? codec}) async {
    final c = codec ?? _codecOf(path);
    await Isolate.run(() => _NativeArchive.decompress(c, path, destination));
    return File(destination);
  }

  /// gzip this file into [destination].
  Future<File> gzipTo(String destination, {int? level}) =>
      compressTo(destination, codec: Compression.gzip, level: level);

  /// gunzip this file into [destination].
  Future<File> gunzipTo(String destination) => decompressTo(destination, codec: Compression.gzip);

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

/// The archive functions of `dart_toolkit_native`, by file path.
final class _NativeArchive {
  static final _lib = Native.require('archives');
  static final _list = _lib
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr, Pointer<Pointer<Uint8>>, Pointer<IntPtr>),
        int Function(Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<IntPtr>)
      >('tk_archive_list');
  static final _extract = _lib
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr),
        int Function(Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint8>, int)
      >('tk_archive_extract');
  static final _create = _lib
      .lookupFunction<
        Int32 Function(Uint32, Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr, Int32),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint8>, int, int)
      >('tk_archive_create');
  static final _compress = _lib
      .lookupFunction<
        Int32 Function(Uint32, Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr, Int32),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int, int)
      >('tk_compress');
  static final _decompress = _lib
      .lookupFunction<
        Int32 Function(Uint32, Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int)
      >('tk_decompress');
  static void _check(int code) {
    if (code < 0) throw FormatException(Native.lastError());
  }

  static List<ArchiveEntry> list(String path, String? password) {
    final Uint8List data;
    try {
      data = Native.withText(
        path,
        (p, pl) => Native.withText(password, (pw, pwl) => Native.take((out, len) => _list(p, pl, pw, pwl, out, len))),
      );
    } on StateError catch (e) {
      throw FormatException(e.message);
    }
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

  static int extract(String path, String dest, String? password) => Native.withText(
    path,
    (p, pl) => Native.withText(
      dest,
      (d, dl) => Native.withText(password, (pw, pwl) {
        final n = _extract(p, pl, d, dl, pw, pwl);
        _check(n);
        return n;
      }),
    ),
  );

  static int create(Archive format, String src, String dest, String? password, int level) => Native.withText(
    src,
    (s, sl) => Native.withText(
      dest,
      (d, dl) => Native.withText(password, (pw, pwl) {
        final n = _create(format.index, s, sl, d, dl, pw, pwl, level);
        _check(n);
        return n;
      }),
    ),
  );

  static void compress(Compression codec, String src, String dest, int level) => Native.withText(
    src,
    (s, sl) => Native.withText(dest, (d, dl) => _check(_compress(codec.index, s, sl, d, dl, level))),
  );

  static void decompress(Compression codec, String src, String dest) =>
      Native.withText(src, (s, sl) => Native.withText(dest, (d, dl) => _check(_decompress(codec.index, s, sl, d, dl))));
}
