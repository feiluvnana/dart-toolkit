part of '../../native.dart';

/// The toolkit's native library, `dart_toolkit_native`: one Rust `cdylib` with the same
/// functions on every platform, shipped prebuilt inside the package. `hash` and the archive
/// half of `fs` are thin bindings to it and throw [UnsupportedError] when it did not load.
///
/// Lookup order: `DART_TOOLKIT_NATIVE` (a path), the directory of the running executable, then
/// `native/prebuilt/<os>_<arch>/` inside the package.
///
/// {@category Native}
abstract final class Native {
  static final DynamicLibrary? _library = _load();
  static String? _reason;

  /// Whether the library loaded; [reason] says why not.
  static bool get isAvailable => _library != null;

  /// Why the library did not load, or `null`.
  static String? get reason {
    _library;
    return _reason;
  }

  /// The ABI version the library reports.
  static int get version =>
      _library == null ? 0 : _library!.lookupFunction<Uint32 Function(), int Function()>('tk_version')();

  static DynamicLibrary? _load() {
    final candidates = <String>[
      ?Platform.environment['DART_TOOLKIT_NATIVE'],
      p.join(p.dirname(Platform.resolvedExecutable), NativeBridge.fileName),
    ];
    // Inside the package, for `dart run` from a checkout or a pub cache.
    final root = _packageRoot();
    if (root != null) candidates.add(p.join(root, 'native', 'prebuilt', NativeBridge.target, NativeBridge.fileName));
    final failures = <String>[];
    for (final path in candidates) {
      if (!File(path).existsSync()) continue;
      try {
        return DynamicLibrary.open(path);
      } catch (e) {
        failures.add('$path: $e');
      }
    }
    _reason = failures.isEmpty ? 'no $NativeBridge.fileName at ${candidates.join(', ')}' : failures.join('; ');
    return null;
  }

  /// The package root, from the location of this library.
  static String? _packageRoot() {
    final uri = Isolate.resolvePackageUriSync(Uri.parse('package:dart_toolkit/core.dart'));
    if (uri == null || uri.scheme != 'file') return null;
    return p.dirname(p.dirname(uri.toFilePath()));
  }
}

/// The FFI plumbing `fs` and `hash` bind through.
///
/// It is public only because those are separate libraries; nothing outside the package
/// should call it, and it is not covered by the versioning promise. What a program asks
/// about the native library is on [Native]: [Native.isAvailable], [Native.reason],
/// [Native.version].
abstract final class NativeBridge {
  /// The library's file name on this platform.
  static String get fileName => switch (Platform.operatingSystem) {
    'macos' => 'libdart_toolkit_native.dylib',
    'windows' => 'dart_toolkit_native.dll',
    _ => 'libdart_toolkit_native.so',
  };

  /// This platform's folder under `native/prebuilt/`; `make native` asks for it by name.
  static String get target {
    final arch = switch (Abi.current()) {
      Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => 'arm64',
      _ => 'x64',
    };
    return '${Platform.operatingSystem}_$arch';
  }

  /// The library, or an [UnsupportedError] that says what [feature] needed and why it is absent.
  static DynamicLibrary require(String feature) {
    final lib = Native._library;
    if (lib == null) {
      throw UnsupportedError('$feature needs dart_toolkit_native, which did not load: ${Native.reason}');
    }
    return lib;
  }

  /// The last error message the library recorded.
  static String lastError() {
    final f = require(
      'error',
    ).lookupFunction<Int32 Function(Pointer<Uint8>, IntPtr), int Function(Pointer<Uint8>, int)>('tk_last_error');
    const cap = 1024;
    final buf = alloc(cap);
    try {
      final n = f(buf, cap);
      if (n <= 0) return 'unknown error';
      // A message longer than the buffer is cut, and cutting mid-character would make
      // `utf8.decode` throw over the top of the error being reported.
      return utf8.decode(buf.asTypedList(n < cap ? n : cap), allowMalformed: true);
    } finally {
      free(buf, cap);
    }
  }

