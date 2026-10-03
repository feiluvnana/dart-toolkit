part of '../../fs.dart';

/// The container formats `compressTo` writes, by extension; the order is the native library's code.
/// `.rar` is read-only, and the library refuses it by name.
enum _Archive {
  zip('.zip'),
  sevenZip('.7z'),
  tar('.tar'),
  tarGz('.tar.gz'),
  tarXz('.tar.xz'),
  tarZst('.tar.zst'),
  tarBz2('.tar.bz2'),
  rar('.rar');

  final String extension;
  const _Archive(this.extension);

  static _Archive of(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.tgz')) return tarGz;
    if (lower.endsWith('.txz')) return tarXz;
    if (lower.endsWith('.tzst')) return tarZst;
    if (lower.endsWith('.tbz2')) return tarBz2;
    for (final a in values) {
      if (lower.endsWith(a.extension)) return a;
    }
    throw ArgumentError(
      'No archive format for "$path"; write one of ${[for (final a in values)
        if (a != rar) a.extension].join(', ')}',
    );
  }

  static bool isArchiveFormat(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.tgz') || lower.endsWith('.txz') || lower.endsWith('.tzst') || lower.endsWith('.tbz2')) {
      return true;
    }
    for (final a in values) {
      if (lower.endsWith(a.extension)) return true;
    }
    return false;
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

/// Progress of an archive, extraction, or compression operation.
///
/// Implements [TaskProgress] from `core.dart` so it renders in CLI progress bars,
/// task boards, and gauges automatically.
///
/// {@category Files}
final class ArchiveProgress implements TaskProgress {
  /// The entry or file currently being processed.
  final String path;

  /// Bytes processed so far for the entire archive.
  final int bytes;

  /// Total bytes expected, or `null` if unknown.
  final int? bytesTotal;

  /// Number of entries / files processed so far.
  final int completed;

  /// Total number of entries / files in the archive, or `null` if unknown.
  @override
  final int? total;

  /// Operation status: `null` while running, `'done'` when complete.
  @override
  final String? status;

  @override
  final Object? error;

  const ArchiveProgress({
    required this.path,
    this.bytes = 0,
    this.bytesTotal,
    this.completed = 0,
    this.total,
    this.status,
    this.error,
  });

  @override
  String get taskId => path;

  @override
  String get label => path;

  @override
  double? get ratio => switch (bytesTotal) {
    final all? when all > 0 => (bytes / all).clamp(0.0, 1.0),
    _ => switch (total) {
      final all? when all > 0 => (completed / all).clamp(0.0, 1.0),
      _ => null,
    },
  };

  @override
  int? get received => bytes;

  @override
  bool get isDone => status != null;

  @override
  String toString() =>
      'ArchiveProgress($path, ${bytes.humanBytes}${bytesTotal != null ? '/${bytesTotal!.humanBytes}' : ''}, $completed/${total ?? '?'}${status != null ? ', status: $status' : ''})';
}

/// Archives and compression on [Path]: zip, 7z, rar (read), tar and its gz, xz, zstd and bzip2 forms,
/// and single-stream gzip, xz, zstd and bzip2.
///
/// ```dart
/// await src.compressTo('backup.7z', password: 'pw');
/// await 'release.tar.zst'.path.decompressTo(dir);
/// for (final e in await 'photos.rar'.path.entries(password: 'pw')) print(e);
/// ```
///
/// {@category Files}
extension PathArchiveExtensions on Path {

  /// Whether this path represents an archive container format (.zip, .7z, .rar, .tar, etc.)
  /// by file extension, magic bytes, or container contents.
  bool get isArchive => _Archive.isArchiveFormat(path) || _hasContainerMagic(path) || _hasArchiveEntries(path);

