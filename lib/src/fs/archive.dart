part of '../../fs.dart';

/// The formats `archiveTo` writes, by extension; the order is the native library's code.
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

/// Archives on [Path]: zip, 7z, rar (read), tar and its gz, xz, zstd and bzip2 forms, with a
/// password where the format has one. All of it runs in the native library; where it did not
/// load every call throws [UnsupportedError] with the reason.
///
/// ```dart
/// await src.archiveTo('backup.7z', password: 'pw');
/// await 'release.tar.zst'.path.extractTo(dir);
/// for (final e in await 'photos.rar'.path.entries(password: 'pw')) print(e);
/// ```
///
/// {@category Files}
extension PathArchiveExtensions on Path {
  /// Archives this file or directory into [destination] as a [Stream] of [ArchiveProgress].
  Stream<ArchiveProgress> archive(String destination, {String? password, int? level}) {
    final format = _Archive.of(destination);
    return _NativeArchive.createStream(format, path, destination, password, level ?? -1);
  }

  /// Archives this file or directory into [destination]; the format is [destination]'s
  /// extension. [level] is the codec's own scale; `null` is its default. [onProgress] receives
  /// each progress update. Returns the file.
  ///
  /// Writes `.zip`, `.7z`, `.tar` and `.tar.gz`/`.xz`/`.zst`/`.bz2` (or `.tgz`, …); any other
  /// extension is an [ArgumentError]. zip and 7z take a [password] (AES-256). A password for
  /// a tar, a `.rar` (read-only) and a [level] out of the codec's range are a
  /// [FormatException] that says so, and leave nothing behind. Only files, directories and
  /// links go in: a FIFO, socket or device is skipped.
  Future<File> archiveTo(
    String destination, {
    String? password,
    int? level,
    void Function(ArchiveProgress progress)? onProgress,
  }) async {
    if (onProgress != null) {
      await for (final p in archive(destination, password: password, level: level)) {
        onProgress(p);
      }
    } else {
      final format = _Archive.of(destination);
      await Isolate.run(() => _NativeArchive.create(format, path, destination, password, level ?? -1));
    }
    return File(destination);
  }

  /// Extracts the archive at this path into [destination] as a [Stream] of [ArchiveProgress].
  Stream<ArchiveProgress> extract(String destination, {String? password, String? only, bool trusted = false}) {
    return _NativeArchive.extractStream(path, destination, password, only, _flags(trusted));
  }

  /// Extracts the archive at this path into [destination], restoring permissions and times;
  /// [only] extracts just the entries that match a [glob] pattern: `only: '**/*.txt'`.
  /// [onProgress] receives each progress update.
  ///
  /// The format comes from the magic number, so a renamed archive still extracts; the name
  /// only tells a `.tar.gz` from a lone `.gz`.
  ///
  /// By default an archive may not write more than 200 times its own size (at least 1 GiB),
  /// loses setuid, setgid and sticky bits, and may not make a link out of [destination].
  /// [trusted] lifts all three; nothing lifts the refusal of an entry named outside it.
  ///
  /// Throws [FormatException] on a corrupt archive, a wrong [password] or one of the refusals
  /// above, [UnsupportedError] when the native library did not load.
  Future<Directory> extractTo(
    String destination, {
    String? password,
    String? only,
    bool trusted = false,
    void Function(ArchiveProgress progress)? onProgress,
  }) async {
    if (onProgress != null) {
      await for (final p in extract(destination, password: password, only: only, trusted: trusted)) {
        onProgress(p);
      }
    } else {
      await Isolate.run(() => _NativeArchive.extract(path, destination, password, only, _flags(trusted)));
    }
    return Directory(destination);
  }

  /// The contents of the one entry [name] — `'a/b.txt'`, as [entries] lists it — read
  /// without extracting anything else. The size cap is [extractTo]'s, and [trusted] lifts it.
  Future<Uint8List> entry(String name, {String? password, bool trusted = false}) =>
      Isolate.run(() => _NativeArchive.read(path, name, password, _flags(trusted)));

