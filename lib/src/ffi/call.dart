part of '../../ffi.dart';

/// A library [Ffi.open] found.
///
/// {@category Native}
final class Lib {
  Lib._(this.path, this._lib);

  /// What it was opened as; empty for the running process.
  final String path;
  final DynamicLibrary _lib;
  final _symbols = <String, _Symbol>{};
  final _releases = <String, (NativeFinalizer, void Function(Pointer<Void>))>{};

  /// Whether it exports [name].
  bool has(String name) => _symbols.containsKey(name) || _lib.providesSymbol(name);

  /// The function [name] returning [ret], looked up now: `libc.fn('strlen', C.i64)('hi')`.
  ///
  /// A variadic function says how many of its arguments are [fixed] — `snprintf` has 3 —
  /// because the rest travel differently (on the stack, on Apple arm64). Called without it, a
  /// variadic function reads garbage rather than failing. In the variadic part a `float` is a
  /// `double`, as C promotes it.
  Fn<T> fn<T>(String name, C<T> ret, {int fixed = 0}) => Fn._(_symbol(name), ret, fixed);

  /// Calls [name] once: `libc.call('getpid', C.i32)`. The lookup is cached all the same;
  /// [fn] only gives it a name.
  T call<T>(
    String name,
    C<T> ret, [
    Object? a,
    Object? b,
    Object? c,
    Object? d,
    Object? e,
    Object? f,
    Object? g,
    Object? h,
  ]) => _symbol(name).invoke(ret, 0, a, b, c, d, e, f, g, h);

  /// [ptr], released by this library's [release] — `free`, `sqlite3_close`, any
  /// `void f(void*)` — when the [Owned] is garbage collected, or by [Owned.close]. Pass the
  /// [Owned] wherever the pointer would go. [size], the bytes it holds, tells the garbage
  /// collector how much a forgotten one keeps alive, so a loop of them is collected in time.
  Owned own(Pointer ptr, String release, {int? size}) {
    final (finalizer, fn) = _releases[release] ??= () {
      final p = _lookup(release).cast<NativeFunction<Void Function(Pointer<Void>)>>();
      return (NativeFinalizer(p), p.asFunction<void Function(Pointer<Void>)>());
    }();
    return Owned._(ptr.cast(), finalizer, fn, size);
  }

  _Symbol _symbol(String name) => _symbols[name] ??= _Symbol(this, name, _lookup(name));

  Pointer<Void> _lookup(String name) {
    try {
      return _lib.lookup<Void>(name);
    } on ArgumentError {
      throw ArgumentError.value(name, 'name', 'no such symbol in ${path.isEmpty ? 'the process' : path}');
    }
  }
}

/// One function of a [Lib], answering [T]. It takes up to eight arguments:
///
/// * `int`, `bool`, `null` (a null pointer), a `Pointer`, an [Owned], an [Out] or a
///   [Callback];
/// * a `String`, as a NUL-terminated UTF-8 `char*` for the call;
/// * a typed list (`Uint8List`, `Int32List`, …), copied in for the call and **back out
///   after it**, so a buffer the callee fills is filled — `read(fd, buf, n)`. An unmodifiable
///   one goes in only;
/// * a `double`, and `C.f32(x)` for a `float`. An `int` is always an integer: write
///   `pow(2.0, 10.0)`, not `pow(2, 10)`.
///
/// Integers and doubles mix freely — `ldexp(1.0, 10)` — except on Windows, which passes
/// arguments by position: there a call is all integers or all doubles, at most six, and a mix
/// is refused. A narrow integer parameter is passed as its key makes it: `C.i8(255)` is `-1`.
///
/// {@category Native}
final class Fn<T> {
  Fn._(this._symbol, this._ret, this._fixed);

  final _Symbol _symbol;
  final C<T> _ret;
  final int _fixed;

  /// Calls it.
  T call([Object? a, Object? b, Object? c, Object? d, Object? e, Object? f, Object? g, Object? h]) =>
      _symbol.invoke(_ret, _fixed, a, b, c, d, e, f, g, h);

  /// Calls it on another isolate, for a function that blocks, while this isolate's event loop
  /// keeps running. Helper isolates are started as needed and kept for the next call, so only
  /// the first pays for a spawn. Typed lists are still copied back. A [Callback] cannot go.
  Future<T> async([Object? a, Object? b, Object? c, Object? d, Object? e, Object? f, Object? g, Object? h]) async {
    final args = [a, b, c, d, e, f, g, h];
    final send = [for (final x in args) _sendable(x)];
    final helper = await _Helper._get();
    final reply = await helper._ask((_symbol._lib.path, _symbol.name, _ret, _fixed, send));
    final (raw, lists, error, stack) = reply! as (Object?, List<Uint8List>?, Object?, String?);
    if (error != null) Error.throwWithStackTrace(error, StackTrace.fromString(stack ?? ''));
    var i = 0;
    for (final x in args.whereType<TypedData>()) {
      _writeBack(x, lists![i++]);
    }
    return _ret._take(raw!);
  }

