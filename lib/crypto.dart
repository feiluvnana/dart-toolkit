/// # Crypto
///
/// Digests of a file, streamed, or of bytes and strings in memory — MD5, SHA-1, SHA-2, CRC-32,
/// HMAC — on the platform's native library where there is one, in Dart where there is not.
///
/// {@category Files}
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'core.dart';
import 'fs.dart';

part 'src/crypto/hash.dart';
part 'src/crypto/native.dart';
