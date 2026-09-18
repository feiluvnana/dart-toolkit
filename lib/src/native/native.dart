part of '../../native.dart';

/// The toolkit's native library, `dart_toolkit_native`: one Rust `cdylib` with the same
/// functions on every platform, shipped prebuilt inside the package. `crypto` and `fs` use it
/// when it loads and fall back to Dart, or throw [UnsupportedError], when it does not.
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

  /// The file name for this platform.
  static String get fileName => switch (Platform.operatingSystem) {
    'macos' => 'libdart_toolkit_native.dylib',
    'windows' => 'dart_toolkit_native.dll',
    _ => 'libdart_toolkit_native.so',
  };

  /// This platform's folder under `native/prebuilt/`.
  static String get target {
    final arch = switch (Abi.current()) {
      Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => 'arm64',
      _ => 'x64',
    };
    return '${Platform.operatingSystem}_$arch';
  }

  /// The library, or an [UnsupportedError] that says what [feature] needed and why it is absent.
  ///
  /// Callers look functions up on it: `Native.require('7z').lookupFunction<…>('tk_archive_extract')`.
  static DynamicLibrary require(String feature) {
    final lib = _library;
    if (lib == null) throw UnsupportedError('$feature needs dart_toolkit_native, which did not load: $reason');
    return lib;
  }

  static DynamicLibrary? _load() {
    final candidates = <String>[
      ?Platform.environment['DART_TOOLKIT_NATIVE'],
      p.join(p.dirname(Platform.resolvedExecutable), fileName),
    ];
    // Inside the package, for `dart run` from a checkout or a pub cache.
    final root = _packageRoot();
    if (root != null) candidates.add(p.join(root, 'native', 'prebuilt', target, fileName));
    final failures = <String>[];
    for (final path in candidates) {
      if (!File(path).existsSync()) continue;
      try {
        return DynamicLibrary.open(path);
      } catch (e) {
        failures.add('$path: $e');
      }
    }
    _reason = failures.isEmpty ? 'no $fileName at ${candidates.join(', ')}' : failures.join('; ');
    return null;
  }

  /// The package root, from the location of this library.
  static String? _packageRoot() {
    final uri = Isolate.resolvePackageUriSync(Uri.parse('package:dart_toolkit/core.dart'));
    if (uri == null || uri.scheme != 'file') return null;
    return p.dirname(p.dirname(uri.toFilePath()));
  }

  /// The last error message the library recorded.
  static String lastError() {
    final f = require(
      'error',
    ).lookupFunction<Int32 Function(Pointer<Uint8>, IntPtr), int Function(Pointer<Uint8>, int)>('tk_last_error');
    final buf = malloc(1024);
    try {
      final n = f(buf, 1024);
      return n <= 0 ? 'unknown error' : utf8.decode(buf.asTypedList(n < 1024 ? n : 1024));
    } finally {
      free(buf);
    }
  }

  static final Pointer<Uint8> Function(int) malloc = DynamicLibrary.process()
      .lookupFunction<Pointer<Uint8> Function(IntPtr), Pointer<Uint8> Function(int)>('malloc');
  static final void Function(Pointer<Uint8>) free = DynamicLibrary.process()
      .lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('free');

  /// Runs [body] with [data] copied into native memory.
  static R withBytes<R>(List<int> data, R Function(Pointer<Uint8> ptr, int len) body) {
    if (data.isEmpty) return body(nullptr, 0);
    final ptr = malloc(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      return body(ptr, data.length);
    } finally {
      free(ptr);
    }
  }

  /// Runs [body] with a native buffer of [size] bytes; returns the first [n] of them as told by [body].
  static Uint8List withOut(int size, int Function(Pointer<Uint8> out) body) {
    final ptr = malloc(size);
    try {
      final n = body(ptr);
      if (n < 0) throw StateError(lastError());
      return Uint8List.fromList(ptr.asTypedList(n));
    } finally {
      free(ptr);
    }
  }

  /// Runs [body] with [text] as UTF-8 in native memory; `null` becomes a null pointer.
  static R withText<R>(String? text, R Function(Pointer<Uint8> ptr, int len) body) =>
      text == null ? body(nullptr, 0) : withBytes(utf8.encode(text), body);
}