  /// Decompresses this archive or compressed file into [destination].
  ///
  /// If this file is a container archive (e.g. `.zip`, `.7z`, `.rar`, `.tar`, `.tar.gz`),
  /// it is extracted into the directory at [destination].
  /// If [flatten] is true, files in any extracted subdirectories are moved directly into
  /// [destination], and the empty intermediate directories are removed.
  ///
  /// If this file is a single-stream compressed file (`.gz`, `.xz`, `.zst`, `.bz2`),
  /// it is decompressed to the file at [destination].
  Future<Path> decompressTo(
    String destination, {
    String? password,
    String? only,
    bool trusted = false,
    bool flatten = false,
    Compression? codec,
    bool? asArchive,
    void Function(ArchiveProgress progress)? onProgress,
  }) async {
    final dest = Path(destination);
    final absPath = p.absolute(path);
    final absDest = p.absolute(dest.path);

    final isContainer = asArchive ??
        (codec == null &&
            (isArchive ||
                password != null ||
                only != null ||
                flatten ||
                _Archive.isArchiveFormat(path) ||
                await FileSystemEntity.isDirectory(absDest)));

    if (!isContainer) {
      // Single-stream decompression to file
      if (onProgress != null) {
        await for (final p in _NativeArchive.decompressStream(codec, absPath, absDest, _flags(trusted))) {
          onProgress(p);
        }
      } else {
        await Isolate.run(() => _NativeArchive.decompress(codec, absPath, absDest, _flags(trusted)));
      }
      return dest;
    }

    // Container archive extraction to directory
    Set<Path> dirsBefore = const {};
    if (flatten && await dest.exists()) {
      dirsBefore = await dest.dirs().toSet();
    }

    if (onProgress != null) {
      await for (final p in _NativeArchive.extractStream(absPath, absDest, password, only, _flags(trusted))) {
        onProgress(p);
      }
    } else {
      await Isolate.run(() => _NativeArchive.extract(absPath, absDest, password, only, _flags(trusted)));
    }

    if (flatten) {
      final newDirs = (await dest.dirs().toSet()).difference(dirsBefore);
      for (final dir in newDirs) {
        await for (final file in dir.files(recursive: true)) {
          final target = dest / file.name;
          await file.move(target, overwrite: true);
        }
        await dir.delete(recursive: true);
      }
    }

    return dest;
  }

  /// Unbundles this archive in-place into its parent directory.
  ///
  /// If [flatten] is true, files inside any extracted subdirectory are moved directly
  /// into the parent directory and the intermediate directory is deleted.
  /// If [cleanup] is true, the archive file itself is deleted after successful unbundling.
  Future<Path> unbundle({
    bool cleanup = false,
    bool flatten = false,
    String? password,
    String? only,
    bool trusted = false,
    void Function(ArchiveProgress progress)? onProgress,
  }) async {
    final targetDir = parent;
    await decompressTo(
      targetDir.path,
      password: password,
      only: only,
      trusted: trusted,
      flatten: flatten,
      asArchive: true,
      onProgress: onProgress,
    );
    if (cleanup) {
      await delete();
    }
    return targetDir;
  }

