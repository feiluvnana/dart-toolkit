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
      expect(Hash.md5().add('hello').hex(), '5d41402abc4b2a76b9719d911017c592');
      expect(
        Hash.sha1().add('hello').hex(),
        'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d',
      );
      expect(
        Hash.sha256().add('hello').hex(),
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      );
      expect(Hash.sha512().add('hello').hex().length, 128);
    });

    test('add is incremental and returns the hasher', () {
      final h = Hash.sha256();
      expect(identical(h.add('hel'), h), isTrue);
      h.add('lo');
      expect(h.hex(), Hash.sha256().add('hello').hex());
    });

    test('add takes bytes too', () {
      expect(
        Hash.sha256().add(utf8.encode('hello')).hex(),
        Hash.sha256().add('hello').hex(),
      );
    });

    test('wrong data type is an ArgumentError', () {
      expect(() => Hash.sha256().add(42), throwsArgumentError);
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

    test('a failed run poisons the hasher instead of a partial hex',
        () async {
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
