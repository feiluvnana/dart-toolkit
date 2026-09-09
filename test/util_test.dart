import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('zip', () {
    late Directory work;

    setUp(() => work = io.temp('dt_zip_'));
    tearDown(() => work.deleteSync(recursive: true));

    String at(String name) => io.join(work.path, name);

    test('packs a folder and unpacks it back', () async {
      io.write(at('site/index.html'), '<h1>Home</h1>');
      io.write(at('site/css/app.css'), 'body{}');

      await zip.pack(at('site'), at('site.zip'));
      expect(io.has(at('site.zip')), isTrue);

      final files = await zip.unpack(at('site.zip'), at('out'));
      expect(files, hasLength(2));
      expect(io.read(at('out/index.html')), equals('<h1>Home</h1>'));
      expect(io.read(at('out/css/app.css')), equals('body{}'));
    });

    test('lists and reads entries without unpacking', () async {
      io.write(at('src/a.txt'), 'alpha');
      io.write(at('src/b.txt'), 'beta');
      await zip.pack(at('src'), at('src.zip'));

      final names =
          (await zip.list(
              at('src.zip'),
            )).where((e) => !e.folder).map((e) => e.name).toList()
            ..sort();
      expect(names, equals(['a.txt', 'b.txt']));

      final bytes = await zip.read(at('src.zip'), 'b.txt');
      expect(utf8.decode(bytes!), equals('beta'));
      expect(await zip.read(at('src.zip'), 'missing.txt'), isNull);
    });

    test('bundles in-memory data', () async {
      await zip.bundle(at('mem.zip'), {
        'notes.txt': utf8.encode('from memory'),
      });
      final bytes = await zip.read(at('mem.zip'), 'notes.txt');
      expect(utf8.decode(bytes!), equals('from memory'));
    });

    test('round-trips through tar and tar.gz', () async {
      io.write(at('d/one.txt'), 'one');
      for (final name in ['d.tar', 'd.tar.gz', 'd.tgz']) {
        await zip.pack(at('d'), at(name));
        final out = at('un_${util.text.slug(name)}');
        await zip.unpack(at(name), out);
        expect(io.read(io.join(out, 'one.txt')), equals('one'), reason: name);
      }
    });

    test('Format is taken from the file name', () {
      expect(Format.of('a.zip'), equals(Format.zip));
      expect(Format.of('a.tar'), equals(Format.tar));
      expect(Format.of('a.tar.gz'), equals(Format.gz));
      expect(Format.of('a.tgz'), equals(Format.gz));
      expect(Format.of('a.tar.bz2'), equals(Format.bz2));
      expect(Format.of('nameless'), equals(Format.zip));
    });

    test('an entry that escapes the destination is skipped', () async {
      await zip.bundle(at('evil.zip'), {
        '../escaped.txt': utf8.encode('nope'),
        'safe.txt': utf8.encode('yes'),
      });
      final written = await zip.unpack(at('evil.zip'), at('dest'));
      expect(written, hasLength(1));
      expect(io.has(at('escaped.txt')), isFalse);
      expect(io.read(at('dest/safe.txt')), equals('yes'));
    });

    test('deflate and inflate round-trip', () {
      final raw = utf8.encode('compress me' * 50);
      final packed = zip.deflate(raw);
      expect(packed.length, lessThan(raw.length));
      expect(zip.inflate(packed), equals(raw));
    });
  });

  group('util.text', () {
    test('slug', () {
      expect(util.text.slug('Hello, World!'), equals('hello-world'));
      expect(util.text.slug('  Café  Déjà Vu '), equals('cafe-deja-vu'));
      expect(util.text.slug('a/b', separator: '_'), equals('a_b'));
    });

    test('clean and strip', () {
      expect(util.text.clean('  a   b\n c '), equals('a b c'));
      expect(util.text.strip('<p>Hi <b>there</b></p>'), equals('Hi there'));
      expect(util.text.clean('a​b'), equals('ab'));
    });

    test('clip', () {
      expect(util.text.clip('short', 20), equals('short'));
      expect(util.text.clip('a long sentence here', 10), equals('a long se…'));
      expect(util.text.clip('anything', 0), equals(''));
    });

    test('number and numbers', () {
      expect(util.text.number(r'$1,234.50'), equals(1234.5));
      expect(util.text.number('no digits'), isNull);
      expect(util.text.number('-42 items'), equals(-42));
      expect(util.text.numbers('3 of 7 at 2.5'), equals([3, 7, 2.5]));
    });

    test('title, upper, words, blank', () {
      expect(util.text.title('hELLO there'), equals('Hello There'));
      expect(util.text.upper('hello'), equals('Hello'));
      expect(util.text.words('one two-three'), equals(['one', 'two', 'three']));
      expect(util.text.blank('   \n '), isTrue);
      expect(util.text.blank(' x '), isFalse);
    });

    test('between and betweens', () {
      const body = 'a "id":"one" b "id":"two" c';
      expect(util.text.between(body, '"id":"', '"'), equals('one'));
      expect(util.text.betweens(body, '"id":"', '"'), equals(['one', 'two']));
      expect(util.text.between(body, 'missing', '"'), isNull);
    });
  });

  group('util.hash', () {
    test('sha, md5 and short', () {
      expect(util.hash.sha('abc').length, equals(64));
      expect(util.hash.md5('abc').length, equals(32));
      expect(
        util.hash.short('abc'),
        equals(util.hash.sha('abc').substring(0, 8)),
      );
      expect(util.hash.sha('abc'), equals(util.hash.sha(utf8.encode('abc'))));
    });

    test('sign is stable and key-dependent', () {
      expect(
        util.hash.sign('body', 'k1'),
        equals(util.hash.sign('body', 'k1')),
      );
      expect(util.hash.sign('body', 'k1'), isNot(util.hash.sign('body', 'k2')));
    });

    test('base64 round-trips', () {
      final encoded = util.hash.encode('hello');
      expect(utf8.decode(util.hash.decode(encoded)), equals('hello'));
    });
  });

  group('util.rand', () {
    test('pick, some and shuffle stay inside the pool', () {
      final pool = List.generate(10, (i) => i);
      expect(pool, contains(util.rand.pick(pool)));
      final three = util.rand.some(pool, 3);
      expect(three, hasLength(3));
      expect(three.toSet(), hasLength(3));
      expect(util.rand.some(pool, 99), hasLength(10));
      final shuffled = util.rand.shuffle(pool);
      expect(shuffled..sort(), equals(pool));
      expect(() => util.rand.pick(<int>[]), throwsStateError);
    });

    test('between, id, jitter and chance stay in range', () {
      for (var i = 0; i < 50; i++) {
        final n = util.rand.between(5, 10);
        expect(n, allOf(greaterThanOrEqualTo(5), lessThan(10)));
      }
      expect(util.rand.between(3, 3), equals(3));
      expect(util.rand.id(16), hasLength(16));
      expect(util.rand.id(), isNot(equals(util.rand.id())));

      final jittered = util.rand.jitter(const Duration(seconds: 2));
      expect(jittered, greaterThanOrEqualTo(const Duration(seconds: 2)));
      expect(jittered, lessThanOrEqualTo(const Duration(milliseconds: 2500)));

      expect(util.rand.chance(1), isTrue);
      expect(util.rand.chance(0), isFalse);
    });
  });
}
