/// # Native
///
/// `NativeLib`: the loader for `dart_toolkit_native`, the Rust library that gives `hash`,
/// `fs` and `http` the same fast functions on every platform. Import it to ask
/// `NativeLib.isAvailable` before calling something that needs it.
///
/// It is `NativeLib` and not `Native` because the barrel exports it, and a package name
/// silently beats a `dart:` one: `Native` hid `dart:ffi`'s `@Native` from every program that
/// imported both. Calling some other C library is `package:dart_toolkit/ffi.dart`.
///
/// {@category Native}
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

part 'src/native/native.dart';
