part of '../../native.dart';

/// The toolkit's native library, `dart_toolkit_native`, shipped prebuilt inside the package.
/// What needs it throws [UnsupportedError] when it did not load.
///
/// Looked for at `DART_TOOLKIT_NATIVE` (a path, and then nowhere else), beside the running
/// executable, then in `native/prebuilt/<os>_<arch>/` inside the package.
///
/// {@category Native}
abstract final class NativeLib {
  static final DynamicLibrary? _library = _load();
  static String? _reason;

  /// Whether the library loaded; [reason] says why not.
  static bool get isAvailable => _library != null;

  /// Why the library did not load, or `null`.
  static String? get reason {
    _library;
    return _reason;
  }

  /// The ABI version this package was built against; a library reporting another is refused
  /// at load rather than failing later on a missing symbol.
  static const _abi = 3;

  static DynamicLibrary? _load() {
    final override = Platform.environment['DART_TOOLKIT_NATIVE'];
    final candidates = override != null
        ? [override]
        : [
            p.join(p.dirname(Platform.resolvedExecutable), NativeBridge.fileName),
            if (_packageRoot() case final root?)
              p.join(root, 'native', 'prebuilt', NativeBridge.target, NativeBridge.fileName),
          ];
    final failures = <String>[];
    for (final path in candidates) {
      if (!File(path).existsSync()) continue;
      try {
        final lib = DynamicLibrary.open(path);
        final ver = _version(lib);
        if (ver == _abi) return lib;
        failures.add('$path reported ABI version $ver, expected $_abi');
      } catch (e) {
        failures.add('$path: $e');
      }
    }
    _reason = failures.isNotEmpty
        ? failures.join('; ')
        : override != null
        ? 'DART_TOOLKIT_NATIVE file not found: $override'
        : 'no ${NativeBridge.fileName} at ${candidates.join(', ')}';
    return null;
  }

  static int _version(DynamicLibrary lib) {
    try {
      return lib.lookupFunction<Uint32 Function(), int Function()>('tk_version')();
    } catch (_) {
      return 0;
    }
  }

  static String? _packageRoot() {
    final uri = Isolate.resolvePackageUriSync(Uri.parse('package:dart_toolkit/core.dart'));
    return uri == null || uri.scheme != 'file' ? null : p.dirname(p.dirname(uri.toFilePath()));
  }
}

/// The FFI plumbing `fs`, `hash` and `http` bind through: public only because those are
/// separate libraries, and not covered by the versioning promise. Programs ask [NativeLib].
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

  /// The library, or an [UnsupportedError] that says why it is absent.
  static DynamicLibrary require() {
    final lib = NativeLib._library;
    if (lib == null) {
      throw UnsupportedError('dart_toolkit_native did not load: ${NativeLib.reason}');
    }
    return lib;
  }

  /// The last error message the library recorded.
  static String lastError() {
    const cap = 1024;
    final buf = alloc(cap);
    try {
      final n = _lastError(buf, cap);
      if (n <= 0) return 'unknown error';
      // A cut message may end mid-character.
      return utf8.decode(buf.asTypedList(n < cap ? n : cap), allowMalformed: true);
    } finally {
      free(buf, cap);
    }
  }

  static final _lastError = require()
      .lookupFunction<Int32 Function(Pointer<Uint8>, IntPtr), int Function(Pointer<Uint8>, int)>('tk_last_error');

  // The library's own allocator: `DynamicLibrary.process()` cannot find `malloc` everywhere.
  static final Pointer<Uint8> Function(int) _alloc = require()
      .lookupFunction<Pointer<Uint8> Function(IntPtr), Pointer<Uint8> Function(int)>('tk_alloc');
  static final void Function(Pointer<Uint8>, int) _dealloc = require()
      .lookupFunction<Void Function(Pointer<Uint8>, IntPtr), void Function(Pointer<Uint8>, int)>('tk_dealloc');
  // What the library allocated itself, as opposed to what [alloc] handed out.
  static final void Function(Pointer<Uint8>, int) _free = require()
      .lookupFunction<Void Function(Pointer<Uint8>, IntPtr), void Function(Pointer<Uint8>, int)>('tk_free');

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

  /// Runs [body] with a pointer-and-length pair the library fills with its own allocation;
  /// the bytes are copied out and the allocation freed. A negative return throws [StateError].
  static Uint8List take(int Function(Pointer<Pointer<Uint8>> out, Pointer<IntPtr> len) body) {
    final out = alloc(16).cast<Pointer<Uint8>>(), len = (out + 1).cast<IntPtr>();
    try {
      if (body(out, len) < 0) throw StateError(lastError());
      final data = Uint8List.fromList(out.value.asTypedList(len.value));
      _free(out.value, len.value);
      return data;
    } finally {
      free(out.cast(), 16);
    }
  }

  static final _inflateNew = require().lookupFunction<Pointer<Void> Function(Uint32), Pointer<Void> Function(int)>(
    'tk_inflate_new',
  );
  static final _inflateInto = require()
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr),
        int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint8>, int)
      >('tk_inflate_into');
  static final _inflateFinish = require().lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
    'tk_inflate_finish',
  );
  static final _inflateFree = require().lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'tk_inflate_free',
  );

  /// [body] with a `content-encoding` undone as it arrives; [codec] is 1 gzip, 3 brotli,
  /// 4 zstd. Here so `http` binds no FFI of its own. Corrupt data, and a body that ends
  /// before its compressed stream does, are a [FormatException].
  static Stream<List<int>> inflate(Stream<List<int>> body, int codec) async* {
    const inCap = 64 * 1024, outCap = 256 * 1024;
    final handle = _inflateNew(codec);
    if (handle == nullptr) throw FormatException(lastError());
    // One buffer each way for the handle's life; an output that fills one means more is pending.
    final input = alloc(inCap), output = alloc(outCap);
    final inView = input.asTypedList(inCap), outView = output.asTypedList(outCap);
    try {
      await for (final chunk in body) {
        for (var off = 0; off < chunk.length; off += inCap) {
          final n = chunk.length - off < inCap ? chunk.length - off : inCap;
          inView.setRange(0, n, chunk, off);
          for (var pending = n; ; pending = 0) {
            final w = _inflateInto(handle, input, pending, output, outCap);
            if (w < 0) throw FormatException(lastError());
            if (w > 0) yield outView.sublist(0, w);
            if (w < outCap) break;
          }
        }
      }
      // Skipped when the listener stopped early.
      if (_inflateFinish(handle) < 0) throw FormatException(lastError());
    } finally {
      _inflateFree(handle);
      free(input, inCap);
      free(output, outCap);
    }
  }

  static final _decodeText = require()
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr, Pointer<Pointer<Uint8>>, Pointer<IntPtr>),
        int Function(Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<IntPtr>)
      >('tk_decode_text');

  /// [bytes] read in the charset [label] names (any WHATWG label: `shift_jis`, `euc-kr`, …).
  /// An unknown label reads as UTF-8; malformed bytes become U+FFFD.

  static String decodeText(String label, Uint8List bytes) {
    final units = withText(
      label,
      (l, ll) => withBytes(bytes, (p, n) => take((out, len) => _decodeText(l, ll, p, n, out, len))),
    );
    return String.fromCharCodes(Uint16List.view(units.buffer, units.offsetInBytes, units.length ~/ 2));
  }

  /// Runs [body] with [text] as UTF-8 in native memory; `null` becomes a null pointer.
  static R withText<R>(String? text, R Function(Pointer<Uint8> ptr, int len) body) =>
      text == null ? body(nullptr, 0) : withBytes(utf8.encode(text), body);
}
