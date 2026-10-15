import 'dart:convert';
import 'dart:io' hide File;

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:test/test.dart';

void main() {
  group('Hash', () {
    test('md5 makes a Hasher', () {
      expect(Hash.md5(), isA<Hasher>());
    });

    test('sha1 makes a Hasher', () {
      expect(Hash.sha1(), isA<Hasher>());
    });

    test('sha256 makes a Hasher', () {
      expect(Hash.sha256(), isA<Hasher>());
    });

    test('sha512 makes a Hasher', () {
      expect(Hash.sha512(), isA<Hasher>());
    });
  });

  group('expect and of', () {
    const abc = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('hash_expect'));
    tearDown(() => tmp.delete(recursive: true));

    test('of() digests a reader', () async {
      expect(await Hash.sha256().of(Reader.of(utf8.encode('abc'))), abc);
    });

    test('a matching expect: passes through; a mismatch never lands', () async {
      final ok = Fs.file('${tmp.path}/ok');
      await (Reader.of(utf8.encode('abc')) | Hash.sha256(expect: abc.toUpperCase()) > ok);
      expect(await ok.text(), 'abc');
      final bad = Fs.file('${tmp.path}/bad');
      await expectLater(
        Reader.of(utf8.encode('abd')) | Hash.sha256(expect: abc) > bad,
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('sha256 mismatch'))),
      );
      expect(await bad.exists(), isFalse);
      await expectLater(Reader.of(utf8.encode('abd')) > Hash.sha256(expect: abc), throwsFormatException);
    });

    test('a mismatched archive is never unarchived', () async {
      final src = Fs.dir('${tmp.path}/src');
      await src.file('a.txt').write('a');
      final tgz = await Archive.archive(['.'], dir: src.path(), format: ArchiveFormat.tgz).bytes();
      await expectLater(
        Reader.of(tgz) | Hash.sha256(expect: abc) > Archive.unarchive('${tmp.path}/out'),
        throwsFormatException,
      );
      expect(await Fs.entry('${tmp.path}/out'), isNull);
    });
  });

  group('Hasher', () {
    test('one-shot matches known digests', () {
      expect(Hash.md5().add('hello').hex(), '5d41402abc4b2a76b9719d911017c592');
      expect(Hash.sha1().add('hello').hex(), 'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d');
      expect(Hash.sha256().add('hello').hex(), '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824');
      expect(Hash.sha512().add('hello').hex().length, 128);
    });

    test('add is incremental and returns the hasher', () {
      final h = Hash.sha256();
      expect(identical(h.add('hel'), h), isTrue);
      h.add('lo');
      expect(h.hex(), Hash.sha256().add('hello').hex());
    });

    test('addBytes feeds raw bytes identically to utf8 text', () {
      expect(Hash.sha256().addBytes(utf8.encode('hello')).hex(), Hash.sha256().add('hello').hex());
    });

    test('add and addBytes chain incrementally', () {
      final h = Hash.sha256().add('hel').addBytes(utf8.encode('lo'));
      expect(h.hex(), Hash.sha256().add('hello').hex());
    });

    test('hex() again returns the same digest', () {
      final h = Hash.sha256().add('x');
      expect(h.hex(), h.hex());
    });

    test('add after hex is a StateError', () {
      final h = Hash.sha256().add('x');
      h.hex();
      expect(() => h.add('y'), throwsStateError);
    });

    test('as a Writer it digests the stream', () async {
      final h = Hash.sha256();
      await (_Mem('hello') > h);
      expect(h.hex(), Hash.sha256().add('hello').hex());
    });

    test('as a Pipe it forwards unchanged and digests', () async {
      final h = Hash.sha256();
      final out = await (_Mem('hello') | h).bytes();
      expect(out, utf8.encode('hello'));
      expect(h.hex(), Hash.sha256().add('hello').hex());
    });

    test('a failed run poisons the hasher instead of a partial hex', () async {
      final h = Hash.sha256();
      await expectLater(_Boom() | h > null, throwsStateError);
      expect(() => h.hex(), throwsStateError);
      expect(() => h.add('more'), throwsStateError);
      expect(_Boom() | h > null, throwsStateError);
    });

    test('a finished hasher cannot take another pipeline', () async {
      final h = Hash.sha256().add('x');
      h.hex();
      // Pipelines are lazy: the StateError surfaces when the run starts.
      expect(_Mem('y') > h, throwsStateError);
      expect(_Mem('y').pipe(h).bytes(), throwsStateError);
    });

    test('F6: a writer that fails before reading poisons the pipe hasher too', () async {
      final h = Hash.sha256();
      await expectLater(_Mem('hello') | h > _ThrowBeforeRead(), throwsA(isA<ArgumentError>()));
      // Not the empty-input digest: the run never delivered the bytes.
      expect(() => h.hex(), throwsStateError);
    });
  });
}

final class _Mem with Reader {
  _Mem(this._text);
  final String _text;
  @override
  Stream<List<int>> stream() => Stream.value(utf8.encode(_text));
}

final class _Boom with Reader {
  @override
  Stream<List<int>> stream() async* {
    yield utf8.encode('part');
    throw StateError('reader blew up mid-write');
  }
}

/// Fails before ever listening to the input stream (a missing parent, an
/// unwritable target): the pipe must still poison its stages.
final class _ThrowBeforeRead with Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async {
    throw ArgumentError('cannot open target');
  }
}
