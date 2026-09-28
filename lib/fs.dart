/// # Filesystem & Paths
///
/// `Path`: an ergonomic, `String`-compatible filesystem path, and every archive format on it
/// through the native library.
///
/// {@category Files}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'core.dart';
import 'native.dart';

part 'src/fs/archive.dart';
part 'src/fs/path.dart';
