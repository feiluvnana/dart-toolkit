/// The seam over the `dart_toolkit_native` cdylib.
///
/// `core` stays free of `dart:ffi` (startup budget rule 50): only topics that make
/// a native call import this file — `hash`, `fs`, `archive`, `image`,
/// `process` — so a program that never touches them never compiles FFI.
///
/// Every call here goes through the native library (cutover, rule 42): when the
/// library does not load, [require] throws [UnsupportedError] naming why.
///
/// Long calls take a stop byte (`Pointer<Uint8>`, `nullptr` for none) and the
/// existing `tk_common` progress callback; synchronous short calls pass both
/// as null.
///
/// Scripts see only [Native] (via `native.dart`); the loader below and the
/// helpers after it are visible to the other seam files only.
library;

export 'errors.dart';

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:typed_data';

import 'errors.dart';
import 'jobs.dart';
import 'native_status.dart';

/// ABI of `dart_toolkit_native` this seam binds.
const _nativeAbi = 3;

/// Whether every native library loads (dart_toolkit_native, _chrome, _tui).
abstract final class Native {
  /// Whether every native library is there: the engine loads itself, and the
  /// chrome and tui library files exist. The chrome/tui seams are not compiled
  /// for this check (startup budget): only their files are looked up by path.
  /// In a fresh script with a missing file, the answer is not vacuously true.
  static bool get ok => reason == null;

  /// The first library that is missing, and why (`null` when all load).
  static String? get reason {
    if (_Engine._load() == null) {
      return _Engine._reason ?? 'dart_toolkit_native did not load';
    }
    final chrome = _missingLib('chrome', 'DART_TOOLKIT_CHROME_LIB');
    if (chrome != null) return 'dart_toolkit_chrome library file not found: $chrome';
    final tui = _missingLib('tui', 'DART_TOOLKIT_TUI_LIB');
    if (tui != null) return 'dart_toolkit_tui library file not found: $tui';
    return null;
  }

  /// The candidate for library [name] when none exists, else `null`. The env
  /// override names its file; otherwise beside the executable, else the built
  /// copy — the same files the seams open, without compiling them.
  static String? _missingLib(String name, String envKey) {
    final env = io.Platform.environment[envKey];
    if (env != null) {
      final path = io.File(env).absolute.path;
      return io.File(path).existsSync() ? null : path;
    }
    final beside = _join([io.File(io.Platform.resolvedExecutable).parent.path, _Engine._fileOf(name)]);
    if (io.File(beside).existsSync()) return null;
    final built = _builtLib(name);
    if (built != null && io.File(built).existsSync()) return null;
    return built ?? beside;
  }

  /// `native/lib/<os>_<arch>/<file>` inside the package, or `null` without
  /// the package sources (a compiled executable has no package).
  static String? _builtLib(String name) {
    final root = _Engine._packageRoot();
    if (root == null || !io.File(_join([root, 'native', 'Cargo.toml'])).existsSync()) {
      return null;
    }
    return _join([root, 'native', 'lib', _Engine._target, _Engine._fileOf(name)]);
  }
}

/// The `native` cdylib binding: opened once, on first use.
abstract final class _Engine {
  static ffi.DynamicLibrary? _lib;
  static String? _reason;
  static bool _tried = false;

  /// The library, or throws [UnsupportedError] naming why it is absent (rule 42).
  static ffi.DynamicLibrary require() {
    final lib = _load();
    if (lib == null) {
      throw UnsupportedError('dart_toolkit_native did not load: $_reason');
    }
    return lib;
  }

  static ffi.DynamicLibrary? _load() {
    NativeStatus.register(
      'dart_toolkit_native',
      NativeCheck(() => _load() != null, () {
        _load();
        return _reason;
      }, _reset),
    );
    if (!_tried) {
      _tried = true;
      _lib = _open();
    }
    return _lib;
  }

