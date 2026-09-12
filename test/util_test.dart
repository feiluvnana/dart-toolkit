import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('zip', () {
    late Directory work;

    setUp(() => work = Directory.systemTemp.createTempSync('dt_zip_'));
    tearDown(() => work.deleteSync(recursive: true));

    String at(String name) => p.join(work.path, name);

    void writeFile(String path, String content) {
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    test('packs a folder and unpacks it back', () async {
      writeFile(at('site/index.html'), '<h1>Home</h1>');
      writeFile(at('site/css/app.css'), 'body{}');

      await Formats.zip(at('site'), at('site.zip'));
      expect(File(at('site.zip')).existsSync(), isTrue);

      final files = await Formats.unzip(at('site.zip'), at('out'));
      expect(files.length, equals(2));
      expect(File(at('out/index.html')).readAsStringSync(), equals('<h1>Home</h1>'));
      expect(File(at('out/css/app.css')).readAsStringSync(), equals('body{}'));
    });

    test('lists and reads entries without unpacking', () async {
      writeFile(at('src/a.txt'), 'alpha');
      writeFile(at('src/b.txt'), 'beta');
      await Formats.zip(at('src'), at('src.zip'));

      final names = (await const ZipAccessor().list(at('src.zip')))
          .where((e) => !e.folder)
          .map((e) => e.name)
          .toList()
        ..sort();
      expect(names, equals(['a.txt', 'b.txt']));

      final bytes = await const ZipAccessor().extract(at('src.zip'), 'b.txt');
      expect(utf8.decode(bytes!), equals('beta'));
      expect(await const ZipAccessor().extract(at('src.zip'), 'missing.txt'), isNull);
    });

    test('bundles in-memory data', () async {
      await const ZipAccessor().bundle(at('mem.zip'), {
        'notes.txt': utf8.encode('from memory'),
      });
      final bytes = await const ZipAccessor().extract(at('mem.zip'), 'notes.txt');
      expect(utf8.decode(bytes!), equals('from memory'));
    });

    test('round-trips through tar and tar.gz', () async {
      writeFile(at('d/one.txt'), 'one');
      for (final name in ['d.tar', 'd.tar.gz', 'd.tgz']) {
        await Formats.zip(at('d'), at(name));
        final out = at('un_${Text.slug(name)}');
        await Formats.unzip(at(name), out);
        expect(
          File(p.join(out, 'one.txt')).readAsStringSync(),
          equals('one'),
          reason: name,
        );
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
      await const ZipAccessor().bundle(at('evil.zip'), {
        '../escaped.txt': utf8.encode('nope'),
        'safe.txt': utf8.encode('yes'),
      });
      final written = await Formats.unzip(at('evil.zip'), at('dest'));
      expect(written.length, equals(1));
      expect(File(at('escaped.txt')).existsSync(), isFalse);
      expect(File(at('dest/safe.txt')).readAsStringSync(), equals('yes'));
    });

    test('an archive that is not there is empty, not a throw', () async {
      final missing = at('absent.zip');
      expect((await const ZipAccessor().list(missing)).length, equals(0));
      expect(await const ZipAccessor().extract(missing, 'a.txt'), isNull);
      expect((await Formats.unzip(missing, at('nowhere'))).length, 0);
    });

    test('an extension no format covers is refused', () async {
      writeFile(at('one/a.txt'), 'x');
      expect(() => Format.of('site.rar'), throwsArgumentError);
      expect(
        () => Formats.zip(at('one'), at('one.rar')),
        throwsArgumentError,
      );
      // A name with no extension has nothing to disagree with.
      expect(Format.of('archive'), equals(Format.zip));
      // And an explicit format still overrides the name.
      await Formats.zip(at('one'), at('one.rar'), format: Format.zip);
      expect(File(at('one.rar')).existsSync(), isTrue);
    });

    test('deflate and inflate round-trip', () {
      final raw = utf8.encode('compress me' * 50);
      final packed = const ZipAccessor().deflate(raw);
      expect(packed.length, lessThan(raw.length));
      expect(const ZipAccessor().inflate(packed), equals(raw));
    });
  });

  group('Text', () {
    test('slug', () {
      expect(Text.slug('Hello, World!'), equals('hello-world'));
      expect(Text.slug('  Café  Déjà Vu '), equals('cafe-deja-vu'));
      expect(Text.slug('a/b', separator: '_'), equals('a_b'));
    });

    test('clean and strip', () {
      expect(Text.clean('  a   b\n c '), equals('a b c'));
      expect(Text.tags('<p>Hi <b>there</b></p>'), equals('Hi there'));
      expect(Text.clean('a​b'), equals('ab'));
    });

    test('clip', () {
      expect(Text.clip('short', 20), equals('short'));
      expect(Text.clip('a long sentence here', 10), equals('a long se…'));
      expect(Text.clip('anything', 0), equals(''));
    });

    test('number and numbers', () {
      expect(Text.number(r'$1,234.50'), equals(1234.5));
      expect(Text.number('no digits'), isNull);
      expect(Text.number('-42 items'), equals(-42));
      expect(
        Text.numbers('3 of 7 at 2.5').toList(),
        equals([3, 7, 2.5]),
      );

      expect(Text.number('(5)'), equals(-5));
      expect(Text.number('(1,234.50)'), equals(-1234.5));
      expect(Text.numbers('(3) and 4').toList(), equals([-3, 4]));

      expect(Text.number('1e3'), equals(1000));
      expect(Text.number('1.5e3'), equals(1500.0));
      expect(Text.number('2E-2'), equals(0.02));

      expect(Text.number('1,2'), equals(1));
      expect(Text.numbers('1,2').toList(), equals([1, 2]));
      expect(Text.number('1 234 567'), equals(1234567));
      expect(Text.number('12 34'), equals(12));
      expect(Text.number('1_000'), equals(1000));
    });

    test('render fills a template and leaves a missing key empty', () {
      expect(
        Text.render('Hello {name}, {count} new', {
          'name': 'x',
          'count': 3,
        }),
        equals('Hello x, 3 new'),
      );
      expect(Text.render('{a}-{b}', {'a': 1}), equals('1-'));
      expect(Text.render('no slots', {'a': 1}), equals('no slots'));
      expect(Text.render('{ a }', {'a': 1}), equals('{ a }'));
      expect(Text.render('{a}{a}', {'a': 'x'}), equals('xx'));
    });

    test('fold maps every accented letter to its own plain form', () {
      const groups = <String, String>{
        'a': 'àáâãäåāăą',
        'c': 'çćĉċč',
        'd': 'đďð',
        'e': 'èéêëēĕėęě',
        'g': 'ğĝġģ',
        'h': 'ĥħ',
        'i': 'ìíîïĩīĭįı',
        'j': 'ĵ',
        'k': 'ķ',
        'l': 'ĺļľł',
        'n': 'ñńņň',
        'o': 'òóôõöøōŏő',
        'r': 'ŕŗř',
        's': 'śŝşš',
        't': 'ţťŧ',
        'u': 'ùúûüũūŭůűų',
        'w': 'ŵ',
        'y': 'ýÿŷ',
        'z': 'źżž',
      };
      var checked = 0;
      groups.forEach((plain, accented) {
        for (final letter in accented.split('')) {
          checked++;
          expect(Text.fold(letter), equals(plain), reason: letter);
          expect(
            Text.fold(letter.toUpperCase()),
            equals(plain.toUpperCase()),
            reason: letter.toUpperCase(),
          );
        }
      });

      const spelled = <String, String>{
        'ß': 'ss',
        'æ': 'ae',
        'œ': 'oe',
        'ĳ': 'ij',
        'þ': 'th',
      };
      spelled.forEach((letter, plain) {
        checked++;
        expect(Text.fold(letter), equals(plain), reason: letter);
        if (letter.toUpperCase() != letter) {
          expect(
            Text.fold(letter.toUpperCase()),
            equals(plain[0].toUpperCase() + plain.substring(1)),
            reason: letter.toUpperCase(),
          );
        }
      });

      expect(checked, equals(92));
      expect(Text.fold('日本語'), equals('日本語'));
      expect(Text.fold('Заголовок'), equals('Заголовок'));

      expect(Text.slug('Crème Brûlée'), equals('creme-brulee'));
      expect(Text.slug('Señor Muñoz'), equals('senor-munoz'));
      expect(Text.slug('Straße'), equals('strasse'));
    });

    test('title, upper, words, blank', () {
      expect(Text.title('hELLO there'), equals('Hello There'));
      expect(Text.upper('hello'), equals('Hello'));
      expect(
        Text.words('one two-three').toList(),
        equals(['one', 'two', 'three']),
      );
      expect(Text.blank('   \n '), isTrue);
      expect(Text.blank(' x '), isFalse);
    });

    test('between and betweens', () {
      const body = 'a "id":"one" b "id":"two" c';
      expect(
        Text.betweens(body, '"id":"', '"').firstOrNull,
        equals('one'),
      );
      expect(
        Text.betweens(body, '"id":"', '"').toList(),
        equals(['one', 'two']),
      );
      expect(
        Text.betweens(body, 'missing', '"').firstOrNull,
        isNull,
      );
    });
  });

  group('Hash', () {
    test('sha, md5 and short', () {
      expect(Hash.sha('abc').length, equals(64));
      expect(Hash.md5('abc').length, equals(32));
      expect(
        Hash.sha('abc').substring(0, 8),
        equals(Hash.sha('abc').substring(0, 8)),
      );
      expect(Hash.sha('abc'), equals(Hash.sha(utf8.encode('abc'))));
    });

    test('sign is stable and key-dependent', () {
      expect(
        Hash.sign('body', 'k1'),
        equals(Hash.sign('body', 'k1')),
      );
      expect(Hash.sign('body', 'k1'), isNot(Hash.sign('body', 'k2')));
    });

    test('base64 round-trips', () {
      final encoded = Text.base64('hello');
      expect(utf8.decode(Text.unbase64(encoded)), equals('hello'));
    });
  });

  group('Time reads back', () {
    test('parse takes ISO first, then the loose forms', () {
      expect(Time.parse('2024-03-09T10:15:00Z')?.isUtc, isTrue);
      expect(Time.parse('2024-03-09'), equals(DateTime(2024, 3, 9)));
      expect(
        Time.parse('2024-03-09 10:15'),
        equals(DateTime(2024, 3, 9, 10, 15)),
      );
      expect(Time.parse('2024/03/09'), equals(DateTime(2024, 3, 9)));
      expect(
        Time.parse('09/03/2024'),
        equals(DateTime(2024, 3, 9)),
        reason: 'a two-digit first group is the day',
      );
      expect(Time.parse('09.03.2024'), equals(DateTime(2024, 3, 9)));
      expect(Time.parse('9 Mar 2024'), equals(DateTime(2024, 3, 9)));
      expect(Time.parse('March 9, 2024'), equals(DateTime(2024, 3, 9)));
    });

    test('parse reads back what stamp writes', () {
      final when = DateTime(2024, 3, 9, 10, 15, 30);
      expect(Time.parse(Time.stamp(when)), equals(when));
      expect(
        Time.parse(when.toUtc().toIso8601String())?.toUtc(),
        equals(when.toUtc()),
      );
    });

    test('a bad date is null rather than a throw', () {
      expect(Time.parse(''), isNull);
      expect(Time.parse('tomorrow'), isNull);
      expect(Time.parse('31/02/2024'), isNull, reason: 'no such day');
      expect(Time.parse('2024-13-01'), isNull);
      expect(Time.parse('1700000000'), isNull);
      expect(Time.parse('20240102'), equals(DateTime(2024, 1, 2)));
    });

    test('format carries the sign of a negative duration', () {
      expect(Time.format(const Duration(seconds: -5)), equals('-00:05'));
      expect(
        Time.format(const Duration(seconds: -3725)),
        equals('-01:02:05'),
      );
      expect(
        Time.format(const Duration(seconds: 3725)),
        equals('01:02:05'),
      );
      expect(Time.format(Duration.zero), equals('00:00'));
    });

    test('span reads the units a timeout is written in', () {
      expect(Time.span('250ms'), equals(250.ms));
      expect(Time.span('30s'), equals(30.s));
      expect(Time.span('5m'), equals(5.m));
      expect(Time.span('2h'), equals(2.h));
      expect(Time.span('1d'), equals(1.d));
      expect(Time.span('1w'), equals(7.d));
      expect(Time.span('1h30m'), equals(90.m));
      expect(Time.span('2d 12h'), equals(60.h));
      expect(Time.span('1.5h'), equals(90.m));
      expect(Time.span('30'), equals(30.s), reason: 'bare means seconds');
      expect(Time.span(''), isNull);
      expect(Time.span('soon'), isNull);
      expect(Time.span('5 apples'), isNull);
    });

    test('day is the grouping primitive', () {
      final noon = DateTime(2024, 3, 9, 12, 30, 15);
      expect(Time.day(noon), equals(DateTime(2024, 3, 9)));
      expect(Time.day(noon.toUtc()).isUtc, isTrue);

      final stamps = [
        DateTime(2024, 3, 9, 1),
        DateTime(2024, 3, 9, 23),
        DateTime(2024, 3, 10, 5),
      ];
      expect(stamps.map(Time.day).toSet().length, equals(2));
    });

    test('int gained the two missing rungs', () {
      expect(2.h, equals(const Duration(hours: 2)));
      expect(3.d, equals(const Duration(days: 3)));
    });
  });

  group('Rand', () {
    test('pick, some and shuffle stay inside the pool', () {
      final pool = List.generate(10, (i) => i);
      expect(pool, contains(Rand.pick(pool)));
      final three = Rand.shuffle(pool).take(3).toList();
      expect(three, hasLength(3));
      expect(three.toSet(), hasLength(3));
      expect(
        Rand.shuffle(pool).take(99).toList(),
        hasLength(10),
      );
      final shuffled = Rand.shuffle(pool);
      expect((shuffled.toList()..sort()), equals(pool));
      expect(() => Rand.pick(<int>[]), throwsStateError);
    });

    test('between, id, jitter and chance stay in range', () {
      for (var i = 0; i < 50; i++) {
        final n = Rand.between(5, 10);
        expect(n, allOf(greaterThanOrEqualTo(5), lessThan(10)));
      }
      expect(Rand.between(3, 3), equals(3));
      expect(Rand.id(16), hasLength(16));
      expect(Rand.id(), isNot(equals(Rand.id())));

      final jittered = Rand.jitter(const Duration(seconds: 2));
      expect(jittered, greaterThanOrEqualTo(const Duration(seconds: 2)));
      expect(jittered, lessThanOrEqualTo(const Duration(milliseconds: 2500)));

      expect(Rand.chance(1), isTrue);
      expect(Rand.chance(0), isFalse);
    });
  });
}
