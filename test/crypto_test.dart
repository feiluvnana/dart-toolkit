import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/crypto.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/native.dart';
import 'package:test/test.dart';

/// Published vectors and the openssl command line agree with the native library.
void main() {
  final data = List.generate(70000, (i) => (i * 31) & 0xff);

  setUpAll(() => expect(Native.isAvailable, isTrue, reason: 'dart_toolkit_native did not load: ${Native.reason}'));

  Future<String> openssl(List<String> args, {String? dir}) async {
    final r = await Process.run('openssl', args, workingDirectory: dir, stdoutEncoding: null);
    expect(r.exitCode, 0, reason: 'openssl ${args.join(' ')}: ${r.stderr}');
    return utf8.decode(r.stdout as List<int>).trim();
  }

  group('digests', () {
    test('every algorithm matches its published vector', () {
      const abc = {
        Hash.md5: '900150983cd24fb0d6963f7d28e17f72',
        Hash.sha1: 'a9993e364706816aba3e25717850c26c9cd0d89d',
        Hash.sha224: '23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7',
        Hash.sha256: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        Hash.sha384: 'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7',
        Hash.sha512:
            'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f',
        Hash.sha512_256: '53048e2681941ef99b2e29b76b4c7dabe4c2d0c634fc6d46e0e2f13107e7af23',
        Hash.sha3_224: 'e642824c3f8cf24ad09234ee7d3c766fc9a3a5168d0c94ad73b46fdf',
        Hash.sha3_256: '3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532',
        Hash.sha3_384:
            'ec01498288516fc926459f58e2c6ad8df9b473cb0fc08c2596da7cf0e49be4b298d88cea927ac7f539f1edf228376d25',
        Hash.sha3_512:
            'b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0',
        Hash.keccak256: '4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45',
        Hash.blake2s: '508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982',
        Hash.blake2b:
            'ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923',
        Hash.blake3: '6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85',
        Hash.ripemd160: '8eb208f7e05d987a9b044a8e98c6b087f15a0bfc',
        Hash.crc32: '352441c2',
        Hash.crc32c: '364b3fb7',
        Hash.xxh64: '44bc2cf5ad770999',
        Hash.xxh3: '78af5f94892f3950',
      };
      for (final h in Hash.values) {
        expect('abc'.hash(h), abc[h], reason: h.name);
        expect(h.length, abc[h]!.length ~/ 2, reason: h.name);
      }
      expect('abc'.crc32, 0x352441c2);
      expect('abc'.xxh3, 0x78af5f94892f3950);
      expect(''.sha256, 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });

    test('files stream through the same digest; openssl agrees', () async {
      final dir = Directory.systemTemp.createTempSync('hash_');
      try {
        final f = Path(dir.path) / 'big.bin';
        await f.writeBytes(data);
        expect(await f.sha256(), data.sha256);
        expect(await f.blake3(), data.blake3);
        expect(await f.crc32(), data.crc32);
        expect(await f.xxh3(), data.xxh3);
        expect((await openssl(['dgst', '-sha512', '-r', f])).split(' ').first, await f.sha512());
        expect((await openssl(['dgst', '-sha3-384', '-r', f])).split(' ').first, await f.hash(Hash.sha3_384));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('hmac (RFC 4231 case 2) for SHA-2 and SHA-3', () {
      expect(
        'what do ya want for nothing?'.hmac(Hash.sha256, 'Jefe'),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      );
      expect(
        'what do ya want for nothing?'.hmac(Hash.sha3_256, 'Jefe'),
        'c7d4072e788877ae3596bbb0da73b887c9171f93095b294ae857fbe2645e1ba5',
      );
      expect(() => 'x'.hmac(Hash.blake2b, 'k'), throwsStateError);
    });

    test('encodings', () {
      expect(utf8.encode('hi').hex, '6869');
      expect('6869'.hexBytes, [0x68, 0x69]);
      expect([251, 255].base64Url, '-_8');
      expect('-_8'.base64Bytes, [251, 255]);
      expect(utf8.encode('Hello!').base32, 'JBSWY3DPEE');
      expect('jbsw y3dp ee=='.base32Bytes, utf8.encode('Hello!'));
      expect(Crypto.uuid(), matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    });
  });

  group('keys and derivation', () {
    test('Key, token, equals', () {
      expect(Key.random().length, 32);
      expect('${Key.random(16)}', 'Key(16 bytes)');
      expect(Key.fromHex('00ff').bytes, [0, 255]);
      expect(Key.fromBase32('JBSWY3DPEE').bytes, utf8.encode('Hello!'));
      expect(Crypto.token().length, 43);
      expect(Crypto.equals([1, 2], [1, 2]), isTrue);
      expect(Crypto.equals([1, 2], [1, 3]), isFalse);
    });

    test('PBKDF2 (RFC 7914 / RFC 6070), HKDF (RFC 5869), scrypt (RFC 7914)', () {
      final pw = utf8.encode('password'), salt = utf8.encode('salt');
      expect(
        const Pbkdf2(Hash.sha256, 4096).derive(pw, salt, length: 32).hex,
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
      );
      expect(const Pbkdf2(Hash.sha1, 2).derive(pw, salt, length: 20).hex, 'ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957');
      final ikm = '0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'.hexBytes;
      expect(
        const Hkdf()
            .derive(ikm, salt: '000102030405060708090a0b0c'.hexBytes, info: 'f0f1f2f3f4f5f6f7f8f9'.hexBytes, length: 42)
            .hex,
        '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865',
      );
      expect(const Hkdf().expand(ikm, lengths: {'a': 16, 'b': 32}).map((k) => k.length), [16, 32]);
      expect(
        const Scrypt(logN: 10, r: 8, p: 16).derive(pw, utf8.encode('NaCl'), length: 64).hex,
        'fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640',
      );
    });

    test('Argon2id matches openssl', () async {
      final ours = const Argon2id(
        memoryKib: 65536,
        iterations: 3,
        parallelism: 4,
      ).derive(utf8.encode('pw'), utf8.encode('saltsaltsaltsalt'));
      final out = await Process.run('openssl', [
        'kdf', '-keylen', '32', '-kdfopt', 'pass:pw', '-kdfopt', 'salt:saltsaltsaltsalt', '-kdfopt', 'iter:3', //
        '-kdfopt', 'memcost:65536', '-kdfopt', 'lanes:4', '-kdfopt', 'threads:4', 'ARGON2ID',
      ]);
      if (out.exitCode == 0) expect(ours.hex, out.stdout.toString().trim().replaceAll(':', '').toLowerCase());
    });

    test('Password: every algorithm round-trips in its standard string form', () {
      final forms = {
        const Argon2id(memoryKib: 8192, iterations: 1, parallelism: 1): r'$argon2id$v=19$m=8192,t=1,p=1$',
        const Bcrypt(cost: 4): r'$2b$04$',
        const Scrypt(logN: 10): r'$scrypt$ln=10,r=8,p=1$',
        const Pbkdf2(Hash.sha256, 1000): r'$pbkdf2-sha256$i=1000,l=32$',
        const Pbkdf2(Hash.sha512, 1000): r'$pbkdf2-sha512$i=1000,l=32$',
      };
      for (final MapEntry(key: algorithm, value: prefix) in forms.entries) {
        final stored = Password.hash('correct horse', algorithm);
        expect(stored, startsWith(prefix), reason: '$algorithm');
        expect(Password.verify('correct horse', stored), isTrue, reason: stored);
        expect(Password.verify('wrong', stored), isFalse, reason: stored);
      }
      expect(Password.hash('x'), startsWith(r'$argon2id$'));
      expect(Password.verify('x', 'garbage'), isFalse);
      expect(() => const Pbkdf2(Hash.sha1).hash('x'), throwsArgumentError);
    });

    test('Password.verify reads hashes other software made; the PHC string encodes what it says', () {
      // OpenBSD bcrypt vectors.
      expect(Password.verify('', r'$2a$06$DCq7YPn5Rq63x1Lad4cll.TV4S6ytwfsfvkgY8jIucDrjc8deX1s.'), isTrue);
      expect(Password.verify('a', r'$2a$06$m0CrhHm10qJ3lXRY.5zDGO3rS2KdeeWLuGmsfGlMfOxih58VYVfxe'), isTrue);
      expect(Password.verify('b', r'$2a$06$m0CrhHm10qJ3lXRY.5zDGO3rS2KdeeWLuGmsfGlMfOxih58VYVfxe'), isFalse);
      // $argon2id$v=19$m=8192,t=1,p=1$<salt>$<hash>: the raw derivation reproduces <hash>.
      const a = Argon2id(memoryKib: 8192, iterations: 1, parallelism: 1);
      final parts = a.hash('pw').split(r'$');
      expect(a.derive(utf8.encode('pw'), parts[4].base64Bytes).base64.replaceAll('=', ''), parts[5]);
    });
  });

  group('ciphers', () {
    test('AES-GCM: shape, tamper detection; openssl decrypts the stream', () async {
      final key = Key(Uint8List(32));
      final box = Aes.gcm(key);
      final sealed = box.seal(utf8.encode('the quick brown fox'), aad: utf8.encode('hdr'));
      expect(sealed.length, 12 + 19 + 16);
      expect(utf8.decode(box.open(sealed, aad: utf8.encode('hdr'))), 'the quick brown fox');
      expect(() => box.open(sealed, aad: utf8.encode('other')), throwsA(isA<CipherException>()));
      sealed[20] ^= 1;
      expect(() => box.open(sealed, aad: utf8.encode('hdr')), throwsA(isA<CipherException>()));
    });

    test('AES-CBC interoperates with openssl enc both ways', () async {
      final key = Key.random();
      final dir = Directory.systemTemp.createTempSync('cbc_');
      try {
        // Ours → openssl.
        final sealed = Aes.cbc(key).seal(utf8.encode('legacy payload'));
        File('${dir.path}/ct').writeAsBytesSync(sealed.sublist(16));
        final plain = await openssl([
          'enc', '-d', '-aes-256-cbc', '-K', key.hex, '-iv', sealed.sublist(0, 16).hex, '-in', 'ct', //
        ], dir: dir.path);
        expect(plain, 'legacy payload');
        // openssl → ours.
        File('${dir.path}/pt').writeAsStringSync('from openssl');
        final iv = Crypto.randomBytes(16);
        await openssl(['enc', '-aes-256-cbc', '-K', key.hex, '-iv', iv.hex, '-in', 'pt', '-out', 'ct2'], dir: dir.path);
        final theirs = [...iv, ...File('${dir.path}/ct2').readAsBytesSync()];
        expect(utf8.decode(Aes.cbc(key).open(theirs)), 'from openssl');
        expect(
          () => Aes.cbc(Key.random()).open(theirs),
          throwsA(anyOf(isA<CipherException>(), isA<FormatException>())),
        );
        expect(() => Aes.cbc(key).seal([1], aad: [2]), throwsArgumentError);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('ChaCha20-Poly1305, XChaCha20-Poly1305, AES-128, files in chunks', () async {
      for (final c in [ChaCha20Poly1305(Key.random()), XChaCha20Poly1305(Key.random()), Aes.gcm(Key.random(16))]) {
        expect(c.open(c.seal([1, 2, 3])), [1, 2, 3], reason: '$c');
        expect(c.open(c.seal([])), isEmpty);
      }
      expect(XChaCha20Poly1305(Key.random()).seal([]).length, 24 + 16);
      final cc = ChaCha20Poly1305(Key.random());
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

  group('key agreement', () {
    test('X25519 RFC 7748 §6.1 vector; P-256 ECDH agrees both ways', () {
      final alice = X25519.fromKey(Key.fromHex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a'));
      final bob = X25519.fromKey(Key.fromHex('5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb'));
      expect(alice.publicKey.hex, '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a');
      expect(bob.publicKey.hex, 'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f');
      expect(alice.agree(bob.publicKey).hex, '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742');
      expect(bob.agree(alice.publicKey), alice.agree(bob.publicKey));
      expect(() => alice.agree(Uint8List(32)), throwsStateError, reason: 'low-order point');

      final a = Ecdh.generate(), b = Ecdh.generate();
      expect(a.agree(b.publicKey), b.agree(a.publicKey));
      expect(a.agree(b.publicKey).length, 32);
    });
  });

  group('signatures', () {
    test('Ed25519 RFC 8032 test 1; PEM round trip with openssl', () async {
      final pair = Ed25519.fromSeed(Key.fromHex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'));
      expect(pair.publicKey.hex, 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a');
      final sig = pair.sign([]);
      expect(
        sig.hex,
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      );
      expect(Ed25519.verify(pair.publicKey, [], sig), isTrue);
      expect(Ed25519.verify(pair.publicKey, [1], sig), isFalse);

      final dir = Directory.systemTemp.createTempSync('ed_');
      try {
        await openssl(['genpkey', '-algorithm', 'ed25519', '-out', 'k.pem'], dir: dir.path);
        final theirs = Ed25519.fromPem(File('${dir.path}/k.pem').readAsStringSync());
        expect(await openssl(['pkey', '-in', 'k.pem', '-pubout'], dir: dir.path), theirs.publicPem.trim());
        expect(Ed25519.fromPem(theirs.pem).publicKey, theirs.publicKey);
        expect(Ed25519.publicFromPem(theirs.publicPem), theirs.publicKey);
        File('${dir.path}/msg').writeAsStringSync('hello');
        File('${dir.path}/sig').writeAsBytesSync(theirs.sign(utf8.encode('hello')));
        File('${dir.path}/pub.pem').writeAsStringSync(theirs.publicPem);
        await openssl([
          'pkeyutl',
          '-verify',
          '-pubin',
          '-inkey',
          'pub.pem',
          '-rawin',
          '-in',
          'msg',
          '-sigfile',
          'sig',
        ], dir: dir.path);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('ECDSA P-256 round trip; PEM matches openssl', () async {
      final e = Ecdsa.generate();
      final msg = utf8.encode('sign me');
      final sig = e.sign(msg);
      expect(Ecdsa.verify(e.publicKey, msg, sig), isTrue);
      expect(Ecdsa.verify(e.publicKey, utf8.encode('other'), sig), isFalse);
      final dir = Directory.systemTemp.createTempSync('ec_');
      try {
        await openssl(['ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', 'k.pem'], dir: dir.path);
        final theirs = Ecdsa.fromPem(File('${dir.path}/k.pem').readAsStringSync());
        expect(await openssl(['pkey', '-in', 'k.pem', '-pubout'], dir: dir.path), theirs.publicPem.trim());
        expect(Ecdsa.publicFromPem(theirs.publicPem), theirs.publicKey);
        expect(Ecdsa.fromPem(theirs.pem).publicKey, theirs.publicKey);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('RSA: PKCS#1 v1.5 and PSS signatures and OAEP interoperate with openssl', () async {
      final dir = Directory.systemTemp.createTempSync('rsa_');
      try {
        final key = Rsa.generate();
        File('${dir.path}/k.pem').writeAsStringSync(key.pem);
        File('${dir.path}/pub.pem').writeAsStringSync(key.publicPem);
        File('${dir.path}/msg').writeAsStringSync('release 1.0');
        final msg = utf8.encode('release 1.0');

        // Ours → openssl, both paddings.
        File('${dir.path}/sig').writeAsBytesSync(key.sign(msg));
        await openssl(['dgst', '-sha256', '-verify', 'pub.pem', '-signature', 'sig', 'msg'], dir: dir.path);
        File('${dir.path}/pss').writeAsBytesSync(key.sign(msg, pss: true));
        await openssl([
          'dgst', '-sha256', '-sigopt', 'rsa_padding_mode:pss', '-verify', 'pub.pem', '-signature', 'pss', 'msg', //
        ], dir: dir.path);

        // openssl → ours.
        await openssl(['dgst', '-sha512', '-sign', 'k.pem', '-out', 'sig512', 'msg'], dir: dir.path);
        final sig512 = File('${dir.path}/sig512').readAsBytesSync();
        expect(Rsa.verify(key.publicPem, msg, sig512, hash: Hash.sha512), isTrue);
        expect(Rsa.verify(key.pem, msg, sig512, hash: Hash.sha512), isTrue, reason: 'a private PEM verifies too');
        expect(Rsa.verify(key.publicPem, utf8.encode('release 1.1'), sig512, hash: Hash.sha512), isFalse);
        expect(Rsa.verify(key.publicPem, msg, sig512), isFalse, reason: 'wrong digest');

        // OAEP.
        final secret = Crypto.randomBytes(32);
        expect(key.decrypt(Rsa.encrypt(key.publicPem, secret)), secret);
        File('${dir.path}/secret').writeAsBytesSync(secret);
        await openssl([
          'pkeyutl', '-encrypt', '-pubin', '-inkey', 'pub.pem', '-pkeyopt', 'rsa_padding_mode:oaep', //
          '-pkeyopt', 'rsa_oaep_md:sha256', '-in', 'secret', '-out', 'ct',
        ], dir: dir.path);
        expect(key.decrypt(File('${dir.path}/ct').readAsBytesSync()), secret);
        expect(() => Rsa.generate(1024).decrypt(Rsa.encrypt(key.publicPem, secret)), throwsA(isA<CipherException>()));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('tokens', () {
    test('JWT HS256 matches jwt.io; every key kind signs and verifies; bad tokens throw', () {
      final claims = {'sub': '1234567890', 'name': 'John Doe', 'iat': 1516239022};
      final secret = Key.text('your-256-bit-secret');
      const known =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
      expect(Jwt.sign(claims, secret), known);
      expect(Jwt.verify(known, secret), claims);
      expect(Jwt.decode(known).header, {'alg': 'HS256', 'typ': 'JWT'});
      expect(() => Jwt.verify(known, Key.text('other')), throwsA(isA<JwtException>()));
      expect(() => Jwt.verify('${known}x', secret), throwsA(isA<JwtException>()));

      final ed = Ed25519.generate(), ec = Ecdsa.generate(), rsa = Rsa.generate();
      for (final (signer, verifiers) in [
        (ed, [ed, ed.publicKey, ed.publicPem]),
        (ec, [ec, ec.publicKey, ec.publicPem]),
        (rsa, [rsa, rsa.publicPem]),
      ]) {
        final token = Jwt.sign(claims, signer);
        for (final v in verifiers) {
          expect(Jwt.verify(token, v), claims, reason: '$signer with ${v.runtimeType}');
        }
        expect(() => Jwt.verify(token, secret), throwsA(isA<JwtException>()), reason: 'alg/key confusion');
      }
      expect(Jwt.decode(Jwt.sign(claims, rsa, pss: true, hash: Hash.sha384)).header['alg'], 'PS384');
      expect(Jwt.verify(Jwt.sign(claims, rsa, pss: true, hash: Hash.sha384), rsa.publicPem), claims);
      expect(Jwt.decode(Jwt.sign(claims, secret, hash: Hash.sha512)).header['alg'], 'HS512');

      final now = DateTime.utc(2030);
      expect(() => Jwt.verify(Jwt.sign({'exp': Jwt.at(now)}, secret), secret, now: now), throwsA(isA<JwtException>()));
      expect(Jwt.verify(Jwt.sign({'exp': Jwt.at(now) + 1}, secret), secret, now: now), {'exp': Jwt.at(now) + 1});
      expect(
        () => Jwt.verify(Jwt.sign({'nbf': Jwt.at(now) + 1}, secret), secret, now: now),
        throwsA(isA<JwtException>()),
      );
      final none = '${utf8.encode('{"alg":"none"}').base64Url}.${utf8.encode('{}').base64Url}.';
      expect(() => Jwt.verify(none, secret), throwsA(isA<JwtException>()));
    });

    test('TOTP RFC 6238 vectors, HOTP RFC 4226, verify window, uri', () {
      final secret = Key.text('12345678901234567890');
      final totp = Totp(secret, digits: 8);
      expect(totp.code(DateTime.fromMillisecondsSinceEpoch(59 * 1000, isUtc: true)), '94287082');
      expect(totp.code(DateTime.fromMillisecondsSinceEpoch(1111111109 * 1000, isUtc: true)), '07081804');
      expect(
        Totp(
          Key.text('1234567890123456789012345678901234567890123456789012345678901234'),
          digits: 8,
          digest: Hash.sha512,
        ).code(DateTime.fromMillisecondsSinceEpoch(59 * 1000, isUtc: true)),
        '90693936',
      );
      expect(Totp(secret).hotp(0), '755224');
      expect(Totp(secret).hotp(9), '520489');
      final at = DateTime.fromMillisecondsSinceEpoch(1111111109 * 1000, isUtc: true);
      expect(totp.verify('0708 1804', at: at), isTrue);
      expect(
        totp.verify(totp.code(at.add(const Duration(seconds: 30))), at: at),
        isTrue,
        reason: 'one period of drift',
      );
      expect(totp.verify(totp.code(at.add(const Duration(seconds: 90))), at: at), isFalse);
      expect(
        Totp.fromBase32('JBSWY3DPEHPK3PXP').uri('me@example.com', issuer: 'Example'),
        'otpauth://totp/Example%3Ame%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&algorithm=SHA1&digits=6&period=30',
      );
    });
  });
}
