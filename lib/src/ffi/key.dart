part of '../../ffi.dart';

// `C.bool` is a member called `bool`, which inside [C] hides the type; the type is named
// through this instead.
typedef _Bool = bool;

const _void = 0, _int = 1, _flag = 2, _ptr = 3, _str = 4, _f64 = 5, _f32 = 6;

/// A C type, as a typed key: `libc.fn('getpid', C.i32)` is an `Fn<int>`.
///
/// As a return, the key is how a value is read back, which matters because a callee returning
/// an `int` leaves the upper half of the register undefined; [i32] narrows it. There is no
/// `u64` or `size`: a Dart `int` is 64 bits, so `size_t`, `uint64_t` and `intptr_t` are all
/// [i64] and there is nothing to narrow.
///
/// Called, a key is a value as that type holds it: `C.f32(1.5)` is a `float` argument,
/// `C.i8(255)` is `-1`, and `C.i32(a)` is how a callback reads a negative `int`, which C hands
/// over zero-extended. [at] reads the type out of memory, [list] views an array of it, and
/// [field] makes a member of a [Layout].
///
/// {@category Native}
final class C<T> {
  const C._(this._kind, [this._bits = 64, this._signed = true]);

  final int _kind;
  final int _bits;
  final _Bool _signed;

  /// `void`.
  static const none = C<void>._(_void);

  /// `int8_t`.
  static const i8 = C<int>._(_int, 8);

  /// `uint8_t`.
  static const u8 = C<int>._(_int, 8, false);

  /// `int16_t`.
  static const i16 = C<int>._(_int, 16);

  /// `uint16_t`.
  static const u16 = C<int>._(_int, 16, false);

  /// `int32_t`, and C's `int`.
  static const i32 = C<int>._(_int, 32);

  /// `uint32_t`.
  static const u32 = C<int>._(_int, 32, false);

  /// Any 64-bit integer: `int64_t`, `uint64_t`, `size_t`, `intptr_t`, `long` off Windows.
  static const i64 = C<int>._(_int);

  /// C's `bool`, one byte.
  static const bool = C<_Bool>._(_flag, 8, false);

  /// Any pointer, as `Pointer<Void>`; pass it straight back to another call.
  static const ptr = C<Pointer<Void>>._(_ptr);

  /// A NUL-terminated UTF-8 `char*`, read into a `String`; `NULL` is `null`. The memory is
  /// the callee's and is not freed.
  static const str = C<String?>._(_str);

  /// `double`.
  static const f64 = C<double>._(_f64);

  /// `float`. As an argument it is written `C.f32(x)`: a bare `double` is a `double`.
  static const f32 = C<double>._(_f32, 32);

  /// A struct's shape, from its members in order; see [Layout].
  static Layout struct(List<Field<Object?>> fields) => Layout._(fields);

  /// [value] as this type holds it: narrowed to its width for an integer, and for [f32] the
  /// bits a `float` argument travels in (pass it on; it is not a number to print).
  T call(T value) => switch (_kind) {
    _int => _narrow(value as int) as T,
    _f32 => _floatBits(value as double) as T,
    _ => value,
  };

  /// The value of this type stored at [address]: `C.i32.at(a)` in a comparator, or
  /// `C.ptr.at(out.address)` for a `void**` out-parameter.
  T at(int address) => switch (_kind) {
    _int => _load(address) as T,
    _flag => (Pointer<Uint8>.fromAddress(address).value != 0) as T,
    _ptr => Pointer<Pointer<Void>>.fromAddress(address).value as T,
    _str => _read(Pointer<IntPtr>.fromAddress(address).value),
    _f64 => Pointer<Double>.fromAddress(address).value as T,
    _f32 => Pointer<Float>.fromAddress(address).value as T,
    _ => throw UnsupportedError('there is no value of type void to read'),
  };

  /// The [length] values of this type at [p], as a typed list over that memory — not a copy,
  /// so it lives as long as the memory does. Numbers only.
  List<T> list(Pointer p, int length) =>
      switch ((_kind, _bits, _signed)) {
            (_int, 8, true) => p.cast<Int8>().asTypedList(length),
            (_int, 8, false) => p.cast<Uint8>().asTypedList(length),
            (_int, 16, true) => p.cast<Int16>().asTypedList(length),
            (_int, 16, false) => p.cast<Uint16>().asTypedList(length),
            (_int, 32, true) => p.cast<Int32>().asTypedList(length),
            (_int, 32, false) => p.cast<Uint32>().asTypedList(length),
            (_int, _, _) => p.cast<Int64>().asTypedList(length),
            (_f64, _, _) => p.cast<Double>().asTypedList(length),
            (_f32, _, _) => p.cast<Float>().asTypedList(length),
            _ => throw UnsupportedError('a list of $this needs C.at'),
          }
          as List<T>;

  /// A new member of this type, for [C.struct].
  Field<T> get field => Field._(this);

  /// Bytes it takes in memory, which is also its alignment.
  int get _size => switch (_kind) {
    _void => throw UnsupportedError('void has no size'),
    _int || _flag || _f32 => _bits ~/ 8,
    _ => 8,
  };