  /// The library's own allocator, rather than the host process's `malloc`.
  ///
  /// `DynamicLibrary.process()` cannot find `malloc` on every platform, and sharing an
  /// allocator across the boundary by coincidence is not worth the one saved export.
  static final Pointer<Uint8> Function(int) _alloc = require(
    'memory',
  ).lookupFunction<Pointer<Uint8> Function(IntPtr), Pointer<Uint8> Function(int)>('tk_alloc');
  static final void Function(Pointer<Uint8>, int) _dealloc = require(
    'memory',
  ).lookupFunction<Void Function(Pointer<Uint8>, IntPtr), void Function(Pointer<Uint8>, int)>('tk_dealloc');

  /// [size] bytes of native memory, released by [free].
  static Pointer<Uint8> alloc(int size) => _alloc(size);

  /// Releases what [alloc] returned; [size] is what it was asked for.
  static void free(Pointer<Uint8> ptr, int size) => _dealloc(ptr, size);

  /// Runs [body] with [data] copied into native memory.
  static R withBytes<R>(List<int> data, R Function(Pointer<Uint8> ptr, int len) body) {
    if (data.isEmpty) return body(nullptr, 0);
    final ptr = alloc(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      return body(ptr, data.length);
    } finally {
      free(ptr, data.length);
    }
  }

  /// Runs [body] with a native buffer of [size] bytes; returns the first [n] of them as told by [body].
  static Uint8List withOut(int size, int Function(Pointer<Uint8> out) body) {
    final ptr = alloc(size);
    try {
      final n = body(ptr);
      if (n < 0) throw StateError(lastError());
      return Uint8List.fromList(ptr.asTypedList(n));
    } finally {
      free(ptr, size);
    }
  }

  static final void Function(Pointer<Uint8>, int) _free = require(
    'free',
  ).lookupFunction<Void Function(Pointer<Uint8>, IntPtr), void Function(Pointer<Uint8>, int)>('tk_free');

  /// Runs [body] with a pointer-and-length pair the library fills with its own allocation;
  /// the bytes are copied out and the allocation freed. A negative return throws [StateError].
  static Uint8List take(int Function(Pointer<Pointer<Uint8>> out, Pointer<IntPtr> len) body) {
    final outSize = sizeOf<Pointer<Uint8>>(), lenSize = sizeOf<IntPtr>();
    final out = alloc(outSize).cast<Pointer<Uint8>>();
    final len = alloc(lenSize).cast<IntPtr>();
    try {
      if (body(out, len) < 0) throw StateError(lastError());
      final data = Uint8List.fromList(out.value.asTypedList(len.value));
      _free(out.value, len.value);
      return data;
    } finally {
      free(out.cast(), outSize);
      free(len.cast(), lenSize);
    }
  }

  static final _inflateNew = require(
    'content-encoding',
  ).lookupFunction<Pointer<Void> Function(Uint32), Pointer<Void> Function(int)>('tk_inflate_new');
  static final _inflatePush = require('content-encoding')
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, IntPtr, Pointer<Pointer<Uint8>>, Pointer<IntPtr>),
        int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<IntPtr>)
      >('tk_inflate_push');
  static final _inflateFree = require(
    'content-encoding',
  ).lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('tk_inflate_free');

  /// [body] with a `content-encoding` undone as it arrives; [codec] is 1 gzip, 2 deflate,
  /// 3 brotli, 4 zstd.
  ///
  /// It is here rather than in `http` so that `http` binds no FFI of its own: a decoder is a
  /// handle, three lookups and a pointer, and none of that belongs in a module about
  /// requests. Nothing is buffered — a chunk off the socket goes in and whatever it decoded
  /// to comes out, which is often nothing while a decoder fills its window.
  static Stream<List<int>> inflate(Stream<List<int>> body, int codec) async* {
    final handle = _inflateNew(codec);
    if (handle == nullptr) throw StateError(lastError());
    try {
      await for (final chunk in body) {
        final decoded = take((out, len) => withBytes(chunk, (ptr, size) => _inflatePush(handle, ptr, size, out, len)));
        if (decoded.isNotEmpty) yield decoded;
      }
    } finally {
      _inflateFree(handle);
    }
  }

  /// Runs [body] with [text] as UTF-8 in native memory; `null` becomes a null pointer.
  static R withText<R>(String? text, R Function(Pointer<Uint8> ptr, int len) body) =>
      text == null ? body(nullptr, 0) : withBytes(utf8.encode(text), body);
}