  static Object? _sendable(Object? x) => switch (x) {
    final Pointer p => p.address,
    final Owned o => o._address,
    final Out<Object?> o => o.ptr.address,
    Callback() => throw ArgumentError.value(x, 'argument', 'a callback cannot be called from another isolate'),
    _ => x,
  };
}

/// An isolate that makes [Fn.async]'s calls, one at a time, kept for the next.
///
/// A spawn per call cost ~100 µs; a message each way costs a few. A blocking call holds its
/// helper, so concurrent calls get helpers of their own. An idle helper does not keep the
/// program alive.
final class _Helper {
  _Helper._(this._port, this._to);

  static final _idle = <_Helper>[];

  final RawReceivePort _port;
  final SendPort _to;
  Completer<Object?>? _pending;

  static Future<_Helper> _get() async {
    if (_idle.isNotEmpty) return _idle.removeLast();
    final ready = Completer<SendPort>();
    _Helper? helper;
    final port = RawReceivePort();
    port.handler = (Object? m) {
      if (helper case final h?) {
        final done = h._pending!;
        h._pending = null;
        port.keepIsolateAlive = false;
        _idle.add(h);
        done.complete(m);
      } else {
        ready.complete(m! as SendPort);
      }
    };
    try {
      await Isolate.spawn(_serve, port.sendPort, debugName: 'dart_toolkit/ffi');
    } catch (_) {
      port.close();
      rethrow;
    }
    return helper = _Helper._(port, await ready.future);
  }

  Future<Object?> _ask(Object message) {
    final done = _pending = Completer<Object?>();
    _port.keepIsolateAlive = true;
    _to.send(message);
    return done.future;
  }

  // Static, so the closure captures only what it names: an instance closure takes `this`, and
  // with it a DynamicLibrary, which cannot cross isolates.
  static void _serve(SendPort out) {
    final libs = <String, Lib>{};
    final inbox = RawReceivePort();
    inbox.handler = (Object? m) {
      final (path, name, ret, fixed, args) = m! as (String, String, C<Object?>, int, List<Object?>);
      try {
        final lib = libs[path] ??= Lib._(path, path.isEmpty ? DynamicLibrary.process() : DynamicLibrary.open(path));
        final raw = lib._symbol(name)._raw(ret, fixed, args);
        out.send((raw, [for (final t in args.whereType<TypedData>()) _bytesOf(t)], null, null));
      } catch (e, st) {
        try {
          out.send((null, null, e, '$st'));
        } on ArgumentError {
          out.send((null, null, '$e', '$st')); // an error that cannot be sent goes as its text
        }
      }
    };
    out.send(inbox.sendPort);
  }
}

/// A pointer with its release attached: released when this is garbage collected, or by [close].
///
/// {@category Native}
final class Owned implements Finalizable {
  Owned._(this._ptr, this._finalizer, this._release, int? size) {
    _finalizer.attach(this, _ptr, detach: this, externalSize: size);
  }

  final Pointer<Void> _ptr;
  final NativeFinalizer _finalizer;
  final void Function(Pointer<Void>) _release;
  var _closed = false;

  /// The pointer; a [StateError] once closed.
  Pointer<Void> get ptr => Pointer.fromAddress(_address);

  /// Releases it now. A second close does nothing.
  void close() {
    if (_closed) return;
    _closed = true;
    _finalizer.detach(this);
    _release(_ptr);
  }

  int get _address => _closed ? throw StateError('the pointer was released') : _ptr.address;
}

// The slots a mixed call is laid out in. Reusing them is safe: they are read into the call's
// arguments before C runs, so a callback that makes a call of its own cannot disturb them.
final _is = List<int>.filled(8, 0);
final _ds = List<double>.filled(8, 0);

/// A resolved function, bound lazily to whichever shape it is called through.
final class _Symbol {
  _Symbol(this._lib, this.name, this._ptr);

  final Lib _lib;
  final String name;
  final Pointer<Void> _ptr;
  late final _asInts = _ints(_ptr);
  late final _asIntsD = _intsD(_ptr);
  late final _asReals = _reals(_ptr);
  late final _asRealsI = _realsI(_ptr);
  late final _asMixed = _mixed(_ptr);
  late final _asMixedD = _mixedD(_ptr);
  final _variadic = <int, Function>{};

  T invoke<T>(
    C<T> ret,
    int fixed,
    Object? a,
    Object? b,
    Object? c,
    Object? d,
    Object? e,
    Object? f,
    Object? g,
    Object? h,
  ) {
    // The common shapes, each straight through: a few integers or pointers (nothing to
    // allocate, nothing to free), the same with strings or typed lists, and all doubles.
    if (fixed == 0 && g == null && h == null) {
      if (!ret._real) {
        if (_isPlain(a) && _isPlain(b) && _isPlain(c) && _isPlain(d) && _isPlain(e) && _isPlain(f)) {
          return ret._read(_asInts(_bare(a), _bare(b), _bare(c), _bare(d), _bare(e), _bare(f)));
        }
        if (a is! double && b is! double && c is! double && d is! double && e is! double && f is! double) {
          return ret._read(_scoped(a, b, c, d, e, f));
        }
      } else if (a is double? && b is double? && c is double? && d is double? && e is double? && f is double?) {
        return ret._fromReal(_asReals(a ?? 0, b ?? 0, c ?? 0, d ?? 0, e ?? 0, f ?? 0));
      }
    }
    return ret._take(_raw(ret, fixed, [a, b, c, d, e, f, g, h]));
  }

