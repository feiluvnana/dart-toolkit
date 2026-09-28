part of '../../ffi.dart';

// The native signatures everything is called through.
//
// `dart:ffi` needs a signature as a compile-time constant, so nothing generic can be forwarded
// to it; what can be constant is a signature wide enough for every call. On the 64-bit ABIs
// Dart runs on, arguments travel in slots the caller owns and cleans up, and a callee ignores
// the slots it does not declare — so zeros in the unused ones are harmless. Go's
// `syscall.Syscall6` is the same trick. The return is the one thing the callee leaves partly
// undefined, which is why it is read through a typed key.
//
// * SysV x64 and AAPCS64 hand out integer and floating-point registers independently, so one
//   `(Int64 × 8, Double × 8)` shape calls any mix: the integers go into the first, the doubles
//   into the second, each in order. Eight is AAPCS64's register count; on SysV the seventh and
//   eighth integers go on the stack in the order the callee reads them.
// * Win64 assigns registers by position, so it has only the all-integer and all-double shapes,
//   and a mix is refused.
// * The all-integer six is also the fast path everywhere: it is what most calls are.

typedef _W = Int64;
typedef _D = Double;
typedef _Ints = int Function(int a, int b, int c, int d, int e, int f);
typedef _IntsD = double Function(int a, int b, int c, int d, int e, int f);
typedef _Reals = double Function(double a, double b, double c, double d, double e, double f);
typedef _RealsI = int Function(double a, double b, double c, double d, double e, double f);
typedef _Mixed =
    int Function(
      int a,
      int b,
      int c,
      int d,
      int e,
      int f,
      int g,
      int h,
      double p,
      double q,
      double r,
      double s,
      double t,
      double u,
      double v,
      double w,
    );
typedef _MixedD =
    double Function(
      int a,
      int b,
      int c,
      int d,
      int e,
      int f,
      int g,
      int h,
      double p,
      double q,
      double r,
      double s,
      double t,
      double u,
      double v,
      double w,
    );
typedef _Flat = int Function(int a, int b, int c, int d, int e, int f, int g, int h);

typedef _NInts = _W Function(_W, _W, _W, _W, _W, _W);
typedef _NIntsD = _D Function(_W, _W, _W, _W, _W, _W);
typedef _NReals = _D Function(_D, _D, _D, _D, _D, _D);
typedef _NRealsI = _W Function(_D, _D, _D, _D, _D, _D);
typedef _NMixed = _W Function(_W, _W, _W, _W, _W, _W, _W, _W, _D, _D, _D, _D, _D, _D, _D, _D);
typedef _NMixedD = _D Function(_W, _W, _W, _W, _W, _W, _W, _W, _D, _D, _D, _D, _D, _D, _D, _D);

_Ints _ints(Pointer<Void> p) => p.cast<NativeFunction<_NInts>>().asFunction<_Ints>();
_IntsD _intsD(Pointer<Void> p) => p.cast<NativeFunction<_NIntsD>>().asFunction<_IntsD>();
_Reals _reals(Pointer<Void> p) => p.cast<NativeFunction<_NReals>>().asFunction<_Reals>();
_RealsI _realsI(Pointer<Void> p) => p.cast<NativeFunction<_NRealsI>>().asFunction<_RealsI>();
_Mixed _mixed(Pointer<Void> p) => p.cast<NativeFunction<_NMixed>>().asFunction<_Mixed>();
_MixedD _mixedD(Pointer<Void> p) => p.cast<NativeFunction<_NMixedD>>().asFunction<_MixedD>();

/// Whether this ABI passes arguments by position (Win64) rather than by register file.
final _positional = Platform.isWindows;

// Variadic functions, by how many arguments are fixed. `VarArgs` is what makes the caller do
// what a variadic callee expects: on SysV x64 set `al` to the vector registers used, on Apple
// arm64 put the variadic part on the stack. Apple arm64 and Windows read every variadic
// argument from an 8-byte integer slot, so there the doubles go as their bits ([_flat]); SysV
// and Linux arm64 read them from the floating-point registers ([_split]).
final _flatVarArgs = switch (Abi.current()) {
  Abi.macosArm64 || Abi.iosArm64 || Abi.windowsX64 || Abi.windowsArm64 => true,
  _ => false,
};

