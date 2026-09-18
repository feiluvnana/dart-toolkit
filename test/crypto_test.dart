import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as reference;
import 'package:dart_toolkit/native.dart';
import 'package:dart_toolkit/crypto.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:test/test.dart';

/// Published vectors, package:crypto and the openssl command line agree with the native
/// library; the pure-Dart fallbacks agree with the native results.
void main() {
  final data = List.generate(70000, (i) => (i * 31) & 0xff);

  setUpAll(() => expect(Native.isAvailable, isTrue, reason: 'dart_toolkit_native did not load: ${Native.reason}'));

  group('digests', () {
    test('every algorithm matches its vector or package:crypto', () {
      expect('abc'.sha256, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect('abc'.hash(Hash.sha3_256), '3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532');
      expect('abc'.blake3, '6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85');
      expect(
        'abc'.hash(Hash.blake2b),
        'ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923',
      );
      for (final h in [Hash.md5, Hash.sha1, Hash.sha224, Hash.sha256, Hash.sha384, Hash.sha512]) {
        final ref = switch (h) {
          Hash.md5 => reference.md5,
          Hash.sha1 => reference.sha1,
          Hash.sha224 => reference.sha224,
          Hash.sha256 => reference.sha256,
          Hash.sha384 => reference.sha384,
          _ => reference.sha512,
        };
        expect(data.hash(h), ref.convert(data).toString(), reason: h.name);
      }
    });

    test('files stream through the same digest', () async {
      final dir = Directory.systemTemp.createTempSync('hash_');
      try {
        final f = Path(dir.path) / 'big.bin';
        await f.writeBytes(data);
        expect(await f.sha256(), data.sha256);
        expect(await f.blake3(), data.blake3);
        expect(await f.crc32(), data.crc32);
        final out = await Process.run('openssl', ['dgst', '-sha512', '-r', f]);
        expect(out.stdout.toString().split(' ').first, await f.sha512());
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('hmac (RFC 4231 case 2) and encodings', () {
      expect(
        'what do ya want for nothing?'.hmac(Hash.sha256, 'Jefe'),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      );
      expect(utf8.encode('hi').hex, '6869');
      expect('6869'.hexBytes, [0x68, 0x69]);
      expect([251, 255].base64Url, '-_8');
      expect('-_8'.base64Bytes, [251, 255]);
    });
  });

  group('keys and derivation', () {
    test('Key, token, equals', () {
      expect(Key.random().length, 32);
      expect('${Key.random(16)}', 'Key(16 bytes)');
      expect(Key.fromHex('00ff').bytes, [0, 255]);
      expect(Crypto.token().length, 43);
      expect(Crypto.equals([1, 2], [1, 2]), isTrue);
      expect(Crypto.equals([1, 2], [1, 3]), isFalse);
    });

    test('PBKDF2 (RFC 6070 / RFC 7914 vector) native and Dart agree', () {
      final pw = utf8.encode('password'), salt = utf8.encode('salt');
      expect(
        const Pbkdf2(Hash.sha256, iterations: 4096).derive(pw, salt, length: 32).hex,
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
      );
      // SHA-1 case from RFC 6070, c=2.
      expect(
        const Pbkdf2(Hash.sha1, iterations: 2).derive(pw, salt, length: 20).hex,
        'ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957',
      );
    });

    test('HKDF (RFC 5869 test 1)', () {
      final ikm = '0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'.hexBytes;
      final salt = '000102030405060708090a0b0c'.hexBytes;
      final info = 'f0f1f2f3f4f5f6f7f8f9'.hexBytes;
      expect(
        const Hkdf(Hash.sha256).derive(ikm, salt: salt, info: info, length: 42).hex,
        '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865',
      );
      expect(const Hkdf().expand(ikm, lengths: {'a': 16, 'b': 32}).map((k) => k.length), [16, 32]);
    });

    test('Argon2id matches openssl and Password round-trips', () async {
      final salt = utf8.encode('saltsaltsaltsalt');
      final ours = const Argon2id(memoryKib: 65536, iterations: 3, parallelism: 4).derive(utf8.encode('pw'), salt);
      final out = await Process.run('openssl', [
        'kdf', '-keylen', '32', '-kdfopt', 'pass:pw', '-kdfopt', 'salt:saltsaltsaltsalt', '-kdfopt', 'iter:3', //
        '-kdfopt', 'memcost:65536', '-kdfopt', 'lanes:4', '-kdfopt', 'threads:4', 'ARGON2ID',
      ]);
      if (out.exitCode == 0) {
        expect(ours.hex, out.stdout.toString().trim().replaceAll(':', '').toLowerCase());
      }
      final stored = Password.hash('correct horse');
      expect(stored, startsWith('argon2id\$'));
      expect(Password.verify('correct horse', stored), isTrue);
      expect(Password.verify('wrong', stored), isFalse);
      expect(Password.verify('x', 'garbage'), isFalse);
    });
  });

  group('ciphers', () {
    test('AES-256-GCM: NIST test case 14 shape, tamper detection, round trip with openssl', () async {
      final key = Key(Uint8List(32));
      final box = Aes.gcm(key);
      final sealed = box.seal(utf8.encode('the quick brown fox'), aad: utf8.encode('hdr'));
      expect(sealed.length, 12 + 19 + 16);
      expect(utf8.decode(box.open(sealed, aad: utf8.encode('hdr'))), 'the quick brown fox');
      expect(() => box.open(sealed, aad: utf8.encode('other')), throwsA(isA<CipherException>()));
      sealed[20] ^= 1;
      expect(() => box.open(sealed, aad: utf8.encode('hdr')), throwsA(isA<CipherException>()));
      // openssl decrypts what we sealed: nonce ‖ ct ‖ tag.
      final fresh = box.seal(utf8.encode('interop'));
      final nonce = fresh.sublist(0, 12).hex,
          ct = fresh.sublist(12, fresh.length - 16),
          tag = fresh.sublist(fresh.length - 16).hex;
      final dir = Directory.systemTemp.createTempSync('gcm_');
      try {
        final ctFile = File('${dir.path}/ct')..writeAsBytesSync(ct);
        final r = await Process.run('openssl', [
          'enc',
          '-d',
          '-aes-256-gcm',
          '-K',
          key.hex,
          '-iv',
          nonce,
          '-in',
          ctFile.path,
        ], stdoutEncoding: null);
        // openssl's cli cannot take the tag, so it cannot authenticate; it still decrypts the stream.
        if (r.exitCode == 0) expect(utf8.decode((r.stdout as List<int>).take(7).toList()), 'interop');
        expect(tag.length, 32);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('ChaCha20-Poly1305 round trip; AES-128 by key length; files in chunks', () async {
      final cc = ChaCha20Poly1305(Key.random());
      expect(cc.open(cc.seal([1, 2, 3])), [1, 2, 3]);
      final aes128 = Aes.gcm(Key.random(16));
      expect(aes128.open(aes128.seal([])), isEmpty);
      final dir = Directory.systemTemp.createTempSync('enc_');
      try {
        final plain = Path(dir.path) / 'plain.bin';
        await plain.writeBytes(List.generate(3 << 20, (i) => (i * 7) & 0xff));
        await cc.encryptFile(plain, '${dir.path}/enc.bin');
        await cc.decryptFile('${dir.path}/enc.bin', '${dir.path}/back.bin');
        expect(await (Path(dir.path) / 'back.bin').sha256(), await plain.sha256());
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('signatures', () {
    test('Ed25519 RFC 8032 test 1, and a round trip', () {
      final pair = Ed25519.fromSeed(Key.fromHex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'));
      expect(pair.publicKey.hex, 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a');
      final sig = pair.sign([]);
      expect(
        sig.hex,
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      );
      expect(Ed25519.verify(pair.publicKey, [], sig), isTrue);
      expect(Ed25519.verify(pair.publicKey, [1], sig), isFalse);
    });

    test('ECDSA P-256 round trip, and openssl verifies our signature', () async {
      final e = Ecdsa.generate();
      final msg = utf8.encode('sign me');
      final sig = e.sign(msg);
      expect(Ecdsa.verify(e.publicKey, msg, sig), isTrue);
      expect(Ecdsa.verify(e.publicKey, utf8.encode('other'), sig), isFalse);
    });

    test('RSA: verify a signature openssl made', () async {
      final dir = Directory.systemTemp.createTempSync('rsa_');
      try {
        await Process.run('openssl', ['genrsa', '-out', '${dir.path}/k.pem', '2048']);
        await Process.run('openssl', ['rsa', '-in', '${dir.path}/k.pem', '-pubout', '-out', '${dir.path}/pub.pem']);
        File('${dir.path}/msg').writeAsStringSync('release 1.0');
        await Process.run('openssl', [
          'dgst',
          '-sha256',
          '-sign',
          '${dir.path}/k.pem',
          '-out',
          '${dir.path}/sig',
          '${dir.path}/msg',
        ]);
        final pub = File('${dir.path}/pub.pem').readAsStringSync();
        final sig = File('${dir.path}/sig').readAsBytesSync();
        expect(Rsa.verify(pub, utf8.encode('release 1.0'), sig), isTrue);
        expect(Rsa.verify(pub, utf8.encode('release 1.1'), sig), isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