  /// Forgets the cached open so the next call looks again (tests only, behind
  /// [NativeReset]).
  static void _reset() {
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
            _join([io.File(io.Platform.resolvedExecutable).parent.path, _fileOf('native')]),
            ?built,
          ];
    final failures = <String>[];
    for (final path in candidates) {
      final lib = _at(path, failures);
      if (lib != null) return lib;
    }
    final install = override == null && built != null
        ? '; build it with `dart run tool/build_native.dart` (or `make native`)'
        : '';
    _reason = failures.isNotEmpty
        ? '${failures.join('; ')}$install'
        : override != null
        ? 'DART_TOOLKIT_NATIVE file not found: $override'
        : 'not installed: no ${_fileOf('native')} at ${candidates.join(', ')}$install';
    return null;
  }

  static ffi.DynamicLibrary? _at(String path, List<String> failures) {
    if (!io.File(path).existsSync()) return null;
    try {
      final lib = ffi.DynamicLibrary.open(path);
      final ver = _version(lib);
      if (ver == _nativeAbi) return lib;
      lib.close();
      failures.add('$path reported ABI version $ver, expected $_nativeAbi');
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

  /// `DART_TOOLKIT_NATIVE`'s file: relative against the working directory.
  static String? get _override {
    final env = io.Platform.environment['DART_TOOLKIT_NATIVE'];
    if (env == null) return null;
    return io.File(env).absolute.path;
  }

  /// `native/lib/<os>_<arch>/<file>` inside the package, or `null` without
  /// the package sources (a compiled executable has no package).
  static String? get _built {
    final root = _packageRoot();
    if (root == null || !io.File(_join([root, 'native', 'Cargo.toml'])).existsSync()) {
      return null;
    }
    return _join([root, 'native', 'lib', _target, _fileOf('native')]);
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

  /// Runs [body] with a native buffer of [size] bytes; returns the first [n]
  /// bytes as told by [body]. A negative return throws [NativeException].
  static Uint8List withOut(String op, int size, int Function(ffi.Pointer<ffi.Uint8> out) body) {
    final ptr = alloc(size);
    try {
      final n = body(ptr);
      if (n < 0) throw NativeException(op, lastError());
      return Uint8List.fromList(ptr.asTypedList(n));
    } finally {
      free(ptr, size);
    }
  }

  static Uint8List take(
    String op,
    int Function(ffi.Pointer<ffi.Pointer<ffi.Uint8>> out, ffi.Pointer<ffi.IntPtr> len) body,
  ) {
    // For `give` buffers, freed with `tk_free`.
    final out = alloc(16).cast<ffi.Pointer<ffi.Uint8>>();
    final len = (out + 1).cast<ffi.IntPtr>();
    try {
      if (body(out, len) < 0) throw NativeException(op, lastError());
      final data = Uint8List.fromList(out.value.asTypedList(len.value));
      _free(out.value, len.value);
      return data;
    } finally {
      free(out.cast(), 16);
    }
  }
}

String _join(List<String> parts) => parts.reduce(
  (a, b) => a.endsWith('/') || a.endsWith(io.Platform.pathSeparator) ? '$a$b' : '$a${io.Platform.pathSeparator}$b',
);

/// The engine's shared helpers for the other seam files: public here so they
/// stay in one place, hidden from scripts by `native.dart`'s export list.
///
/// The library, or throws [UnsupportedError] naming why it is absent (rule 42).
ffi.DynamicLibrary require() => _Engine.require();

/// [size] bytes of native memory, released by [free].
ffi.Pointer<ffi.Uint8> alloc(int size) => _Engine.alloc(size);

/// Releases what [alloc] returned; [size] is what it was asked for.
void free(ffi.Pointer<ffi.Uint8> ptr, int size) => _Engine.free(ptr, size);

/// Runs [body] with [data] copied into native memory.
R withBytes<R>(List<int> data, R Function(ffi.Pointer<ffi.Uint8> ptr, int len) body) => _Engine.withBytes(data, body);

/// Runs [body] with [text] as UTF-8 in native memory.
R withText<R>(String text, R Function(ffi.Pointer<ffi.Uint8> ptr, int len) body) => _Engine.withText(text, body);

/// Runs [body] with a native buffer of [size] bytes; returns the first [n]
/// bytes as told by [body]. A negative return throws [NativeException].
Uint8List withOut(String op, int size, int Function(ffi.Pointer<ffi.Uint8> out) body) =>
    _Engine.withOut(op, size, body);

/// Runs [body] with a pointer-and-length pair the library fills with a buffer
/// it hands over (`give`, freed with `tk_free`); the bytes are copied out.
Uint8List take(String op, int Function(ffi.Pointer<ffi.Pointer<ffi.Uint8>> out, ffi.Pointer<ffi.IntPtr> len) body) =>
    _Engine.take(op, body);

/// The last error message the library recorded (call on the same thread,
/// synchronously after the failing call).
String lastError() => _Engine.lastError();

/// [data] decoded from the charset [label] names (any WHATWG label: `euc-kr`, `shift_jis`,
/// `windows-1252` …) by the native engine. Malformed bytes become U+FFFD. Without the
/// library it is an [UnsupportedError] (rule 42).
String decodeCharset(String label, Uint8List data) {
  final out = alloc(16).cast<ffi.Pointer<ffi.Uint8>>();
  final len = (out + 1).cast<ffi.IntPtr>();
  try {
    final rc = withText(label, (lp, ll) => withBytes(data, (dp, dl) => _decodeText(lp, ll, dp, dl, out, len)));
    if (rc < 0) throw NativeException('decode $label text', lastError());
    try {
      // UTF-16 code units in native order, handed over whole (`own`): freed with `tk_release`.
      return String.fromCharCodes(out.value.cast<ffi.Uint16>().asTypedList(len.value ~/ 2));
    } finally {
      _release(out.value);
    }
  } finally {
    free(out.cast(), 16);
  }
}

final _decodeText = require()
    .lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Uint8>,
        ffi.IntPtr,
        ffi.Pointer<ffi.Uint8>,
        ffi.IntPtr,
        ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
        ffi.Pointer<ffi.IntPtr>,
      ),
      int Function(
        ffi.Pointer<ffi.Uint8>,
        int,
        ffi.Pointer<ffi.Uint8>,
        int,
        ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
        ffi.Pointer<ffi.IntPtr>,
      )
    >('tk_decode_text');

final _release = require()
    .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Uint8>), void Function(ffi.Pointer<ffi.Uint8>)>('tk_release');