_Flat _flat(Pointer<Void> p, int fixed) => switch (fixed) {
  1 => p.cast<NativeFunction<_W Function(_W, VarArgs<(_W, _W, _W, _W, _W, _W, _W)>)>>().asFunction<_Flat>(),
  2 => p.cast<NativeFunction<_W Function(_W, _W, VarArgs<(_W, _W, _W, _W, _W, _W)>)>>().asFunction<_Flat>(),
  3 => p.cast<NativeFunction<_W Function(_W, _W, _W, VarArgs<(_W, _W, _W, _W, _W)>)>>().asFunction<_Flat>(),
  4 => p.cast<NativeFunction<_W Function(_W, _W, _W, _W, VarArgs<(_W, _W, _W, _W)>)>>().asFunction<_Flat>(),
  _ => throw ArgumentError.value(fixed, 'fixed', 'a variadic function takes 1 to 4 fixed arguments here'),
};

_Mixed _split(Pointer<Void> p, int fixed) => switch (fixed) {
  1 =>
    p
        .cast<NativeFunction<_W Function(_W, VarArgs<(_W, _W, _W, _W, _W, _W, _W, _D, _D, _D, _D, _D, _D, _D, _D)>)>>()
        .asFunction<_Mixed>(),
  2 =>
    p
        .cast<NativeFunction<_W Function(_W, _W, VarArgs<(_W, _W, _W, _W, _W, _W, _D, _D, _D, _D, _D, _D, _D, _D)>)>>()
        .asFunction<_Mixed>(),
  3 =>
    p
        .cast<NativeFunction<_W Function(_W, _W, _W, VarArgs<(_W, _W, _W, _W, _W, _D, _D, _D, _D, _D, _D, _D, _D)>)>>()
        .asFunction<_Mixed>(),
  4 =>
    p
        .cast<NativeFunction<_W Function(_W, _W, _W, _W, VarArgs<(_W, _W, _W, _W, _D, _D, _D, _D, _D, _D, _D, _D)>)>>()
        .asFunction<_Mixed>(),
  _ => throw ArgumentError.value(fixed, 'fixed', 'a variadic function takes 1 to 4 fixed arguments here'),
};

// Callbacks the other way round: C calls one four-slot shape and the Dart function takes as many
// as it declares. Four is the most every ABI passes in registers (Win64's limit).
typedef _I = IntPtr;
typedef _Callback = _I Function(_I, _I, _I, _I);

NativeCallable<_Callback> _callable(Function f) {
  // A literal `(a, b) => …` has `dynamic` parameters, which makes it an
  // `Object? Function(int, int)`: it matches without the caller writing a type.
  final Object? Function(int, int, int, int) g = switch (f) {
    final Object? Function() g => (a, b, c, d) => g(),
    final Object? Function(int) g => (a, b, c, d) => g(a),
    final Object? Function(int, int) g => (a, b, c, d) => g(a, b),
    final Object? Function(int, int, int) g => (a, b, c, d) => g(a, b, c),
    final Object? Function(int, int, int, int) g => g,
    _ => throw ArgumentError.value(f, 'f', 'a callback takes 0 to 4 integer arguments; anything else needs dart:ffi'),
  };
  return NativeCallable<_Callback>.isolateLocal((int a, int b, int c, int d) {
    try {
      return switch (g(a, b, c, d)) {
        null => 0,
        final int i => i,
        final bool b => b ? 1 : 0,
        final Pointer p => p.address,
        final Owned o => o._address,
        final Callback c => c._address,
        final Out<Object?> o => o.ptr.address,
        final other => _refuse('returned a ${other.runtimeType}, which C cannot take as an integer'),
      };
    } catch (e, st) {
      // C cannot receive an exception, and a silent 0 hides the bug: say it, then return 0.
      return _refuse('threw $e\n$st');
    }
  }, exceptionalReturn: 0);
}

int _refuse(String what) {
  stderr.writeln('dart_toolkit/ffi: a callback $what; C receives 0');
  return 0;
}
