part of '../native.dart';

/// The package's native libraries: `dart_toolkit_native` (digests, archives, images,
/// content-decoding, charsets) and `dart_toolkit_torrent` (the BitTorrent engine), built from the
/// package's Rust sources.
///
/// Loading one only reads files: `DART_TOOLKIT_NATIVE` (a path, and then nowhere else), beside
/// the running executable, then `native/lib/<os>_<arch>/` inside the package. [install] is the
/// only thing that downloads or compiles.
///
/// ```dart
/// final native = await Native.check();
/// if (!native.isAvailable) await Native.install().show('Native libraries');
/// ```
///
/// {@category Native}
abstract final class Native {
  /// Whether each library loads, and why one does not. Reads files only, never downloads.
  static Future<NativeCheck> check() async =>
      NativeCheck._({for (final handle in NativeBridge._all) handle.name: ?handle._retry()});

  /// Puts every library that does not load where the package looks for it: the release built
  /// from these exact sources, downloaded and checked against its published SHA-256, else
  /// compiled with `cargo` (Rust and a C compiler needed; a few minutes). Reports the bytes it
  /// downloads, then what it compiles, and answers [check] once done.
  ///
  /// A library `DART_TOOLKIT_NATIVE` names is the caller's own and is left alone.
  static Task<NativeCheck> install() => TaskInternals.start('native libraries', 'native libraries', (work) async {
    for (final handle in NativeBridge._all) {
      if (handle._retry() != null) await handle.install(work);
    }
    return check();
  });
}

/// What [Native.check] found: [missing] names each library that does not load, with why.
///
/// {@category Native}
final class NativeCheck {
  /// Why each library that does not load does not, by name: `native`, `torrent`.
  final Map<String, String> missing;

  const NativeCheck._(this.missing);

  /// Whether every library loads.
  bool get isAvailable => missing.isEmpty;

  /// Why some library does not load, or `null` when every one does.
  String? get reason => isAvailable ? null : missing.entries.map((e) => 'dart_toolkit_${e.key}: ${e.value}').join('; ');

  @override
  String toString() => reason ?? 'native libraries loaded';
}

/// The native library failed on input it should have handled, or could not be installed:
/// `Cannot <op>: <what the library said>`. Bad data is a [FormatException], and a library that
/// did not load an [UnsupportedError].
///
/// {@category Native}
final class NativeException implements Exception {
  /// What failed: `hash with sha256`, `create image`, `install dart_toolkit_native`.
  final String op;

  /// What the library said.
  final String message;

  const NativeException(this.op, this.message);

  @override
  String toString() => 'Cannot $op: $message';
}

/// One native library of the package, opened on first use. Each reports its own ABI version
/// and keeps its own last error and allocations, so a result is read and freed through the
/// library that made it. Not API: [NativeBridge] holds the two.
final class NativeHandle {
  NativeHandle._(this.name, this.abi, [this._root]);

  /// `native` or `torrent`: the file is `dart_toolkit_<name>`.
  final String name;

  /// The version this package was built against; a library reporting another is refused at
  /// load rather than failing later on a missing symbol.
  final int abi;

  /// The package's folder, where `native/` is; `null` for this package's own.
  final String? _root;

  DynamicLibrary? _library;
  String? _reason;
  bool _tried = false;

  /// Where [_library] was opened from, so a worker isolate opens that file and looks nowhere else.
  String? _path;

  /// Fills `native/lib/<os>_<arch>/` with this library at [abi]: the release of the package's
  /// sources from [releases], checked against its published SHA-256, else compiled with [cargo].
  /// One process at a time; one that waited for another's install finds it done. Reports on
  /// [work]: the bytes downloaded, then what cargo compiles. What [Native.install] runs.
  Future<void> install(Work work, {String releases = NativeBridge.releases, String cargo = 'cargo'}) =>
      _install(work, releases, cargo);

  /// Compiles this library from the package's Rust sources into `native/lib/<os>_<arch>/`, as
  /// `make native` does after an edit to `native/`; blocks until done. Answers the error, or
  /// `null` once it is there.
  String? build() => _build();

  /// Why the library did not load, or `null`.
  String? get reason {
    _load();
    return _reason;
  }

