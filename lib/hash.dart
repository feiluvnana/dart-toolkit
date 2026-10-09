/// # Hashing & Encoding
///
/// Digests and checksums of text, bytes, files and streams; MACs; hex, base32 and base64;
/// secure random bytes, tokens and UUIDs. The algorithm is the receiver, and every input form
/// gives a [Digest]: `Hash.sha256.text(s)`, `await Hash.blake3.file(path)`, `key:` for a MAC.
/// Digests run in the native library (`Native`) and throw [UnsupportedError] without it;
/// encodings and randomness are pure Dart.
///
/// It identifies, verifies and encodes data; protecting it (ciphers, password hashing,
/// signatures, JWT) is out of scope on purpose.
///
/// {@category Hashing}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'src/core.dart';
import 'src/native.dart';

export 'core.dart';
export 'src/native.dart' show NativeException;

part 'src/hash/codec.dart';
part 'src/hash/digest.dart';
part 'src/hash/hex.dart';
part 'src/hash/native.dart';
part 'src/hash/random.dart';
