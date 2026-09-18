/// # Hashing
///
/// SHA-256 and MD5 digests of a file, streamed, or of bytes in memory — on the platform's
/// native library where there is one, in Dart where there is not.
///
/// {@category Files}
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'fs.dart';

part 'src/hash/hash.dart';
part 'src/hash/native.dart';