  /// Whether the library loaded.
  bool get isLoaded => reason == null;

  /// The library, or an [UnsupportedError] that says why it is absent.
  DynamicLibrary require() => _load() ?? (throw UnsupportedError('dart_toolkit_$name did not load: $_reason'));

  DynamicLibrary? _load() {
    if (!_tried) {
      _tried = true;
      _library = _open();
    }
    return _library;
  }

  /// [reason], looked for again when the library did not load before: it may be there now.
  String? _retry() {
    if (_library == null) _tried = false;
    return reason;
  }

  /// The library at [path], opened as the one the main isolate found: for a worker isolate.
  void _adopt(String path) {
    if (_tried) return;
    _tried = true;
    _path = path;
    _library = DynamicLibrary.open(path);
  }

  /// `DART_TOOLKIT_NATIVE`'s file for this library: the main one at the path, the others beside
  /// it; relative is against the working directory, never the loader's search path.
  String? get _override {
    final env = Env.get<String?>('DART_TOOLKIT_NATIVE');
    if (env == null) return null;
    final path = File(env).absolute.path;
    return name == 'native' ? path : _join([File(path).parent.path, NativeBridge.fileOf(name)]);
  }

  DynamicLibrary? _open() {
    _reason = null;
    final override = _override;
    final built = _built;
    final candidates = override != null
        ? [override]
        : [
            _join([File(Platform.resolvedExecutable).parent.path, NativeBridge.fileOf(name)]),
            ?built,
          ];
    final failures = <String>[];
    for (final path in candidates) {
      if (_at(path, failures) case final lib?) {
        _path = path;
        return lib;
      }
    }
    final install = override == null && built != null ? '; `await Native.install()` downloads or builds it' : '';
    _reason = failures.isNotEmpty
        ? '${failures.join('; ')}$install'
        : override != null
        ? 'DART_TOOLKIT_NATIVE file not found: $override'
        : 'not installed: no ${NativeBridge.fileOf(name)} at ${candidates.join(', ')}$install';
    return null;
  }

  /// The library at [path] when it is there at [abi]; a stale one is closed and said in [failures].
  DynamicLibrary? _at(String path, List<String> failures) {
    if (!File(path).existsSync()) return null;
    try {
      final lib = DynamicLibrary.open(path);
      final ver = _version(lib);
      if (ver == abi) return lib;
      // Closed, so the rebuilt file at this path is what the next open loads.
      lib.close();
      failures.add('$path reported ABI version $ver, expected $abi');
    } catch (e) {
      failures.add('$path: $e');
    }
    return null;
  }

  /// Where the package keeps this library, `native/lib/<os>_<arch>/<file>`; `null` without the
  /// package's Rust sources (a compiled executable has no package).
  String? get _built {
    final root = _root ?? NativeBridge._packageRoot();
    if (root == null || !File(_join([root, 'native', 'Cargo.toml'])).existsSync()) return null;
    return _join([root, 'native', 'lib', NativeBridge.target, NativeBridge.fileOf(name)]);
  }

  static int _version(DynamicLibrary lib) {
    try {
      return lib.lookupFunction<Uint32 Function(), int Function()>('tk_version')();
    } catch (_) {
      return 0; // a library from before tk_version: told as a version mismatch
    }
  }