  /// The entries of the archive at this path, without extracting; the format is read from
  /// the file itself, as in [extractTo].
  Future<List<ArchiveEntry>> entries({String? password}) => Isolate.run(() => _NativeArchive.list(path, password));

  /// Compresses this file into [destination] with [codec] as a [Stream] of [ArchiveProgress].
  Stream<ArchiveProgress> compress(String destination, {Compression? codec, int? level}) {
    final c = codec ?? _codecOf(destination);
    return _NativeArchive.compressStream(c, path, destination, level ?? -1);
  }

  /// Compresses this file into [destination] with [codec], read from the extension by default.
  /// [onProgress] receives each progress update.
  Future<File> compressTo(
    String destination, {
    Compression? codec,
    int? level,
    void Function(ArchiveProgress progress)? onProgress,
  }) async {
    if (onProgress != null) {
      await for (final p in compress(destination, codec: codec, level: level)) {
        onProgress(p);
      }
    } else {
      final c = codec ?? _codecOf(destination);
      await Isolate.run(() => _NativeArchive.compress(c, path, destination, level ?? -1));
    }
    return File(destination);
  }

  /// Decompresses this single-stream file into [destination] as a [Stream] of [ArchiveProgress].
  Stream<ArchiveProgress> decompress(String destination, {Compression? codec, bool trusted = false}) {
    return _NativeArchive.decompressStream(codec, path, destination, _flags(trusted));
  }

  /// Decompresses this single-stream file into [destination].
  ///
  /// The codec is read from the magic number unless [codec] names one. Throws
  /// [FormatException] when the bytes are none of gzip, xz, zstd or bzip2, or decompress to
  /// more than [extractTo]'s cap — which leaves nothing at [destination] — unless [trusted].
  /// [onProgress] receives each progress update.
  Future<File> decompressTo(
    String destination, {
    Compression? codec,
    bool trusted = false,
    void Function(ArchiveProgress progress)? onProgress,
  }) async {
    if (onProgress != null) {
      await for (final p in decompress(destination, codec: codec, trusted: trusted)) {
        onProgress(p);
      }
    } else {
      await Isolate.run(() => _NativeArchive.decompress(codec, path, destination, _flags(trusted)));
    }
    return File(destination);
  }

  /// The native flags: trusted, and whether [extractTo]'s `only` folds case as [glob] does.
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
      _with([path, dest, password, only], (a) {
        final [(p, pl), (d, dl), (pw, pwl), (o, ol)] = a;
        _check(_extract(p, pl, d, dl, pw, pwl, o, ol, flags));
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
      _stream(_ExtractTask(path, dest, password, only, flags));

  static Uint8List read(String path, String name, String? password, int flags) => _with([path, name, password], (a) {
    final [(p, pl), (n, nl), (pw, pwl)] = a;
    return _take((out, len) => _read(p, pl, n, nl, pw, pwl, flags, out, len));
  });

  static void create(_Archive format, String src, String dest, String? password, int level) =>
      _with([src, dest, password], (a) {
        final [(s, sl), (d, dl), (pw, pwl)] = a;
        _check(_create(format.index, s, sl, d, dl, pw, pwl, level));
      });

  static Stream<ArchiveProgress> createStream(_Archive format, String src, String dest, String? password, int level) =>
      _stream(_CreateTask(format.index, src, dest, password, level));

  static void compress(Compression codec, String src, String dest, int level) => _with([src, dest], (a) {
    final [(s, sl), (d, dl)] = a;
    _check(_compress(codec.index, s, sl, d, dl, level));
  });

  static Stream<ArchiveProgress> compressStream(Compression codec, String src, String dest, int level) =>
      _stream(_CompressTask(codec.index, src, dest, level));

  /// A `null` codec asks the library to read the stream's magic number.
  static const _detect = 0xFFFFFFFF;

  static void decompress(Compression? codec, String src, String dest, int flags) => _with([src, dest], (a) {
    final [(s, sl), (d, dl)] = a;
    _check(_decompress(codec?.index ?? _detect, s, sl, d, dl, flags));
  });

  static Stream<ArchiveProgress> decompressStream(Compression? codec, String src, String dest, int flags) =>
      _stream(_DecompressTask(codec?.index, src, dest, flags));
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
