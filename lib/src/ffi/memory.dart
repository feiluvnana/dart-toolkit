part of '../../ffi.dart';

// The C runtime's allocator — the one `Ffi.open('c')` opens, so what a scope frees and what a
// script frees with `libc.own(p, 'free')` come from the same heap. Windows has no process-wide
// `malloc` to find, hence `ucrtbase`.
final DynamicLibrary _crt = Platform.isWindows ? DynamicLibrary.open('ucrtbase.dll') : DynamicLibrary.process();
// Leaf calls: none of them calls back into Dart, so they skip the VM's transition (~5 ns each).
final _calloc = _crt.lookupFunction<Pointer<Uint8> Function(IntPtr, IntPtr), Pointer<Uint8> Function(int, int)>(
  'calloc',
  isLeaf: true,
);
final _free = _crt.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('free', isLeaf: true);
final _strlen = _crt.lookupFunction<IntPtr Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>(
  'strlen',
  isLeaf: true,
);

// Where this thread's `errno` lives; each C runtime names the function differently.
final _errno = _crt.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
  switch (Platform.operatingSystem) {
    'macos' || 'ios' => '__error',
    'windows' => '_errno',
    'android' => '__errno',
    _ => '__errno_location',
  },
  isLeaf: true,
);

String _cString(Pointer<Uint8> p) => utf8.decode(p.asTypedList(_strlen(p)), allowMalformed: true);

/// Native memory that lives until [Ffi.scope] returns.
///
/// A call scopes its own `String` and typed-list arguments, so a scope is for what outlives
/// one call: a buffer handed to two functions, a `char*` stored in C, a callback. A pointer C
/// returns into it dies with it.
///
/// {@category Native}
final class Scope {
  Scope._();

  // Null until used: every call makes a scope, and most need none of these.
  List<Pointer<Uint8>>? _owned;
  List<(Pointer<Uint8>, Uint8List)>? _back;
  List<Callback>? _callbacks;

  /// [_end] for a call's own scope, keeping `errno` as the call left it: `free` may set it
  /// (glibc before 2.33), and it is what the caller reads next.
  void _close() {
    if (_owned == null && _callbacks == null) return;
    final errno = _errno();
    final saved = errno.value;
    _end();
    errno.value = saved;
  }

  /// [size] zeroed bytes.
  Pointer<Uint8> alloc(int size) {
    final p = _calloc(1, size < 1 ? 1 : size);
    if (p == nullptr) throw OutOfMemoryError();
    (_owned ??= []).add(p);
    return p;
  }

  /// Room for one [key], zeroed, for a function to write through: `final n = s.out(C.i32);
  /// f(n); n.value`.
  Out<T> out<T>(C<T> key) => Out._(key, alloc(key._size));

  /// [text] as a NUL-terminated UTF-8 `char*`.
  Pointer<Uint8> text(String text) => _copy(utf8.encode(text), 1);

  /// A copy of [data].
  Pointer<Uint8> bytes(List<int> data) => _copy(data, 0);

  Pointer<Uint8> _copy(List<int> data, int pad) {
    final p = alloc(data.length + pad);
    p.asTypedList(data.length).setAll(0, data);
    return p;
  }

  /// [f] as a C function pointer, closed when the scope ends; see [Ffi.callback].
  Callback callback(Function f) {
    final c = Ffi.callback(f);
    (_callbacks ??= []).add(c);
    return c;
  }

  /// One argument as the 64-bit word it travels in.
  int _word(Object? x) => switch (x) {
    null => 0,
    final int i => i,
    final bool b => b ? 1 : 0,
    final Pointer p => p.address,
    final Owned o => o._address,
    final Callback c => c._address,
    final Out<Object?> o => o.ptr.address,
    final String t => text(t).address,
    final TypedData t => _copyBack(t).address,
    final List<Object?> _ => throw ArgumentError.value(
      x,
      'argument',
      'a List goes to C as a typed list: Uint8List.fromList(…)',
    ),
    _ => throw ArgumentError.value(x, 'argument', 'cannot pass a ${x.runtimeType} to C'),
  };

  /// A copy of [t], copied back after the call unless [t] is unmodifiable.
  Pointer<Uint8> _copyBack(TypedData t) {
    final view = t.buffer.asUint8List(t.offsetInBytes, t.lengthInBytes);
    final p = _copy(view, 0);
    if (_writable(t)) (_back ??= []).add((p, view));
    return p;
  }

  void _end() {
    if (_back case final back?) {
      for (final (p, view) in back) {
        view.setAll(0, p.asTypedList(view.length));
      }
    }
    if (_callbacks case final callbacks?) {
      for (final c in callbacks) {
        c.close();
      }
    }
    if (_owned case final owned?) {
      for (final p in owned) {
        _free(p);
      }
    }
  }
}

Uint8List _bytesOf(TypedData t) => t.buffer.asUint8List(t.offsetInBytes, t.lengthInBytes);

/// Copies what C left in [from] back into [t], unless [t] is unmodifiable: its bytes went in
/// as input only. Its buffer is writable even then, so the list itself is asked, by writing
/// an element over itself.
void _writeBack(TypedData t, List<int> from) {
  if (_writable(t)) _bytesOf(t).setAll(0, from);
}

bool _writable(TypedData t) {
  if (t.lengthInBytes == 0) return false;
  try {
    final list = t as List<Object?>;
    list[0] = list[0];
    return true;
  } on UnsupportedError {
    return false;
  }
}

/// Room for one C value that a function writes through: pass it where the pointer goes, and
/// read [value] afterwards. It lives as long as the [Scope] that made it.
///
/// {@category Native}
final class Out<T> {
  Out._(this._key, this.ptr);

  final C<T> _key;

  /// Where it is.
  final Pointer<Uint8> ptr;

  /// What is there now.
  T get value => _key.at(ptr.address);

  set value(T v) => _key._store(ptr.address, v);
}

/// A Dart function C can call back: pass it as an argument, and [close] it when C is done —
/// or make it with [Scope.callback] and let the scope close it.
///
/// It runs on this isolate's thread, during a call this isolate made (`qsort`, `bsearch`, a
/// visitor); a callback from a thread C started itself needs `dart:ffi`'s
/// `NativeCallable.listener`. An `int` argument arrives as its 64-bit slot, so a negative C
/// `int` reads `C.i32(a)`; a pointer arrives as its address, for [C.at]. If the Dart function
/// throws, or returns something C cannot take, that is written to stderr and C receives 0.
///
/// {@category Native}
final class Callback {
  Callback._(this._callable);

  final NativeCallable<_Callback> _callable;
  var _closed = false;

  /// Releases it; C must not call it afterwards. A second close does nothing.
  void close() {
    if (!_closed) _callable.close();
    _closed = true;
  }

  int get _address => _closed ? throw StateError('the callback was closed') : _callable.nativeFunction.address;
}