  /// The last error message the library recorded.
  String lastError() {
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

  late final _lastError = require()
      .lookupFunction<Int32 Function(Pointer<Uint8>, IntPtr), int Function(Pointer<Uint8>, int)>('tk_last_error');

  // The library's own allocator: `DynamicLibrary.process()` cannot find `malloc` everywhere.
  late final Pointer<Uint8> Function(int) _alloc = require()
      .lookupFunction<Pointer<Uint8> Function(IntPtr), Pointer<Uint8> Function(int)>('tk_alloc');
  late final void Function(Pointer<Uint8>, int) _dealloc = require()
      .lookupFunction<Void Function(Pointer<Uint8>, IntPtr), void Function(Pointer<Uint8>, int)>('tk_dealloc');
  // What the library allocated itself, as opposed to what [alloc] handed out.
  late final void Function(Pointer<Uint8>, int) _free = require()
      .lookupFunction<Void Function(Pointer<Uint8>, IntPtr), void Function(Pointer<Uint8>, int)>('tk_free');

  /// [size] bytes of native memory, released by [free].
  Pointer<Uint8> alloc(int size) => _alloc(size);

  /// Releases what [alloc] returned; [size] is what it was asked for.
  void free(Pointer<Uint8> ptr, int size) => _dealloc(ptr, size);

  /// Runs [body] with [data] copied into native memory.
  R withBytes<R>(List<int> data, R Function(Pointer<Uint8> ptr, int len) body) {
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
  Uint8List withOut(String op, int size, int Function(Pointer<Uint8> out) body) {
    final ptr = alloc(size);
    try {
      final n = body(ptr);
      if (n < 0) throw NativeException(op, lastError());
      return Uint8List.fromList(ptr.asTypedList(n));
    } finally {
      free(ptr, size);
    }
  }

  /// Runs [body] with a pointer-and-length pair the library fills with its own allocation;
  /// the bytes are copied out and the allocation freed. A negative return throws [NativeException].
  Uint8List take(String op, int Function(Pointer<Pointer<Uint8>> out, Pointer<IntPtr> len) body) {
    final out = alloc(16).cast<Pointer<Uint8>>(), len = (out + 1).cast<IntPtr>();
    try {
      if (body(out, len) < 0) throw NativeException(op, lastError());
      return adopt(out.value, len.value);
    } finally {
      free(out.cast(), 16);
    }
  }

  /// The [len] bytes at [ptr], an allocation the library handed over, copied out; the
  /// allocation is freed.
  Uint8List adopt(Pointer<Uint8> ptr, int len) {
    final data = Uint8List.fromList(ptr.asTypedList(len));
    _free(ptr, len);
    return data;
  }

  late final _inflateNew = require().lookupFunction<Pointer<Void> Function(Uint32), Pointer<Void> Function(int)>(
    'tk_inflate_new',
  );
  late final _inflateInto = require()
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr),
        int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint8>, int)
      >('tk_inflate_into');
  late final _inflateFinish = require().lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
    'tk_inflate_finish',
  );
  late final _inflateFree = require().lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'tk_inflate_free',
  );

  /// [body] with a `content-encoding` undone as it arrives; [codec] is 1 gzip, 3 brotli,
  /// 4 zstd. Here so `http` binds no FFI of its own. Corrupt data, and a body that ends
  /// before its compressed stream does, are a [FormatException].
  Stream<List<int>> inflate(Stream<List<int>> body, int codec) async* {
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

  late final _decodeText = require()
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr, Pointer<Pointer<Uint8>>, Pointer<IntPtr>),
        int Function(Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<IntPtr>)
      >('tk_decode_text');

  /// [bytes] read in the charset [label] names (any WHATWG label: `shift_jis`, `euc-kr`, …).
  /// An unknown label reads as UTF-8; malformed bytes become U+FFFD.
  String decodeText(String label, Uint8List bytes) {
    final units = withText(
      label,
      (l, ll) => withBytes(bytes, (p, n) => take('decode text', (out, len) => _decodeText(l, ll, p, n, out, len))),
    );
    return String.fromCharCodes(Uint16List.view(units.buffer, units.offsetInBytes, units.length ~/ 2));
  }

  /// Runs [body] with [text] as UTF-8 in native memory; `null` becomes a null pointer.
  R withText<R>(String? text, R Function(Pointer<Uint8> ptr, int len) body) =>
      text == null ? body(nullptr, 0) : withBytes(utf8.encode(text), body);
}

/// The FFI plumbing `fs`, `hash`, `http`, `image` and `torrent` bind through: public only
/// because those are separate libraries, and not covered by the versioning promise.
/// Programs ask [Native].
abstract final class NativeBridge {
  /// `dart_toolkit_native`: digests, archives, content-decoding, charsets, images, piece hashes.
  static final main = NativeHandle._('native', 13);

  /// `dart_toolkit_torrent`: the BitTorrent engine.
  static final torrent = NativeHandle._('torrent', 3);

  static List<NativeHandle> get _all => [main, torrent];

