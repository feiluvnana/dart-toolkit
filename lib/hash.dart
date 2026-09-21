/// # Hashing & Encoding
///
/// Digests and checksums of files, bytes and text; HMAC; hex, base64 and base32; secure
/// random bytes, tokens and UUIDs. The digests run in the toolkit's native library
/// (`Native`) and throw [UnsupportedError] naming what they needed when it did not load;
/// the encodings and the random helpers are pure Dart and always work.
///
/// This is what a script needs to identify, verify and encode data. Protecting data —
/// ciphers, password hashing, key agreement, signatures, JWT — is not here on purpose: an
/// automation toolkit has no business owning that, and getting it wrong is expensive.
///
/// {@category Hashing}
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'fs.dart';
import 'native.dart';

part 'src/hash/codec.dart';
part 'src/hash/digest.dart';
part 'src/hash/native.dart';
part 'src/hash/random.dart';
