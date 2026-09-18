/// # Crypto
///
/// Digests, MACs, key derivation, authenticated encryption and signatures, the same on every
/// platform through the toolkit's own native library (`Native`), with pure Dart for digests,
/// HMAC, HKDF and PBKDF2 when it is absent.
///
/// {@category Crypto}
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'fs.dart';
import 'native.dart';

part 'src/crypto/cipher.dart';
part 'src/crypto/hash.dart';
part 'src/crypto/keys.dart';
part 'src/crypto/native.dart';
part 'src/crypto/sign.dart';