  /// Library [name] at [abi] for the package at [root], rather than this one: for tests.
  static NativeHandle of(String name, int abi, {required String root}) => NativeHandle._(name, abi, root);

  /// The file name of library [name] (`native`, `torrent`) on [target], this platform's unless given.
  static String fileOf(String name, [String? target]) => switch ((target ?? NativeBridge.target).split('_').first) {
    'macos' => 'libdart_toolkit_$name.dylib',
    'windows' => 'dart_toolkit_$name.dll',
    _ => 'libdart_toolkit_$name.so',
  };

  /// Where `make native-release` uploads the libraries: a release per [sourceHash].
  static const releases = 'https://github.com/feiluvnana/dart-toolkit/releases/download';

  /// Library [name]'s file for [target] (`macos_arm64`) in a release, gzipped. Beside it,
  /// `<asset>.sha256` holds its SHA-256 in hex, which [Native.install] checks it against.
  static String assetOf(String name, String target) => '$target-${fileOf(name, target)}.gz';

  /// The Rust sources under [crate] (`native/`), as 16 hex digits: every file but the build
  /// trees (`target/`, `lib/`) and dotfiles (`.cargo/` kept), by path, line endings as `\n`, so a
  /// Windows checkout hashes as a Mac's. What names a release.
  static String sourceHash(String crate) {
    final root = Directory(crate).absolute.path;
    final files = <String, File>{};
    for (final e in Directory(root).listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = e.path.substring(root.length + 1).replaceAll(r'\', '/');
      final parts = rel.split('/');
      if (parts.first == 'target' || parts.first == 'lib') continue;
      if (parts.any((p) => p.startsWith('.') && p != '.cargo')) continue;
      files[rel] = e;
    }
    // FNV-1a, 64 bits: no digest is loaded yet, and this names a build, it guards nothing.
    var h = 0xcbf29ce484222325;
    void add(int byte) => h = (h ^ byte) * 0x100000001b3;
    for (final rel in files.keys.toList()..sort()) {
      utf8.encode(rel).forEach(add);
      add(0);
      for (final b in files[rel]!.readAsBytesSync()) {
        if (b != 13) add(b);
      }
      add(0);
    }
    String hex(int v) => v.toRadixString(16).padLeft(8, '0');
    return '${hex(h >>> 32)}${hex(h & 0xffffffff)}';
  }

  /// This platform's folder under `native/lib/`.
  static String get target {
    final arch = switch (Abi.current()) {
      Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => 'arm64',
      _ => 'x64',
    };
    return '${Platform.operatingSystem}_$arch';
  }

  /// What the library said about the file at [path], as the exception it means: a missing file
  /// (`os error 2` or `3`) is a [PathNotFoundException], another system error a
  /// [FileSystemException], each with the OS's own words; anything else (the file is there but
  /// unreadable as what it should be) a [FormatException] reading `<invalid>: <message>`.
  static Exception fileError(String message, String path, String invalid) {
    final os = _osError.firstMatch(message);
    if (os == null) return FormatException('$invalid: $message');
    final code = int.parse(os[1]!);
    // The library's text is `<path>: <reason> (os error N)`; the reason is what the OS said.
    final said = message.substring(0, os.start).trim();
    final at = said.lastIndexOf(': ');
    final error = OSError(at < 0 ? said : said.substring(at + 2), code);
    if (code == 2 || code == 3) return PathNotFoundException(path, error, 'Cannot open');
    return FileSystemException('Cannot open', path, error);
  }

  static final _osError = RegExp(r'\(os error (\d+)\)');

  static String? _packageRoot() {
    final uri = Isolate.resolvePackageUriSync(Uri.parse('package:dart_toolkit/core.dart'));
    return uri == null || uri.scheme != 'file' ? null : File(uri.toFilePath()).parent.parent.path;
  }
}

/// [parts] joined by this platform's separator, without doubling one a part already ends with
/// (a root such as `/` or `C:\`): `package:path` costs every importer its compile time.
String _join(List<String> parts) => parts.reduce(
  (a, b) => a.endsWith('/') || a.endsWith(Platform.pathSeparator) ? '$a$b' : '$a${Platform.pathSeparator}$b',
);