  /// Bundles this directory or file into an archive.
  ///
  /// Destination defaults to `parent / '$name.zip'` if omitted.
  /// If [flatten] is true, files in any subdirectories are bundled at the root level of the archive.
  /// If [cleanup] is true, the source directory or file is deleted after bundling.
  Future<Path> bundle({
    String? destination,
    bool cleanup = false,
    bool flatten = false,
    String? password,
    int? level,
    void Function(ArchiveProgress progress)? onProgress,
  }) async {
    final dest = destination != null ? Path(destination) : (parent / '$name.zip');
    final absDest = p.absolute(dest.path);
    final absPath = p.absolute(path);

    if (cleanup && (p.equals(absPath, absDest) || p.isWithin(absPath, absDest))) {
      throw StateError(
        'Cannot cleanup source directory when destination archive is inside it: $absDest',
      );
    }

    if (flatten && await FileSystemEntity.isDirectory(path)) {
      final tempDir = Directory.systemTemp.createTempSync('bundle_flatten_');
      try {
        await for (final file in files(recursive: true)) {
          final target = Path(tempDir.path) / file.name;
          await file.copy(target, overwrite: true);
        }
        await Path(tempDir.path).compressTo(
          absDest,
          password: password,
          level: level,
          onProgress: onProgress,
        );
      } finally {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    } else {
      await compressTo(
        absDest,
        password: password,
        level: level,
        onProgress: onProgress,
      );
    }

    if (cleanup) {
      await delete(recursive: true);
    }

    return dest;
  }

  /// Decompresses this archive or compressed stream into [destination] as a [Stream] of [ArchiveProgress].
  Stream<ArchiveProgress> decompress(
    String destination, {
    Compression? codec,
    String? password,
    String? only,
    bool trusted = false,
    bool? asArchive,
  }) {
    final absPath = p.absolute(path);
    final absDest = p.absolute(destination);
    final isContainer = asArchive ??
        (codec == null &&
            (isArchive ||
                password != null ||
                only != null ||
                _Archive.isArchiveFormat(path) ||
                Directory(absDest).existsSync()));
    if (!isContainer) {
      return _NativeArchive.decompressStream(codec, absPath, absDest, _flags(trusted));
    }
    return _NativeArchive.extractStream(absPath, absDest, password, only, _flags(trusted));
  }

  /// The contents of the one entry [name] — `'a/b.txt'`, as [entries] lists it — read
  /// without extracting anything else. The size cap is [decompressTo]'s, and [trusted] lifts it.
  Future<Uint8List> entry(String name, {String? password, bool trusted = false}) =>
      Isolate.run(() => _NativeArchive.read(p.absolute(path), name, password, _flags(trusted)));

  /// The entries of the archive at this path, without extracting; the format is read from
  /// the file itself, as in [decompressTo].
  Future<List<ArchiveEntry>> entries({String? password}) => Isolate.run(() => _NativeArchive.list(p.absolute(path), password));

  /// Compresses or archives this file or directory into [destination] as a [Stream] of [ArchiveProgress].
  Stream<ArchiveProgress> compress(
    String destination, {
    Compression? codec,
    String? password,
    int? level,
  }) {
    final absPath = p.absolute(path);
    final absDest = p.absolute(destination);
    if (codec == null && (_Archive.isArchiveFormat(destination) || FileSystemEntity.isDirectorySync(absPath))) {
      final format = _Archive.of(destination);
      return _NativeArchive.createStream(format, absPath, absDest, password, level ?? -1);
    }
    final c = codec ?? _codecOf(destination);
    return _NativeArchive.compressStream(c, absPath, absDest, level ?? -1);
  }

  /// Compresses or archives this file or directory into [destination].
  ///
  /// If [destination] is a container archive format (e.g. `.zip`, `.7z`, `.tar`, `.tar.gz`),
  /// this file or directory is archived into [destination].
  /// If [destination] is a single-stream compression format (`.gz`, `.xz`, `.zst`, `.bz2`),
  /// this file is compressed into [destination].
  ///
  /// [level] is the codec's own scale; `null` is its default. [onProgress] receives
  /// each progress update. Returns the destination [File].
  Future<File> compressTo(
    String destination, {
    Compression? codec,
    String? password,
    int? level,
    void Function(ArchiveProgress progress)? onProgress,
  }) async {
    final absPath = p.absolute(path);
    final absDest = p.absolute(destination);

    if (codec == null && (_Archive.isArchiveFormat(destination) || await FileSystemEntity.isDirectory(absPath))) {
      final format = _Archive.of(destination);
      if (onProgress != null) {
        await for (final p in compress(destination, password: password, level: level)) {
          onProgress(p);
        }
      } else {
        await Isolate.run(() => _NativeArchive.create(format, absPath, absDest, password, level ?? -1));
      }
      return File(destination);
    }

    if (onProgress != null) {
      await for (final p in compress(destination, codec: codec, level: level)) {
        onProgress(p);
      }
    } else {
      final c = codec ?? _codecOf(destination);
      await Isolate.run(() => _NativeArchive.compress(c, absPath, absDest, level ?? -1));
    }
    return File(destination);
  }

  /// The native flags: trusted, and whether [decompressTo]'s `only` folds case as [glob] does.
  static int _flags(bool trusted) => (trusted ? 1 : 0) | (Platform.isMacOS || Platform.isWindows ? 2 : 0);

  static Compression _codecOf(String path) {
    final lower = path.toLowerCase();
    for (final c in Compression.values) {
      if (lower.endsWith(c.extension)) return c;
    }
    throw ArgumentError(
      'No codec for "$path"; extensions are ${Compression.values.map((c) => c.extension).join(', ')}',
    );
  }

  static bool _hasContainerMagic(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return false;
    try {
      final len = file.lengthSync();
      if (len < 4) return false;
      final raf = file.openSync(mode: FileMode.read);
      try {
        final bytes = raf.readSync(len < 265 ? len : 265);
        if (bytes.length >= 4 &&
            bytes[0] == 0x50 &&
            bytes[1] == 0x4B &&
            (bytes[2] == 3 || bytes[2] == 5 || bytes[2] == 7)) {
          return true;
        }
        if (bytes.length >= 6 &&
            bytes[0] == 0x37 &&
            bytes[1] == 0x7A &&
            bytes[2] == 0xBC &&
            bytes[3] == 0xAF &&
            bytes[4] == 0x27 &&
            bytes[5] == 0x1C) {
          return true;
        }
        if (bytes.length >= 7 &&
            bytes[0] == 0x52 &&
            bytes[1] == 0x61 &&
            bytes[2] == 0x72 &&
            bytes[3] == 0x21 &&
            bytes[4] == 0x1A &&
            bytes[5] == 0x07) {
          return true;
        }
        if (bytes.length >= 262 &&
            bytes[257] == 0x75 &&
            bytes[258] == 0x73 &&
            bytes[259] == 0x74 &&
            bytes[260] == 0x61 &&
            bytes[261] == 0x72) {
          return true;
        }
      } finally {
        raf.closeSync();
      }
    } catch (_) {}
    return false;
  }

  static bool _hasArchiveEntries(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return false;
    try {
      final list = _NativeArchive.list(p.absolute(filePath), null);
      return list.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}

typedef _U8 = Pointer<Uint8>;
typedef _Text = (_U8, int);

typedef _NativeProgressCb =
    Void Function(Uint64 completed, Uint64 total, Uint64 bytes, Uint64 bytesTotal, Pointer<Uint8> name, IntPtr nameLen);

typedef _ProgressCb = Pointer<NativeFunction<_NativeProgressCb>>;

final class _NativeArchive {
  static final _lib = NativeBridge.require();
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
  static final _extractProgress = _lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr, Uint32, _ProgressCb),
        int Function(_U8, int, _U8, int, _U8, int, _U8, int, int, _ProgressCb)
      >('tk_archive_extract_progress');
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
  static final _createProgress = _lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr, Int32, _ProgressCb),
        int Function(int, _U8, int, _U8, int, _U8, int, int, _ProgressCb)
      >('tk_archive_create_progress');
  static final _compress = _lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, Int32),
        int Function(int, _U8, int, _U8, int, int)
      >('tk_compress');
  static final _compressProgress = _lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, Int32, _ProgressCb),
        int Function(int, _U8, int, _U8, int, int, _ProgressCb)
      >('tk_compress_progress');
  static final _decompress = _lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, Uint32),
        int Function(int, _U8, int, _U8, int, int)
      >('tk_decompress');
  static final _decompressProgress = _lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, Uint32, _ProgressCb),
        int Function(int, _U8, int, _U8, int, int, _ProgressCb)
      >('tk_decompress_progress');

  /// [texts] as UTF-8 in one native allocation; `null` and `''` are a null pointer.
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
    final data = _with([path, password], (a) {
      final [(p, pl), (pw, pwl)] = a;
      return _take((out, len) => _list(p, pl, pw, pwl, out, len));
    });

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
      _with([p.absolute(path), p.absolute(dest), password, only], (a) {
        final [(p0, pl), (d, dl), (pw, pwl), (o, ol)] = a;
        _check(_extract(p0, pl, d, dl, pw, pwl, o, ol, flags));
      });

  static _ProgressCb _callback(SendPort sendPort, List<NativeCallable<_NativeProgressCb>> callables) {
    final callable = NativeCallable<_NativeProgressCb>.isolateLocal((
      int completed,
      int total,
      int bytes,
      int bytesTotal,
      Pointer<Uint8> namePtr,
      int nameLen,
    ) {
      final name = (namePtr == nullptr || nameLen == 0) ? '' : utf8.decode(namePtr.asTypedList(nameLen));
      sendPort.send((completed, total, bytes, bytesTotal, name));
    });
    callables.add(callable);
    return callable.nativeFunction;
  }

  static Stream<ArchiveProgress> _stream(_ProgressTask task) {
    late final StreamController<ArchiveProgress> controller;
    final receivePort = ReceivePort();
    Isolate? isolateInstance;

    void cleanup() {
      receivePort.close();
      isolateInstance?.kill();
    }

    controller = StreamController<ArchiveProgress>(onCancel: cleanup);

    Isolate.spawn<(SendPort, _ProgressTask)>(_isolateEntrypoint, (receivePort.sendPort, task))
        .then((isolate) {
          isolateInstance = isolate;
          if (controller.isClosed) {
            cleanup();
            return;
          }
          receivePort.listen((message) {
            if (message == null) {
              cleanup();
              if (!controller.isClosed) controller.close();
            } else if (message is Map && message.containsKey('error')) {
              cleanup();
              if (!controller.isClosed) {
                controller.addError(FormatException(message['error'] as String));
              }
            } else if (message is (int, int, int, int, String)) {
              if (!controller.isClosed) {
                final (completed, total, bytes, bytesTotal, name) = message;
                controller.add(
                  ArchiveProgress(
                    path: name,
                    completed: completed,
                    total: total == 0 ? null : total,
                    bytes: bytes,
                    bytesTotal: bytesTotal == 0 ? null : bytesTotal,
                    status: (total > 0 && completed >= total) ? 'done' : null,
                  ),
                );
              }
            }
          });
        })
        .catchError((Object e) {
          cleanup();
          if (!controller.isClosed) controller.addError(e);
        });

    return controller.stream;
  }

  static void _isolateEntrypoint((SendPort, _ProgressTask) message) {
    final (sendPort, task) = message;
    final callables = <NativeCallable<_NativeProgressCb>>[];
    try {
      final cb = _callback(sendPort, callables);
      switch (task) {
        case _ExtractTask t:
          _with([t.path, t.dest, t.password, t.only], (a) {
            final [(p, pl), (d, dl), (pw, pwl), (o, ol)] = a;
            _check(_extractProgress(p, pl, d, dl, pw, pwl, o, ol, t.flags, cb));
          });
        case _CreateTask t:
          _with([t.src, t.dest, t.password], (a) {
            final [(s, sl), (d, dl), (pw, pwl)] = a;
            _check(_createProgress(t.formatIndex, s, sl, d, dl, pw, pwl, t.level, cb));
          });
        case _CompressTask t:
          _with([t.src, t.dest], (a) {
            final [(s, sl), (d, dl)] = a;
            _check(_compressProgress(t.codecIndex, s, sl, d, dl, t.level, cb));
          });
        case _DecompressTask t:
          _with([t.src, t.dest], (a) {
            final [(s, sl), (d, dl)] = a;
            _check(_decompressProgress(t.codecIndex ?? _detect, s, sl, d, dl, t.flags, cb));
          });
      }
      sendPort.send(null);
    } catch (e) {
      final msg = e is FormatException ? e.message : e.toString();
      sendPort.send({'error': msg});
    } finally {
      for (final c in callables) {
        c.close();
      }
    }
  }

  static Stream<ArchiveProgress> extractStream(String path, String dest, String? password, String? only, int flags) =>
      _stream(_ExtractTask(p.absolute(path), p.absolute(dest), password, only, flags));

  static Uint8List read(String path, String name, String? password, int flags) => _with([p.absolute(path), name, password], (a) {
    final [(p0, pl), (n, nl), (pw, pwl)] = a;
    return _take((out, len) => _read(p0, pl, n, nl, pw, pwl, flags, out, len));
  });

  static void create(_Archive format, String src, String dest, String? password, int level) =>
      _with([p.absolute(src), p.absolute(dest), password], (a) {
        final [(s, sl), (d, dl), (pw, pwl)] = a;
        _check(_create(format.index, s, sl, d, dl, pw, pwl, level));
      });

  static Stream<ArchiveProgress> createStream(_Archive format, String src, String dest, String? password, int level) =>
      _stream(_CreateTask(format.index, p.absolute(src), p.absolute(dest), password, level));

  static void compress(Compression codec, String src, String dest, int level) => _with([p.absolute(src), p.absolute(dest)], (a) {
    final [(s, sl), (d, dl)] = a;
    _check(_compress(codec.index, s, sl, d, dl, level));
  });

  static Stream<ArchiveProgress> compressStream(Compression codec, String src, String dest, int level) =>
      _stream(_CompressTask(codec.index, p.absolute(src), p.absolute(dest), level));

  /// A `null` codec asks the library to read the stream's magic number.
  static const _detect = 0xFFFFFFFF;

  static void decompress(Compression? codec, String src, String dest, int flags) => _with([p.absolute(src), p.absolute(dest)], (a) {
    final [(s, sl), (d, dl)] = a;
    _check(_decompress(codec?.index ?? _detect, s, sl, d, dl, flags));
  });

  static Stream<ArchiveProgress> decompressStream(Compression? codec, String src, String dest, int flags) =>
      _stream(_DecompressTask(codec?.index, p.absolute(src), p.absolute(dest), flags));
}

sealed class _ProgressTask {}

final class _ExtractTask extends _ProgressTask {
  final String path;
  final String dest;
  final String? password;
  final String? only;
  final int flags;

  _ExtractTask(this.path, this.dest, this.password, this.only, this.flags);
}

final class _CreateTask extends _ProgressTask {
  final int formatIndex;
  final String src;
  final String dest;
  final String? password;
  final int level;

  _CreateTask(this.formatIndex, this.src, this.dest, this.password, this.level);
}

final class _CompressTask extends _ProgressTask {
  final int codecIndex;
  final String src;
  final String dest;
  final int level;

  _CompressTask(this.codecIndex, this.src, this.dest, this.level);
}

final class _DecompressTask extends _ProgressTask {
  final int? codecIndex;
  final String src;
  final String dest;
  final int flags;

  _DecompressTask(this.codecIndex, this.src, this.dest, this.flags);
}
