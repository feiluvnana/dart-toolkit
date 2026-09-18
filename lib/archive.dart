/// # Archives
///
/// Zip and unzip operations on `Path`, with the platform's zlib for compression and an
/// in-house reader and writer for the container.
///
/// {@category Files}
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'fs.dart';
import 'util.dart';

part 'src/archive/archive.dart';
part 'src/archive/zip.dart';
