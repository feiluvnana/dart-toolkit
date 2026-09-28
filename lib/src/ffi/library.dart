part of '../../ffi.dart';

/// The way in: [open] a library, [scope] some memory, make a [callback].
///
/// {@category Native}
abstract final class Ffi {
  /// A library by short name, file name or path.
  ///
  /// A short name is looked for as this platform spells it — `'sqlite3'` is
  /// `libsqlite3.dylib`, `libsqlite3.so` (or `.so.0`, which is all a system without the -dev
  /// package has) or `sqlite3.dll` — beside the script, then where the system looks, then in
  /// Homebrew's and `/usr/local`'s `lib`. `'c'` and `'m'` are the C runtime. A name with a `.`
  /// or a slash is opened as it is. A miss is an [ArgumentError] listing everything tried.
  static Lib open(String name) {
    if (sizeOf<IntPtr>() != 8) throw UnsupportedError('package:dart_toolkit/ffi.dart needs a 64-bit platform');
    if (name.contains('.') || name.contains('/') || name.contains(r'\')) {
      try {
        return Lib._(name, DynamicLibrary.open(name));
      } on ArgumentError catch (e) {
        final why = name.contains(Platform.pathSeparator) && !File(name).existsSync() ? 'no such file' : e.message;
        throw ArgumentError.value(name, 'name', 'cannot open the library: $why');
      }
    }
    final tried = <String>[];
    for (final path in _candidates(name)) {
      try {
        return Lib._(path, DynamicLibrary.open(path));
      } on ArgumentError {
        tried.add(path);
      }
    }
    // A static or musl libc has no file of its own.
    if (name == 'c' && !Platform.isWindows) return Lib._('', DynamicLibrary.process());
    throw ArgumentError.value(name, 'name', 'no such library; tried ${tried.join(', ')} — or pass a path');
  }

  static Iterable<String> _candidates(String name) sync* {
    final crt = name == 'c' || name == 'm';
    final files = switch (Platform.operatingSystem) {
      'macos' => ['lib$name.dylib'],
      'windows' => [if (crt) 'ucrtbase.dll', '$name.dll', 'lib$name.dll', if (name == 'sqlite3') 'winsqlite3.dll'],
      _ => [if (crt) 'lib$name.so.6', 'lib$name.so'],
    };
    if (Platform.script.isScheme('file')) {
      final dir = File(Platform.script.toFilePath()).parent.path;
      yield* files.map((f) => '$dir${Platform.pathSeparator}$f');
    }
    yield* files;
    if (Platform.isMacOS) {
      yield* ['/opt/homebrew/lib/lib$name.dylib', '/usr/local/lib/lib$name.dylib'];
      yield '/System/Library/Frameworks/$name.framework/$name';
    } else if (Platform.isLinux) {
      const dirs = [
        '/usr/lib',
        '/usr/lib64',
        '/lib',
        '/usr/local/lib',
        '/usr/lib/x86_64-linux-gnu',
        '/usr/lib/aarch64-linux-gnu',
      ];
      for (final dir in dirs.where((d) => Directory(d).existsSync())) {
        yield* Directory(dir).listSync().map((f) => f.path).where((f) => f.startsWith('$dir/lib$name.so.'));
      }
    }
  }

  /// Runs [body] and then frees everything it allocated — when its future completes, if it
  /// is `async`.
  static R scope<R>(R Function(Scope s) body) {
    final s = Scope._();
    var sync = true;
    try {
      final r = body(s);
      if (r is Future<Object?>) {
        sync = false;
        return r.whenComplete(s._end) as R;
      }
      return r;
    } finally {
      if (sync) s._end();
    }
  }

  /// [f], a function of 0 to 4 `int`s, as a C function pointer until [Callback.close]. A
  /// pointer argument arrives as its address, for [C.at], and a negative C `int` as its
  /// unsigned 64-bit slot, for `C.i32(a)`; the result goes back as an integer (`bool` as 1 or
  /// 0, `null` as 0).
  static Callback callback(Function f) => Callback._(_callable(f));

  /// This thread's C `errno`, as the last call left it: read it right after the call that
  /// failed. A call's own cleanup — freeing its strings and lists — does not change it. After
  /// [Fn.async] it is the other isolate's, and meaningless here.
  static int get errno => _errno().value;
}