  int _narrow(int v) => _bits == 64 ? v : (_signed ? v.toSigned(_bits) : v.toUnsigned(_bits));

  int _load(int address) => switch ((_bits, _signed)) {
    (8, true) => Pointer<Int8>.fromAddress(address).value,
    (8, false) => Pointer<Uint8>.fromAddress(address).value,
    (16, true) => Pointer<Int16>.fromAddress(address).value,
    (16, false) => Pointer<Uint16>.fromAddress(address).value,
    (32, true) => Pointer<Int32>.fromAddress(address).value,
    (32, false) => Pointer<Uint32>.fromAddress(address).value,
    _ => Pointer<Int64>.fromAddress(address).value,
  };

  /// Writes [v] at [address] as this type; a `String` needs a scope, so it is refused.
  void _store(int address, T v) {
    switch (_kind) {
      case _int:
        switch (_bits) {
          case 8:
            Pointer<Uint8>.fromAddress(address).value = (v as int).toUnsigned(8);
          case 16:
            Pointer<Uint16>.fromAddress(address).value = (v as int).toUnsigned(16);
          case 32:
            Pointer<Uint32>.fromAddress(address).value = (v as int).toUnsigned(32);
          default:
            Pointer<Int64>.fromAddress(address).value = v as int;
        }
      case _flag:
        Pointer<Uint8>.fromAddress(address).value = v == true ? 1 : 0;
      case _ptr:
        Pointer<IntPtr>.fromAddress(address).value = (v as Pointer).address;
      case _f64:
        Pointer<Double>.fromAddress(address).value = v as double;
      case _f32:
        Pointer<Float>.fromAddress(address).value = v as double;
      default:
        throw UnsupportedError('cannot store a $this; write a C.ptr from Scope.text');
    }
  }

  /// A raw 64-bit return, narrowed to what the callee actually defined.
  T _read(int raw) => switch (_kind) {
    _int => _narrow(raw) as T,
    _flag => (raw & 0xff != 0) as T,
    _ptr => Pointer<Void>.fromAddress(raw) as T,
    _str => (raw == 0 ? null : _cString(Pointer<Uint8>.fromAddress(raw))) as T,
    _ => null as T,
  };

  /// A return from either register file: `int` from the integer one, `double` from the other.
  T _take(Object raw) => raw is double ? _fromReal(raw) : _read(raw as int);

  /// A return from the floating-point register.
  T _fromReal(double raw) => (_kind == _f32 ? _floatOf(raw) : (_kind == _void ? null : raw)) as T;

  _Bool get _real => _kind == _f64 || _kind == _f32;

  @override
  String toString() => switch (_kind) {
    _void => 'C.none',
    _int => 'C.${_signed ? 'i' : 'u'}$_bits',
    _flag => 'C.bool',
    _ptr => 'C.ptr',
    _str => 'C.str',
    _f64 => 'C.f64',
    _ => 'C.f32',
  };
}

// A `float` travels in the low 32 bits of a floating-point register, which a `double` with
// those bits and a zero top half occupies exactly: that `double` is the argument, and the low
// half of a returned one is the result.
final _scratch = ByteData(8);

double _floatBits(double x) =>
    (_scratch
          ..setFloat32(0, x, Endian.little)
          ..setUint32(4, 0, Endian.little))
        .getFloat64(0, Endian.little);

double _floatOf(double raw) => (_scratch..setFloat64(0, raw, Endian.little)).getFloat32(0, Endian.little);

/// A struct's members laid out the way C lays them out: each at its natural alignment, the
/// whole padded to the widest. Members are [Field]s, so each is named once:
///
/// ```dart
/// final sec = C.i64.field, nsec = C.i64.field;
/// final timespec = C.struct([sec, nsec]);
/// Ffi.scope((s) {
///   final ts = s.alloc(timespec.size);
///   libc.call('clock_gettime', C.i32, 0, ts);
///   print(sec[ts]);
/// });
/// ```
///
/// A struct travels by pointer; one passed or returned by value needs `dart:ffi`.
///
/// {@category Native}
final class Layout {
  Layout._(List<Field<Object?>> fields) {
    var at = 0, widest = 1;
    for (final f in fields) {
      if (f._offset >= 0) throw ArgumentError.value(f, 'fields', 'a field belongs to one struct; make another');
      final n = f._key._size;
      at = (at + n - 1) ~/ n * n;
      f._offset = at;
      at += n;
      if (n > widest) widest = n;
    }
    size = (at + widest - 1) ~/ widest * widest;
  }

  /// Its `sizeof`, for [Scope.alloc].
  late final int size;
}

/// One member of a [Layout], read and written through a pointer to the struct: `sec[ts]`,
/// `sec[ts] = 0`.
///
/// {@category Native}
final class Field<T> {
  Field._(this._key);

  final C<T> _key;
  int _offset = -1;

  /// The member in the struct at [p].
  T operator [](Pointer p) => _key.at(_address(p));

  /// Writes the member in the struct at [p].
  void operator []=(Pointer p, T value) => _key._store(_address(p), value);

  int _address(Pointer p) =>
      _offset < 0 ? throw StateError('the field is not in a struct yet: C.struct([...])') : p.address + _offset;

  @override
  String toString() => '$_key.field';
}
