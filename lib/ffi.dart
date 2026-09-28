/// # Ffi
///
/// Call a C function from a script in one line, with no codegen and no `lookupFunction<N, D>`
/// pair written by hand:
///
/// ```dart
/// import 'package:dart_toolkit/ffi.dart';
///
/// final libc = Ffi.open('c');                   // libc.dylib, libc.so.6, ucrtbase.dll
/// final strlen = libc.fn('strlen', C.i64);      // looked up once, called like a function
/// strlen('hello');                              // 5 — a String goes in as a scoped UTF-8 char*
/// libc.call('getenv', C.str, 'HOME');           // a char* comes back as a String?
/// libc.call('ldexp', C.f64, 1.0, 10);           // 1024.0 — integers and doubles mix
/// libc.call('sqrtf', C.f32, C.f32(2.0));        // a float, written as one
/// libc.call('atof', C.f64, '2.5');              // 2.5
///
/// final name = Uint8List(64);                   // a typed list is copied in and back out
/// libc.call('gethostname', C.i32, name, name.length);
///
/// Ffi.scope((s) {
///   final end = s.out(C.ptr);                   // an out-parameter: char **endptr
///   libc.call('strtol', C.i64, s.text('42 rest'), end, 10);  // 42
///   C.u8.list(end.value, 5);                    // " rest", viewed where it lies
/// });
///
/// if (libc.call('open', C.i32, '/nope', 0) < 0) print(Ffi.errno);  // 2, ENOENT
/// libc.fn('snprintf', C.i32, fixed: 3)(name, 64, '%d %s', 42, 'hi');  // variadic
///
/// final data = Int32List.fromList([5, -3, 9]);
/// Ffi.scope((s) => libc.call('qsort', C.none, data, data.length, 4,
///     s.callback((int a, int b) => C.i32.at(a) - C.i32.at(b))));
///
/// final sec = C.i64.field, nsec = C.i64.field;  // a struct, each member named once
/// final timespec = C.struct([sec, nsec]);
///
/// final buf = libc.own(libc.call('malloc', C.ptr, 1024), 'free', size: 1024);  // freed on GC
/// await libc.fn('usleep', C.i32).async(300000);  // on another isolate; this one keeps running
/// ```
///
/// **Its own namespace.** This library is not exported from `dart_toolkit.dart` and never
/// will be. Its names are short on purpose — `Ffi`, `C`, `Lib`, `Fn`, `Scope`, `Out`,
/// `Owned`, `Callback`, `Layout`, `Field` — and short names belong only in the scope of a
/// program that asked for them. None of them is a `dart:ffi` name, so this imports beside
/// `dart:ffi` without a `hide`, and everything it offers hangs off them: `Ffi.open`,
/// `Ffi.scope`, `C.i32`.
///
/// **How it works without codegen.** `dart:ffi` needs a signature as a compile-time constant,
/// so no generic helper can forward one. Instead every call goes through a signature wide
/// enough for all of them: on the 64-bit ABIs Dart runs on, arguments travel in slots the
/// caller owns, and a callee ignores the ones it does not declare. SysV x64 and AAPCS64 fill
/// the integer and the floating-point registers independently, so one
/// `(Int64 × 8, Double × 8)` signature calls any mix of up to eight; Win64 assigns registers by
/// position, so there a call is all integers or all doubles. A `float` is the low half of a
/// `double` register, which is what `C.f32(x)` builds and `C.f32` reads back. A variadic
/// function goes through a `VarArgs` signature per fixed count, so the caller does what the
/// platform's `...` expects. The return is the one thing a callee leaves partly undefined,
/// which is why it is named by a typed key — [C] — and not guessed.
///
/// **What it does not do**, and where to go instead — plain `lookupFunction`, which works
/// beside it: structs by value, more than eight arguments, a variadic function returning a
/// `double`, callbacks that take doubles or are called from a thread C started, a mix of
/// integers and doubles on Windows, and 32-bit platforms. Each is refused with an
/// [ArgumentError], except a variadic function called without `fixed:`, which cannot be told
/// apart and reads garbage.
///
/// {@category Native}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

part 'src/ffi/call.dart';
part 'src/ffi/key.dart';
part 'src/ffi/library.dart';
part 'src/ffi/memory.dart';
part 'src/ffi/shapes.dart';
