import 'dart:convert';
import 'dart:io' hide File;

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/utils.dart';

import 'support/io.dart';
import 'package:test/test.dart';

void main() {
  group('digest forms and HMAC', () {
    test('base64() and bytes() finish like hex()', () {
      final h = HashUtils.sha256().add('abc');
      expect(base64Encode(h.bytes()), 'ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=');
      expect(h.hex(), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(h.bytes(), hasLength(32));
      expect(h.bytes().first, 0xba);
      expect(() => h.add('x'), throwsStateError);
    });

    test('key: makes an HMAC (RFC 4231 and RFC 2202 vectors)', () async {
      const msg = 'what do ya want for nothing?';
      final key = utf8.encode('Jefe');
      expect(HashUtils.sha256(key: key).add(msg).hex(), '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843');
      expect(HashUtils.md5(key: key).add(msg).hex(), '750c783e6ab0b503eaa86e310a5db738');
      final hmac = HashUtils.sha256(key: key);
      await (Reader.of(utf8.encode(msg)) > hmac);
      expect(hmac.hex(), startsWith('5bdcc146'));
      // a digest keys the next step of a signing chain
      final step = HashUtils.sha256(key: HashUtils.sha256(key: key).add('a').bytes()).add('b').hex();
      expect(step, hasLength(64));
      await expectLater(
        Reader.of(utf8.encode(msg)) > HashUtils.sha256(key: key, expect: '0' * 64),
        throwsA(isA<ContentException>().having((e) => e.message, 'message', startsWith('hmac-sha256 mismatch'))),
      );
    });
  });

  group('Hash', () {
    test('md5 makes a Hasher', () {
      expect(HashUtils.md5(), isA<Hasher>());
    });

    test('sha1 makes a Hasher', () {
      expect(HashUtils.sha1(), isA<Hasher>());
    });

    test('sha256 makes a Hasher', () {
      expect(HashUtils.sha256(), isA<Hasher>());
    });

    test('sha512 makes a Hasher', () {
      expect(HashUtils.sha512(), isA<Hasher>());
    });
  });

  group('expect and of', () {
    const abc = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('hash_expect'));
    tearDown(() => tmp.delete(recursive: true));

    test('of() digests a reader', () async {
      final read = HashUtils.sha256();
      await (Reader.of(utf8.encode('abc')) > read);
      expect(read.hex(), abc);
    });

    test('a matching expect: passes through; a mismatch never lands', () async {
      final ok = Fs.file('${tmp.path}/ok');
      await (Reader.of(utf8.encode('abc')) | HashUtils.sha256(expect: abc.toUpperCase()) > ok);
      expect(await ok.text(), 'abc');
      final bad = Fs.file('${tmp.path}/bad');
      await expectLater(
        Reader.of(utf8.encode('abd')) | HashUtils.sha256(expect: abc) > bad,
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('sha256 mismatch'))),
      );
      expect(await bad.exists(), isFalse);
      await expectLater(Reader.of(utf8.encode('abd')) > HashUtils.sha256(expect: abc), throwsFormatException);
    });

    test('a mismatched archive is never unarchived', () async {
      final src = Fs.dir('${tmp.path}/src');
      await src.file('a.txt').write('a');
      final tgz = await Archive.archive(['.'], dir: src.path, format: ArchiveFormat.tgz).bytes();
      await expectLater(
        Reader.of(tgz) | HashUtils.sha256(expect: abc) > Archive.unarchive('${tmp.path}/out'),
        throwsFormatException,
      );
      expect(await Fs.entry('${tmp.path}/out'), isNull);
    });
  });

  group('Hasher', () {
    test('one-shot matches known digests', () {
      expect(HashUtils.md5().add('hello').hex(), '5d41402abc4b2a76b9719d911017c592');
      expect(HashUtils.sha1().add('hello').hex(), 'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d');
      expect(HashUtils.sha256().add('hello').hex(), '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824');
      expect(HashUtils.sha512().add('hello').hex().length, 128);
    });

    test('add is incremental and returns the hasher', () {
      final h = HashUtils.sha256();
      expect(identical(h.add('hel'), h), isTrue);
      h.add('lo');
      expect(h.hex(), HashUtils.sha256().add('hello').hex());
    });

    test('addBytes feeds raw bytes identically to utf8 text', () {
      expect(HashUtils.sha256().addBytes(utf8.encode('hello')).hex(), HashUtils.sha256().add('hello').hex());
    });

    test('add and addBytes chain incrementally', () {
      final h = HashUtils.sha256().add('hel').addBytes(utf8.encode('lo'));
      expect(h.hex(), HashUtils.sha256().add('hello').hex());
    });

    test('hex() again returns the same digest', () {
      final h = HashUtils.sha256().add('x');
      expect(h.hex(), h.hex());
    });

    test('add after hex is a StateError', () {
      final h = HashUtils.sha256().add('x');
      h.hex();
      expect(() => h.add('y'), throwsStateError);
    });

    test('as a Writer it digests the stream', () async {
      final h = HashUtils.sha256();
      await (Mem('hello') > h);
      expect(h.hex(), HashUtils.sha256().add('hello').hex());
    });

    test('as a Pipe it forwards unchanged and digests', () async {
      final h = HashUtils.sha256();
      final out = await (Mem('hello') | h).bytes();
      expect(out, utf8.encode('hello'));
      expect(h.hex(), HashUtils.sha256().add('hello').hex());
    });

    test('a failed run poisons the hasher instead of a partial hex', () async {
      final h = HashUtils.sha256();
      await expectLater(BoomReader() | h > null, throwsStateError);
      expect(() => h.hex(), throwsStateError);
      expect(() => h.add('more'), throwsStateError);
      expect(BoomReader() | h > null, throwsStateError);
    });

    test('a finished hasher cannot take another pipeline', () async {
      final h = HashUtils.sha256().add('x');
      h.hex();
      // Pipelines are lazy: the StateError surfaces when the run starts.
      expect(Mem('y') > h, throwsStateError);
      expect((Mem('y') | h).bytes(), throwsStateError);
    });

    test('F6: a writer that fails before reading poisons the pipe hasher too', () async {
      final h = HashUtils.sha256();
      await expectLater(Mem('hello') | h > _ThrowBeforeRead(), throwsA(isA<ArgumentError>()));
      // Not the empty-input digest: the run never delivered the bytes.
      expect(() => h.hex(), throwsStateError);
    });
  });
}

/// Fails before ever listening to the input stream (a missing parent, an
/// unwritable target): the pipe must still poison its stages.
final class _ThrowBeforeRead with Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async {
    throw ArgumentError('cannot open target');
  }
}
