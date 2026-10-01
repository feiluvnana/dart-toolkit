/// # Native
///
/// `NativeLib`: the loader for `dart_toolkit_native`, the Rust library behind `hash`, `fs`
/// and `http`. Ask `NativeLib.isAvailable` before calling something that needs it.
///
/// Not `Native`: the barrel exports it, and it would hide `dart:ffi`'s `@Native`.

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