/// The engine's job surface for [nativeJob]/[nativeCount]: long calls run on the
/// library's worker threads and answer through a listener (rule 52).
final JobLibrary engineJobs = _EngineJobs();

final class _EngineJobs implements JobLibrary {
  static final _rc = require()
      .lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>), int Function(ffi.Pointer<ffi.Void>)>('tk_job_rc');
  static final _take = require()
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.IntPtr>),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.IntPtr>)
      >('tk_job_take');
  static final _error = require()
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int)
      >('tk_job_error');
  static final _free = require()
      .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>), void Function(ffi.Pointer<ffi.Void>)>('tk_job_free');
  static final _freeGiven = require()
      .lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        void Function(ffi.Pointer<ffi.Uint8>, int)
      >('tk_free');

  @override
  int jobRc(ffi.Pointer<ffi.Void> job) => _rc(job);

  @override
  int jobTake(ffi.Pointer<ffi.Void> job, ffi.Pointer<ffi.Pointer<ffi.Uint8>> out, ffi.Pointer<ffi.IntPtr> len) =>
      _take(job, out, len);

  @override
  int jobError(ffi.Pointer<ffi.Void> job, ffi.Pointer<ffi.Uint8> buf, int cap) => _error(job, buf, cap);

  @override
  void jobFree(ffi.Pointer<ffi.Void> job) => _free(job);

  @override
  void freeGiven(ffi.Pointer<ffi.Uint8> ptr, int len) => _freeGiven(ptr, len);

  @override
  ffi.Pointer<ffi.Uint8> alloc(int size) => _Engine.alloc(size);

  @override
  void free(ffi.Pointer<ffi.Uint8> ptr, int size) => _Engine.free(ptr, size);

  @override
  String lastError() => _Engine.lastError();
}
