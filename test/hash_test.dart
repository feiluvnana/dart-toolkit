import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/hash.dart';
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
      expect('abc'.checksum(Hash.crc32), 0x352441c2);
      expect('abc'.hash(Hash.xxh3), '78af5f94892f3950'); // 64 bits, so hex rather than a wrapped int
      expect(''.hash(Hash.sha256), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });

    test('files stream through the same digest; openssl agrees', () async {
      final dir = Directory.systemTemp.createTempSync('hash_');
      try {
        final f = Path(dir.path) / 'big.bin';
        await f.writeBytes(data);
        expect(await f.hash(Hash.sha256), data.hash(Hash.sha256));
        expect(await f.hash(Hash.blake3), data.hash(Hash.blake3));
        expect(await f.checksum(Hash.crc32), data.checksum(Hash.crc32));
        expect(await f.hash(Hash.xxh3), data.hash(Hash.xxh3));
        expect((await openssl(['dgst', '-sha512', '-r', f])).split(' ').first, await f.hash(Hash.sha512));
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
      expect(Secure.uuid(), matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    });
  });

  group('random', () {
    test('token, uuid and a constant-time compare', () {
      expect(Secure.bytes().length, 32);
      expect(Secure.bytes(16).length, 16);
      expect(Secure.token().length, 43);
      expect(Secure.token(16).length, 22);
      expect(Secure.token(), isNot(Secure.token()));
      expect(Secure.uuid(), matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(Secure.equals([1, 2], [1, 2]), isTrue);
      expect(Secure.equals([1, 2], [1, 3]), isFalse);
      expect(Secure.equals([1, 2], [1, 2, 3]), isFalse);
    });
  });

  group('checksum width', () {
    test('a 64-bit checksum reads as hex rather than a wrapped negative int', () {
      expect([1, 2, 3].hash(Hash.xxh3), matches(RegExp(r'^[0-9a-f]{16}$')));
      expect('abc'.hash(Hash.xxh3), '78af5f94892f3950');
      expect(() => [1, 2, 3].checksum(Hash.xxh64), throwsArgumentError);
      expect(() => [1, 2, 3].checksum(Hash.xxh3), throwsArgumentError);
      expect([1, 2, 3].checksum(Hash.crc32), isNonNegative);
      expect([1, 2, 3].checksum(Hash.crc32c), isNonNegative);
    });

    test('hashing a missing file throws and releases the native digest', () async {
      // The context and its staging buffer are freed in a finally; the throw is what
      // used to skip that.
      for (var i = 0; i < 200; i++) {
        await expectLater(() => '/nope/absent-$i.bin'.path.hash(Hash.sha256), throwsA(isA<FileSystemException>()));
      }
    });
  });
}
