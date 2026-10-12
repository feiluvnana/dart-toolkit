/// The seam over the `dart_toolkit_tui` cdylib.
///
/// Only `tui` imports this file — never `dart:ffi` directly — so only programs
/// that own the screen compile FFI (rule 50). Without the library, owning the
/// terminal is an [UnsupportedError] (rule 42: no Dart fallback); the [FakeTerminal]
/// test seam stays pure Dart and always works.
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:isolate';

import '../core/native_status.dart';

/// ABI of `dart_toolkit_tui` this seam binds.
const _tuiAbi = 2;

/// A polled `tk_event`: what the native crate heard.
final class TkEvent extends ffi.Struct {
  /// 0 timeout (unused: the return says it), 1 key, 2 resize, 3 pointer,
  /// 4 paste, 5 focus, 6 blur, 7 interrupt.
  @ffi.Int32()
  external int kind;

  /// Key: printable scalar, else a named code (`0x100001` up … — see
  /// `_Tui.keyUp` et al). Pointer: button. Resize: unused.
  @ffi.Int32()
  external int code;

  /// Modifier bitmask: 1 shift, 2 ctrl, 4 alt. Pointer kind for pointers.
  @ffi.Int32()
  external int mods;

  /// Pointer column / resize width.
  @ffi.Int32()
  external int x;

  /// Pointer row / resize height.
  @ffi.Int32()
  external int y;

  @ffi.Int32()
  external int w;

  @ffi.Int32()
  external int h;

  /// Bracketed-paste bytes (`give()`, freed with `tk_free`), else null.
  external ffi.Pointer<ffi.Uint8> text;

  @ffi.IntPtr()
  external int textLen;
}

/// The `tui` cdylib binding: opened once, on first use.
abstract final class _Tui {
  static ffi.DynamicLibrary? _lib;
  static String? _reason;
  static bool _tried = false;

  /// The library, or throws [UnsupportedError] naming why it is absent (rule 42).
  static ffi.DynamicLibrary require() {
    final lib = _load();
    if (lib == null) {
      throw UnsupportedError('dart_toolkit_tui did not load: $_reason');
    }
    return lib;
  }

  static ffi.DynamicLibrary? _load() {
    NativeStatus.register(
      'dart_toolkit_tui',
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
            _join([io.File(io.Platform.resolvedExecutable).parent.path, _fileOf('tui')]),
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
        ? 'DART_TOOLKIT_TUI_LIB file not found: $override'
        : 'not installed: no ${_fileOf('tui')} at ${candidates.join(', ')}';
    return null;
  }

  static ffi.DynamicLibrary? _at(String path, List<String> failures) {
    if (!io.File(path).existsSync()) return null;
    try {
      final lib = ffi.DynamicLibrary.open(path);
      final ver = _version(lib);
      if (ver == _tuiAbi) return lib;
      lib.close();
      failures.add('$path reported ABI version $ver, expected $_tuiAbi');
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

  /// `DART_TOOLKIT_TUI_LIB`'s file: relative against the working directory.
  static String? get _override {
    final env = io.Platform.environment['DART_TOOLKIT_TUI_LIB'];
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
    return _join([root, 'native', 'lib', _target, _fileOf('tui')]);
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

  /// Releases a `give()` buffer of [size] bytes.
  static void freeGiven(ffi.Pointer<ffi.Uint8> ptr, int size) => _free(ptr, size);

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
}

String _join(List<String> parts) => parts.reduce(
  (a, b) => a.endsWith('/') || a.endsWith(io.Platform.pathSeparator) ? '$a$b' : '$a${io.Platform.pathSeparator}$b',
);

/// Named key codes past the Unicode range (mirror of the Rust table).
const keyUp = 0x100001;
const keyDown = 0x100002;
const keyLeft = 0x100003;
const keyRight = 0x100004;
const keyHome = 0x100005;
const keyEnd = 0x100006;
const keyPageUp = 0x100007;
const keyPageDown = 0x100008;
const keyInsert = 0x100009;
const keyDelete = 0x10000A;
const keyEnter = 0x10000B;
const keyTab = 0x10000C;
const keyBackspace = 0x10000D;
const keyEsc = 0x10000E;
const keyF = 0x100010; // F1..F24 are keyF + (n - 1)

/// Modifier bitmask: 1 shift, 2 ctrl, 4 alt.
const modShift = 1;
const modCtrl = 2;
const modAlt = 4;

/// The tui seam's shared helpers for `term.dart`: public here so they stay in
/// one place, hidden from scripts by `tui.dart`'s export list.
///
/// The library, or throws [UnsupportedError] naming why it is absent (rule 42).
ffi.DynamicLibrary require() => _Tui.require();

/// [size] bytes of native memory, released by [free].
ffi.Pointer<ffi.Uint8> alloc(int size) => _Tui.alloc(size);

/// Releases what [alloc] returned; [size] is what it was asked for.
void free(ffi.Pointer<ffi.Uint8> ptr, int size) => _Tui.free(ptr, size);

/// Releases a `give()` buffer of [size] bytes.
void freeGiven(ffi.Pointer<ffi.Uint8> ptr, int size) => _Tui.freeGiven(ptr, size);

/// Runs [body] with [data] copied into native memory.
R withBytes<R>(List<int> data, R Function(ffi.Pointer<ffi.Uint8> ptr, int len) body) => _Tui.withBytes(data, body);

/// Runs [body] with [text] as UTF-8 in native memory.
R withText<R>(String text, R Function(ffi.Pointer<ffi.Uint8> ptr, int len) body) => _Tui.withText(text, body);

/// The last error message the library recorded (call on the same thread,
/// synchronously after the failing call).
String lastError() => _Tui.lastError();
