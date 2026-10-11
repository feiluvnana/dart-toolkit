/// The `lib2` seam over the `dart_toolkit_chrome` cdylib (ABI 1).
///
/// Only `chrome` imports this file — never `dart:ffi` directly — so only programs
/// that drive a browser compile FFI (r56). Every call goes through the native CDP
/// engine (Phase D cutover): when the library does not load, [require] throws
/// [UnsupportedError] naming why (r50: no Dart fallback).
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:typed_data';

/// ABI of `dart_toolkit_chrome` this seam binds.
const lib2ChromeAbi = 1;

/// The `chrome` cdylib binding for `lib2`: opened once, on first use.
abstract final class Lib2Chrome {
  static ffi.DynamicLibrary? _lib;
  static String? _reason;
  static bool _tried = false;

  /// Whether the native CDP engine is usable right now.
  static bool get isAvailable => _load() != null;

  /// Why the library does not load, or `null` when it does.
  static String? get reason {
    _load();
    return _reason;
  }

  /// The library, or throws [UnsupportedError] naming why it is absent (r50).
  static ffi.DynamicLibrary require() {
    final lib = _load();
    if (lib == null) {
      throw UnsupportedError('dart_toolkit_chrome did not load: $_reason');
    }
    return lib;
  }

  static ffi.DynamicLibrary? _load() {
    if (!_tried) {
      _tried = true;
      _lib = _open();
    }
    return _lib;
  }

  /// For tests: forget the cached open so the next call looks again.
  static void resetForTest() {
    _tried = false;
    _lib = null;
    _reason = null;
  }

  static ffi.DynamicLibrary? _open() {
    _reason = null;
    final override = _override;
    final built = _built;
    final candidates = override != null
        ? [override]
        : [
            _join([io.File(io.Platform.resolvedExecutable).parent.path, _fileOf('chrome')]),
            ?built,
          ];
    final failures = <String>[];
    for (final path in candidates) {
      final lib = _at(path, failures);
      if (lib != null) return lib;
    }
    _reason = failures.isNotEmpty
        ? failures.join('; ')
        : override != null
        ? 'DART_TOOLKIT_CHROME_LIB file not found: $override'
        : 'not installed: no ${_fileOf('chrome')} at ${candidates.join(', ')}';
    return null;
  }

  static ffi.DynamicLibrary? _at(String path, List<String> failures) {
    if (!io.File(path).existsSync()) return null;
    try {
      final lib = ffi.DynamicLibrary.open(path);
      final ver = _version(lib);
      if (ver == lib2ChromeAbi) return lib;
      lib.close();
      failures.add('$path reported ABI version $ver, expected $lib2ChromeAbi');
    } catch (e) {
      failures.add('$path: $e');
    }
    return null;
  }

  static int _version(ffi.DynamicLibrary lib) {
    try {
      return lib.lookupFunction<ffi.Uint32 Function(), int Function()>('tk_version')();
    } catch (_) {
      return 0;
    }
  }

  /// `DART_TOOLKIT_CHROME_LIB`'s file (`DART_TOOLKIT_CHROME` stays the browser
  /// executable per PLAN.md §9): relative against the working directory.
  static String? get _override {
    final env = io.Platform.environment['DART_TOOLKIT_CHROME_LIB'];
    if (env == null) return null;
    return io.File(env).absolute.path;
  }

  /// `native2/lib/<os>_<arch>/<file>` inside the package, or `null` without
  /// the package sources (a compiled executable has no package).
  static String? get _built {
    final root = _packageRoot();
    if (root == null || !io.File(_join([root, 'native2', 'Cargo.toml'])).existsSync()) {
      return null;
    }
    return _join([root, 'native2', 'lib', _target, _fileOf('chrome')]);
  }

  static String _fileOf(String name, [String? target]) => switch ((target ?? _target).split('_').first) {
    'macos' => 'libdart_toolkit_$name.dylib',
    'windows' => 'dart_toolkit_$name.dll',
    _ => 'libdart_toolkit_$name.so',
  };

