/// # Hashing & Encoding
///
/// Digests and checksums of files, bytes and text; HMAC; hex, base64 and base32; secure
/// random bytes, tokens and UUIDs. The algorithm is an argument — `text.hash(Hash.sha256)`,
/// `file.hash(Hash.blake3)` — one spelling for all twenty. Digests run in the native library
/// (`NativeLib`) and throw [UnsupportedError] without it; encodings and randomness are pure Dart.
///
/// It identifies, verifies and encodes data; protecting it (ciphers, password hashing,
/// signatures, JWT) is out of scope on purpose.

///
/// {@category Hashing}
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'native.dart';

part 'src/hash/codec.dart';
part 'src/hash/digest.dart';
part 'src/hash/native.dart';
part 'src/hash/random.dart';
