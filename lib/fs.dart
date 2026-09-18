/// # Filesystem & Paths
///
/// `Path`: an ergonomic, `String`-compatible filesystem path, with zip archives on it — the
/// container written and read here, the compression the platform's zlib.
///
/// {@category Files}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'core.dart';

part 'src/fs/path.dart';
part 'src/fs/zip.dart';
part 'src/fs/zip_extensions.dart';