  static String get _target {
    final arch = switch (ffi.Abi.current()) {
      ffi.Abi.macosArm64 || ffi.Abi.linuxArm64 || ffi.Abi.windowsArm64 => 'arm64',
      _ => 'x64',
    };
    return '${io.Platform.operatingSystem}_$arch';
  }

  static String? _packageRoot() {
    final uri = Isolate.resolvePackageUriSync(Uri.parse('package:dart_toolkit/core.dart'));
    if (uri == null || uri.scheme != 'file') return null;
    return io.File(uri.toFilePath()).parent.parent.path;
  }

  /// The last error message the library recorded (call on the same thread,
  /// synchronously after the failing call).
  static String lastError() {
    const cap = 1024;
    final buf = alloc(cap);
    try {
      final n = _lastError(buf, cap);
      if (n <= 0) return 'unknown error';
      return utf8.decode(buf.asTypedList(n < cap ? n : cap), allowMalformed: true);
    } finally {
      free(buf, cap);
    }
  }

  static final _lastError = require()
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        int Function(ffi.Pointer<ffi.Uint8>, int)
      >('tk_last_error');

  static final _alloc = require()
      .lookupFunction<ffi.Pointer<ffi.Uint8> Function(ffi.IntPtr), ffi.Pointer<ffi.Uint8> Function(int)>('tk_alloc');

  static final _dealloc = require()
      .lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        void Function(ffi.Pointer<ffi.Uint8>, int)
      >('tk_dealloc');

  static final _free = require()
      .lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        void Function(ffi.Pointer<ffi.Uint8>, int)
      >('tk_free');

  /// [size] bytes of native memory, released by [free].
  static ffi.Pointer<ffi.Uint8> alloc(int size) => _alloc(size);

  /// Releases what [alloc] returned; [size] is what it was asked for.
  static void free(ffi.Pointer<ffi.Uint8> ptr, int size) => _dealloc(ptr, size);

  /// Runs [body] with [data] copied into native memory.
  static R withBytes<R>(List<int> data, R Function(ffi.Pointer<ffi.Uint8> ptr, int len) body) {
    if (data.isEmpty) return body(ffi.nullptr, 0);
    final ptr = alloc(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      return body(ptr, data.length);
    } finally {
      free(ptr, data.length);
    }
  }

  /// Runs [body] with [text] as UTF-8 in native memory.
  static R withText<R>(String text, R Function(ffi.Pointer<ffi.Uint8> ptr, int len) body) =>
      withBytes(utf8.encode(text), body);

  /// Runs [body] with a pointer-and-length pair the library fills with a buffer it hands
  /// over (`give`, freed with `tk_free`); the bytes are copied out. A negative return
  /// throws [ChromeException] with what the library said.
  static Uint8List take(
    String op,
    int Function(ffi.Pointer<ffi.Pointer<ffi.Uint8>> out, ffi.Pointer<ffi.IntPtr> len) body,
  ) {
    final out = alloc(16).cast<ffi.Pointer<ffi.Uint8>>();
    final len = (out + 1).cast<ffi.IntPtr>();
    try {
      if (body(out, len) < 0) throw ChromeException('$op: ${lastError()}');
      final data = Uint8List.fromList(out.value.asTypedList(len.value));
      _free(out.value, len.value);
      return data;
    } finally {
      free(out.cast(), 16);
    }
  }
}

/// Thrown when Chrome interaction fails.
final class ChromeException implements Exception {
  final String message;

  const ChromeException(this.message);

  @override
  String toString() => 'ChromeException: $message';
}

String _join(List<String> parts) => parts.reduce(
  (a, b) => a.endsWith('/') || a.endsWith(io.Platform.pathSeparator) ? '$a$b' : '$a${io.Platform.pathSeparator}$b',
);
