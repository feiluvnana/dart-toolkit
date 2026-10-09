/// # Archives
///
/// Zip, 7z, tar and its gz, xz, zstd and bzip2 forms, RAR (read), and single gzip, xz, zstd
/// and bzip2 streams, through the native library: `dir.archive(to: 'x.zip')`,
/// `file.unarchive(into: 'out')`, and `Archive.read` to look inside without extracting.
///
/// {@category Files}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'src/core.dart';
import 'src/native.dart';
import 'path.dart';

export 'path.dart';

part 'src/fs/archive.dart';