  int _scoped(Object? a, Object? b, Object? c, Object? d, Object? e, Object? f) {
    final s = Scope._();
    try {
      return _asInts(s._word(a), s._word(b), s._word(c), s._word(d), s._word(e), s._word(f));
    } finally {
      s._close();
    }
  }

  /// The call, answering what the register held: an `int`, or a `double` for a real [ret].
  Object _raw(C<Object?> ret, int fixed, List<Object?> x) {
    final s = Scope._();
    try {
      return fixed > 0 ? _varargs(ret, fixed, x, s) : _call(ret, x, s);
    } finally {
      s._close();
    }
  }

  Object _call(C<Object?> ret, List<Object?> x, Scope s) {
    var n = x.length;
    while (n > 0 && x[n - 1] == null) {
      n--;
    }
    var ni = 0, nd = 0;
    for (var k = 0; k < n; k++) {
      if (x[k] case final double v) {
        _ds[nd++] = v;
      } else {
        _is[ni++] = _plain(x[k]) ?? s._word(x[k]);
      }
    }
    final i = _is..fillRange(ni, 8, 0), r = _ds..fillRange(nd, 8, 0);
    if (nd == 0 && ni <= 6) {
      return ret._real ? _asIntsD(i[0], i[1], i[2], i[3], i[4], i[5]) : _asInts(i[0], i[1], i[2], i[3], i[4], i[5]);
    }
    if (ni == 0 && nd <= 6) {
      return ret._real ? _asReals(r[0], r[1], r[2], r[3], r[4], r[5]) : _asRealsI(r[0], r[1], r[2], r[3], r[4], r[5]);
    }
    if (_positional) {
      throw ArgumentError(
        '$name: Windows passes arguments by position, so a call that mixes integers and doubles, '
        'or takes more than six, needs dart:ffi lookupFunction',
      );
    }
    return ret._real
        ? _asMixedD(i[0], i[1], i[2], i[3], i[4], i[5], i[6], i[7], r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7])
        : _asMixed(i[0], i[1], i[2], i[3], i[4], i[5], i[6], i[7], r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]);
  }

  Object _varargs(C<Object?> ret, int fixed, List<Object?> x, Scope s) {
    if (ret._real) throw ArgumentError('$name: a variadic function returning a float or double needs dart:ffi');
    var ni = 0, nd = 0;
    for (var k = 0; k < x.length; k++) {
      final v = x[k];
      if (v is double) {
        if (k < fixed) throw ArgumentError('$name: a double among the fixed arguments needs dart:ffi');
        if (_flatVarArgs) {
          _is[ni++] = (_scratch..setFloat64(0, v, Endian.little)).getInt64(0, Endian.little);
        } else {
          _ds[nd++] = v;
        }
      } else {
        _is[ni++] = _plain(v) ?? s._word(v);
      }
    }
    final i = _is..fillRange(ni, 8, 0), r = _ds..fillRange(nd, 8, 0);
    if (_flatVarArgs) {
      final f = (_variadic[fixed] ??= _flat(_ptr, fixed)) as _Flat;
      return f(i[0], i[1], i[2], i[3], i[4], i[5], i[6], i[7]);
    }
    final f = (_variadic[fixed] ??= _split(_ptr, fixed)) as _Mixed;
    return f(i[0], i[1], i[2], i[3], i[4], i[5], i[6], i[7], r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]);
  }
}

/// An argument that is already its 64-bit word, or null for one that needs a [Scope] (a
/// `String`, a typed list) or is refused.
int? _plain(Object? x) => switch (x) {
  null => 0,
  final int i => i,
  final Pointer p => p.address,
  final bool b => b ? 1 : 0,
  final Owned o => o._address,
  final Callback c => c._address,
  final Out<Object?> o => o.ptr.address,
  _ => null,
};

/// Whether [x] is its word already, with nothing to allocate: [_bare] of it cannot fail.
bool _isPlain(Object? x) =>
    x == null || x is int || x is Pointer || x is bool || x is Owned || x is Callback || x is Out;

/// [x] as its word, for an [_isPlain] one.
int _bare(Object? x) => switch (x) {
  final int i => i,
  null => 0,
  final Pointer p => p.address,
  final bool b => b ? 1 : 0,
  final Owned o => o._address,
  final Callback c => c._address,
  final Out<Object?> o => o.ptr.address,
  _ => throw StateError('unreachable'),
};
