/// # Native
///
/// `Native`: the loader for `dart_toolkit_native`, the Rust library that gives `crypto` and
/// `fs` the same fast functions on every platform. Import it to ask `Native.isAvailable`.
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
