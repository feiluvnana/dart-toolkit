import 'dart:convert';

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

  group('Hasher', () {
    test('one-shot matches known digests', () {
      expect(Hash.md5().add('hello').hexDigest(), '5d41402abc4b2a76b9719d911017c592');
      expect(
        Hash.sha1().add('hello').hexDigest(),
        'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d',
      );
      expect(
        Hash.sha256().add('hello').hexDigest(),
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      );
      expect(Hash.sha512().add('hello').hexDigest().length, 128);
    });

    test('add is incremental and returns the hasher', () {
      final h = Hash.sha256();
      expect(identical(h.add('hel'), h), isTrue);
      h.add('lo');
      expect(h.hexDigest(), Hash.sha256().add('hello').hexDigest());
    });

    test('addBytes feeds raw bytes identically to utf8 text', () {
      expect(
        Hash.sha256().addBytes(utf8.encode('hello')).hexDigest(),
        Hash.sha256().add('hello').hexDigest(),
      );
    });

    test('add and addBytes chain incrementally', () {
      final h = Hash.sha256().add('hel').addBytes(utf8.encode('lo'));
      expect(h.hexDigest(), Hash.sha256().add('hello').hexDigest());
    });

    test('hexDigest() again returns the same digest', () {
      final h = Hash.sha256().add('x');
      expect(h.hexDigest(), h.hexDigest());
    });

    test('add after hexDigest is a StateError', () {
      final h = Hash.sha256().add('x');
      h.hexDigest();
      expect(() => h.add('y'), throwsStateError);
    });

    test('as a Writer it digests the stream', () async {
      final h = Hash.sha256();
      await (_Mem('hello') > h);
      expect(h.hexDigest(), Hash.sha256().add('hello').hexDigest());
    });

    test('as a Pipe it forwards unchanged and digests', () async {
      final h = Hash.sha256();
      final out = await (_Mem('hello') | h).bytes();
      expect(out, utf8.encode('hello'));
      expect(h.hexDigest(), Hash.sha256().add('hello').hexDigest());
    });

    test('a failed run poisons the hasher instead of a partial hex',
        () async {
      final h = Hash.sha256();
      await expectLater(_Boom() | h > null, throwsStateError);
      expect(() => h.hexDigest(), throwsStateError);
      expect(() => h.add('more'), throwsStateError);
      expect(_Boom() | h > null, throwsStateError);
    });

    test('a finished hasher cannot take another pipeline', () async {
      final h = Hash.sha256().add('x');
      h.hexDigest();
      // Pipelines are lazy: the StateError surfaces when the run starts.
      expect(_Mem('y') > h, throwsStateError);
      expect(_Mem('y').pipe(h).bytes(), throwsStateError);
    });

    test(
        'F6: a writer that fails before reading poisons the pipe hasher too',
        () async {
      final h = Hash.sha256();
      await expectLater(
        _Mem('hello') | h > _ThrowBeforeRead(),
        throwsA(isA<ArgumentError>()),
      );
      // Not the empty-input digest: the run never delivered the bytes.
      expect(() => h.hexDigest(), throwsStateError);
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
final class _ThrowBeforeRead implements Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async {
    throw ArgumentError('cannot open target');
  }
}
