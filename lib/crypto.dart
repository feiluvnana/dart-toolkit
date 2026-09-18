/// # Crypto
///
/// Digests and checksums, HMAC, key derivation, password hashing, authenticated encryption,
/// key agreement, signatures, JWT and TOTP, the same on every platform through the toolkit's
/// native library (`Native`). Every primitive is native; without the library the module throws
/// `UnsupportedError` naming what it needed.
///
/// {@category Crypto}
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'fs.dart';
import 'native.dart';

part 'src/crypto/agree.dart';
part 'src/crypto/cipher.dart';
part 'src/crypto/codec.dart';
part 'src/crypto/hash.dart';
part 'src/crypto/jwt.dart';
part 'src/crypto/keys.dart';
part 'src/crypto/native.dart';
part 'src/crypto/otp.dart';
part 'src/crypto/sign.dart';
