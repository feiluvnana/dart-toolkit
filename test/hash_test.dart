import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/native.dart';
import 'package:dart_toolkit/path.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Published vectors and the openssl command line agree with the native library.
void main() {
  final data = List.generate(70000, (i) => (i * 31) & 0xff);

  setUpAll(() async {
    final native = await Native.check();
    expect(native.missing['native'], isNull, reason: 'dart_toolkit_native did not load: ${native.reason}');
  });

  Future<String?> openssl(List<String> args, {String? dir}) async {
    try {
      final r = await Process.run('openssl', args, workingDirectory: dir, stdoutEncoding: null);
      expect(r.exitCode, 0, reason: 'openssl ${args.join(' ')}: ${r.stderr}');
      return utf8.decode(r.stdout as List<int>).trim();
    } on ProcessException {
      return null;
    }
  }

  /// A key of these bytes, each below 0x80, so its UTF-8 is the same bytes.
  Secret keyOf(List<int> bytes) => Secret(String.fromCharCodes(bytes));

  group('typed hex', () {
    test('Hex is checked when made, decodes, and goes where hex text does', () {
      final sum = Hash.sha256.text('hello').hex;
      expect(Hash.sha256.text('hello').matches(sum.hex), isTrue);
      expect('6869'.hex.bytes, [0x68, 0x69]);
      expect(() => 'abc'.hex, throwsFormatException);
      expect(() => 'zz'.hex, throwsFormatException);
      expect(() => Hex(' '), throwsFormatException);
    });
  });

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
        expect(h.text('abc').hex, abc[h], reason: h.name);
        expect(h.text('abc').bytes.length, h.length, reason: h.name);
      }
      expect(Hash.sha256.text('').hex, 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });

    test('a digest reads as hex, raw bytes and both base64s, and compares by its bytes', () {
      final d = Hash.sha256.text('abc');
      expect('$d', d.hex);
      expect(d.bytes, d.hex.hexBytes);
      expect(d.base64, base64Encode(d.bytes));
      expect(d.base64url, base64UrlEncode(d.bytes).replaceAll('=', ''));
      expect(d.base64url, isNot(contains('=')));
      expect(d, Hash.sha256.bytes(utf8.encode('abc')));
      expect(d, isNot(Hash.sha256.text('abd')));
      expect(d, isNot(Hash.md5.text('abc')));
      expect({d, Hash.sha256.text('abc')}, hasLength(1));
      expect(d.matches(d.hex), isTrue);
      expect(d.matches(d.hex.toUpperCase()), isTrue);
      expect(d.matches(Hash.sha256.text('x').hex), isFalse);
      expect(d.matches('ab'), isFalse, reason: 'another length');
      expect(() => d.matches('not hex'), throwsFormatException);
    });

    test('files hash as their bytes do; openssl agrees', () async {
      final dir = tempDir('hash_');
      final f = await (dir / 'big.bin').writeBytes(data);
      for (final h in [Hash.sha256, Hash.blake3, Hash.crc32, Hash.xxh3]) {
        expect(await h.file(f), h.bytes(data), reason: h.name);
      }
      if (await openssl(['dgst', '-sha512', '-r', f]) case final ssl?) {
        expect(ssl.split(' ').first, (await Hash.sha512.file(f)).hex);
      }
      if (await openssl(['dgst', '-sha3-384', '-r', f]) case final ssl?) {
        expect(ssl.split(' ').first, (await Hash.sha3_384.file(f)).hex);
      }
    });

    test('hmac (RFC 4231 case 2) for SHA-2 and SHA-3, with a Secret key', () {
      expect(
        Hash.sha256.text('what do ya want for nothing?', key: const Secret('Jefe')).hex,
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      );
      expect(
        Hash.sha3_256.text('what do ya want for nothing?', key: const Secret('Jefe')).hex,
        'c7d4072e788877ae3596bbb0da73b887c9171f93095b294ae857fbe2645e1ba5',
      );
      expect(() => Hash.crc32.text('x', key: const Secret('k')), throwsArgumentError);
    });

    test('a refused key never prints', () {
      try {
        Hash.crc32.text('x', key: const Secret('hunter2'));
        fail('a checksum takes no key');
      } on ArgumentError catch (e) {
        expect('$e', isNot(contains('hunter2')));
      }
    });

    test('encodings', () {
      expect(utf8.encode('hi').hex, '6869');
      expect('6869'.hexBytes, [0x68, 0x69]);
      expect(utf8.encode('Hello!').base32, 'JBSWY3DPEE');
      expect('jbsw y3dp ee=='.base32Bytes, utf8.encode('Hello!'));
      for (final bad in ['JBSWY3DPſ', 'MZXW6ß', 'A', 'JBS']) {
        expect(() => bad.base32Bytes, throwsA(isA<FormatException>().having((e) => e.source, 'source', bad)));
      }
      expect([0xfb, 0xff, 0xbf].base64, '+/+/');
      expect([0xfb, 0xff, 0xbf].base64url, '-_-_');
      expect([0xfb, 0xff].base64url, '-_8', reason: 'unpadded');
      expect('aGk'.base64Bytes, utf8.encode('hi'));
      expect('-_-_'.base64Bytes, '+/+/'.base64Bytes);
      expect('aGVs\nbG8='.base64Bytes, utf8.encode('hello'));
      expect(utf8.decode('eyJhbGciOiJIUzI1NiJ9'.base64Bytes), '{"alg":"HS256"}');
      expect(
        () => 'a'.base64Bytes,
        throwsA(isA<FormatException>().having((e) => e.message, 'message', startsWith('Invalid base64'))),
      );
    });

    test('a value that is not a byte is refused, not encoded wrong (HSH-10)', () {
      expect(() => [300].base32, throwsArgumentError);
      expect(() => [1, -1].hex, throwsArgumentError);
      expect(() => [256].hex, throwsArgumentError);
    });

    test('a hex error says where in the text it was given (HSH-10)', () {
      expect(
        () => 'ab cd zz'.hexBytes,
        throwsA(
          isA<FormatException>()
              .having((e) => e.offset, 'offset', 6)
              .having((e) => e.message, 'message', startsWith('Invalid hex')),
        ),
      );
      expect(' ab\ncd '.hexBytes, [0xab, 0xcd]);
      expect(() => 'abc'.hexBytes, throwsFormatException);
    });

    test('hmac on BLAKE2 and BLAKE3 is their own keyed mode, matching the published vectors', () {
      // BLAKE2's KAT (key 00..3f, empty input), checked against Python's hashlib; BLAKE3's
      // test_vectors.json, key "whats the Elvish word for friend".
      expect(
        Hash.blake2b.bytes([], key: keyOf(List.generate(64, (i) => i))).hex,
        '10ebb67700b1868efb4417987acf4690ae9d972fb7a590c2f02871799aaa4786'
        'b5e996e8f0f4eb981fc214b005f42d2ff4233499391653df7aefcbc13fc51568',
      );
      expect(
        Hash.blake2s.bytes([], key: keyOf(List.generate(32, (i) => i))).hex,
        '48a8997da407876b3d79c0d92325ad3b89cbb754d86ab71aee047ad345fd2c49',
      );
      expect(
        Hash.blake3.text('', key: const Secret('whats the Elvish word for friend')).hex,
        '92b2b75604ed3c761f9d6f62392c8a9227ad0ea3f09573e783f1498a4ed60d26',
      );
      expect(() => Hash.blake3.text('', key: const Secret('short')), throwsArgumentError);
      expect(() => Hash.blake2s.text('', key: Secret('x' * 33)), throwsArgumentError);
    });

    test('hexBytes refuses what is not hex, a sign included', () {
      expect('00FFab'.hexBytes, [0, 255, 0xab]);
      expect(() => '-1'.hexBytes, throwsFormatException);
      expect(() => '+1'.hexBytes, throwsFormatException);
      expect(() => 'zz'.hexBytes, throwsFormatException);
    });
  });

  test(
    'a FIFO is hashed off this isolate, so a writer on it is not blocked',
    () async {
      final dir = tempDir('tk_fifo');
      final fifo = '$dir/pipe';
      expect(Process.runSync('mkfifo', [fifo]).exitCode, 0);
      final digest = Hash.sha256.file(fifo);
      final sink = File(fifo).openWrite();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      sink.write('hi');
      await sink.close();
      expect(await digest, Hash.sha256.text('hi'));
    },
    testOn: 'mac-os || linux',
    timeout: const Timeout(Duration(seconds: 10)),
  );

  group('stream', () {
    test('a stream hashes as its bytes do, in any chunking, keyed or not', () async {
      final data = List.generate(200000, (i) => i * 7 % 256);
      Stream<List<int>> chunked(int n) => Stream.fromIterable([
        for (var i = 0; i < data.length; i += n) data.sublist(i, i + n > data.length ? data.length : i + n),
      ]);
      for (final h in Hash.values) {
        expect(await h.stream(chunked(70000)), h.bytes(data), reason: h.name);
        expect(await h.stream(chunked(1)), h.bytes(data), reason: '${h.name}, a byte at a time');
      }
      expect(await Hash.sha256.stream(const Stream.empty()), Hash.sha256.bytes([]));
      const key = Secret('secret');
      expect(await Hash.sha256.stream(chunked(4096), key: key), Hash.sha256.bytes(data, key: key));
    });

    test('a chunk bigger than the buffer is fed in slices, not by growing it (HSH-5)', () async {
      final big = List.generate(1 << 20, (i) => i % 251);
      expect(await Hash.sha256.stream(Stream.value(big)), Hash.sha256.bytes(big));
    });

    test('a failing source fails the hash, and the file streams like its path', () async {
      Stream<List<int>> broken() async* {
        yield [1];
        throw StateError('cut');
      }

      await expectLater(Hash.sha256.stream(broken()), throwsStateError);
      final dir = tempDir('tk_hs');
      final f = await Path('$dir/f.bin').writeBytes(List.generate(1 << 20, (i) => i % 256));
      expect(await Hash.blake3.stream(f.chunks()), await Hash.blake3.file(f));
    });

    test('a stream reports its bytes and stops on a cancel (HSH-3)', () async {
      final source = StreamController<List<int>>();
      final task = Hash.sha256.stream(source.stream);
      source.add(List.filled(1000, 1));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(task.status, isA<Running<Object?, Digest>>().having((r) => r.received, 'received', 1000));
      task.cancel('enough');
      await expectLater(task, throwsA(isA<CancelledException>()));
      expect(await task.settled, isA<Stopped<Object?, Digest>>());
      await source.close();
    });
  });

  group('random', () {
    test('token and uuid', () {
      expect(Secure.bytes().length, 32);
      expect(Secure.bytes(16).length, 16);
      expect(Secure.token().length, 43);
      expect(Secure.token(16).length, 22);
      expect(Secure.token(), isNot(Secure.token()));
      expect(Secure.uuid(), matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    });

    test('Secure.bytes of any length', () {
      for (final n in [0, 1, 5, 32, 1001]) {
        expect(Secure.bytes(n).length, n);
      }
    });
  });

  group('checksum width', () {
    test('a 64-bit checksum reads as hex rather than a wrapped negative int', () {
      expect(Hash.xxh3.bytes([1, 2, 3]).hex, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(Hash.crc32.bytes([1, 2, 3]).hex, matches(RegExp(r'^[0-9a-f]{8}$')));
    });

    test('hashing a missing file is a PathNotFoundException naming it, and releases the native digest', () async {
      for (var i = 0; i < 200; i++) {
        await expectLater(
          Hash.sha256.file('/nope/absent-$i.bin'),
          throwsA(isA<PathNotFoundException>().having((e) => e.path, 'path', '/nope/absent-$i.bin')),
        );
      }
    });

    test('a folder is no file to hash: the OS says so, once, by path (HSH-2, NAT-7)', () async {
      final dir = tempDir('tk_hd');
      await expectLater(
        Hash.sha256.file(dir),
        throwsA(
          isA<FileSystemException>()
              .having((e) => e, 'type', isNot(isA<FormatException>()))
              .having((e) => e.path, 'path', '$dir')
              .having((e) => e.osError?.message, 'os text', isNot('No such file or directory')),
        ),
      );
    }, testOn: 'mac-os || linux');
  });

  group('files', () {
    late Path dir;
    setUp(() => dir = tempDir('hash_'));

    test('a file truncated while BLAKE3 reads it fails or hashes what it read, never ends the process', () async {
      final f = File(dir / 'sparse.bin');
      (f.openSync(mode: FileMode.write)..truncateSync(4 << 30)).closeSync();
      final task = Hash.blake3.file(f.path).settled;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      (f.openSync(mode: FileMode.append)..truncateSync(0)).closeSync();
      expect(await task, anyOf(isA<Done<Object?, Digest>>(), isA<Failed<Object?, Digest>>()));
    }, testOn: '!windows');

    test('a file larger than the inline limit hashes and MACs as its bytes do, reporting its bytes', () async {
      final bytes = Uint8List.fromList(List.generate(40 << 20, (i) => (i * 7) & 0xff));
      final big = await (dir / 'big.bin').writeBytes(bytes);
      for (final h in [Hash.sha256, Hash.blake3, Hash.xxh3, Hash.crc32]) {
        final task = h.file(big);
        final seen = <Running<Object?, Digest>>[];
        task.statuses.listen((s) => s is Running<Object?, Digest> && s.unit == Unit.bytes ? seen.add(s) : null);
        expect(await task, h.bytes(bytes), reason: h.name);
        expect(seen.map((r) => r.total).toSet(), {bytes.length}, reason: '${h.name} reports its size');
        expect(task.label, endsWith('big.bin'));
      }
      const k = Secret('key');
      expect(await Hash.sha256.file(big, key: k), Hash.sha256.bytes(bytes, key: k));
      expect(await Hash.blake2b.file(big, key: k), Hash.blake2b.bytes(bytes, key: k));
      final k32 = Secret('k' * 32);
      expect(await Hash.blake3.file(big, key: k32), Hash.blake3.bytes(bytes, key: k32));
      if (await openssl(['dgst', '-sha256', '-hmac', 'key', '-r', big]) case final ssl?) {
        expect(ssl.split(' ').first, (await Hash.sha256.file(big, key: k)).hex);
      }
    });

    test('bytes past the slice size hash and MAC as the file of them does, in slices', () async {
      final bytes = Uint8List.fromList(List.generate((3 << 20) + 17, (i) => (i * 13) & 0xff));
      final f = await (dir / 'three.bin').writeBytes(bytes);
      for (final h in Hash.values) {
        expect(h.bytes(bytes), await h.file(f), reason: h.name);
      }
      const k = Secret('key');
      expect(Hash.sha256.bytes(bytes, key: k), await Hash.sha256.file(f, key: k));
    });

    test('a large file stops part way on a cancel, without killing its worker (HSH-3)', () async {
      final big = await (dir / 'big.bin').writeBytes(Uint8List(256 << 20));
      final task = Hash.sha512.file(big);
      await task.statuses.firstWhere((s) => s is Running<Object?, Digest> && s.received > 0);
      task.cancel('stop');
      await expectLater(task, throwsA(isA<CancelledException>()));
      // The library is still usable: the worker returned instead of dying mid-call.
      expect(await Hash.sha256.file(big.parent / 'none.bin').settled, isA<Failed<Object?, Digest>>());
    });

    test('many files are a batch: a missing one fails its own item (HSH-4)', () async {
      final paths = [for (var i = 0; i < 20; i++) dir / 'f$i.txt'];
      for (final (i, f) in paths.indexed) {
        await f.writeText('file $i' * i);
      }
      final all = await paths.parallelize((f) => Hash.sha256.file(f)).toMap();
      expect(all.keys, paths);
      for (final f in paths) {
        expect(all[f], await Hash.sha256.file(f));
      }
      final settled = await [...paths, dir / 'absent'].parallelize((f) => Hash.xxh3.file(f)).settled;
      expect(settled.whereType<Failed<Path, Digest>>().map((f) => f.item), [dir / 'absent']);
      expect(settled.whereType<Done<Path, Digest>>(), hasLength(paths.length));
    });

    test('duplicates groups equal files, biggest first, and ignores equal sizes that differ', () async {
      await (dir / 'a' / 'one.bin').writeBytes(List.filled(1000, 1));
      await (dir / 'b' / 'two.bin').writeBytes(List.filled(1000, 1));
      await (dir / 'c.bin').writeBytes(List.filled(1000, 2)); // same size, other bytes
      await (dir / 'x.txt').writeText('xy');
      await (dir / 'y.txt').writeText('xy');
      await (dir / 'empty1').writeText('');
      await (dir / 'empty2').writeText('');
      final groups = await dir.duplicates();
      expect(groups.map((g) => g.map((e) => e.name).toList()).toList(), [
        ['one.bin', 'two.bin'],
        ['x.txt', 'y.txt'],
      ]);
      await expectLater(
        dir.duplicates().then((_) => (dir / 'gone').duplicates()),
        throwsA(isA<PathNotFoundException>()),
      );
    });

    test('duplicates leaves out a file it cannot read instead of failing', () async {
      await (dir / 'a.txt').writeText('same');
      await (dir / 'b.txt').writeText('same');
      final locked = await (dir / 'c.txt').writeText('else');
      await locked.chmod('000');
      addTearDown(() => locked.chmod('644'));
      final groups = await dir.duplicates();
      expect(groups.map((g) => g.map((e) => e.name).toList()).toList(), [
        ['a.txt', 'b.txt'],
      ]);
    }, testOn: '!windows');
  });
}
