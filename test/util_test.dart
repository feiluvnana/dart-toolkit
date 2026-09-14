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

      await Path(at('site')).zipTo(at('site.zip'));
      expect(File(at('site.zip')).existsSync(), isTrue);

      final files = await Path(at('site.zip')).unzipInto(at('out'));
      expect(files.length, equals(2));
      expect(
        File(at('out/index.html')).readAsStringSync(),
        equals('<h1>Home</h1>'),
      );
      expect(File(at('out/css/app.css')).readAsStringSync(), equals('body{}'));
    });

    test('lists and reads entries without unpacking', () async {
      writeFile(at('src/a.txt'), 'alpha');
      writeFile(at('src/b.txt'), 'beta');
      await Path(at('src')).zipTo(at('src.zip'));

      final names = (await Path(
        at('src.zip'),
      ).entries()).where((e) => !e.folder).map((e) => e.name).toList()..sort();
      expect(names, equals(['a.txt', 'b.txt']));

      final bytes = await Path(at('src.zip')).extract('b.txt');
      expect(utf8.decode(bytes!), equals('beta'));
      expect(await Path(at('src.zip')).extract('missing.txt'), isNull);
    });

    test('bundles in-memory data', () async {
      await Path(
        at('mem.zip'),
      ).writeArchive({'notes.txt': utf8.encode('from memory')});
      final bytes = await Path(at('mem.zip')).extract('notes.txt');
      expect(utf8.decode(bytes!), equals('from memory'));
    });

    test('round-trips through tar and tar.gz', () async {
      writeFile(at('d/one.txt'), 'one');
      for (final name in ['d.tar', 'd.tar.gz', 'd.tgz']) {
        await Path(at('d')).zipTo(at(name));
        final out = at('un_${name.toSlug()}');
        await Path(at(name)).unzipInto(out);
        expect(
          File(p.join(out, 'one.txt')).readAsStringSync(),
          equals('one'),
          reason: name,
        );
      }
    });

    test('ArchiveFormat is taken from the file name', () {
      expect(ArchiveFormat.of('a.zip'), equals(ArchiveFormat.zip));
      expect(ArchiveFormat.of('a.tar'), equals(ArchiveFormat.tar));
      expect(ArchiveFormat.of('a.tar.gz'), equals(ArchiveFormat.gz));
      expect(ArchiveFormat.of('a.tgz'), equals(ArchiveFormat.gz));
      expect(ArchiveFormat.of('a.tar.bz2'), equals(ArchiveFormat.bz2));
      expect(ArchiveFormat.of('nameless'), equals(ArchiveFormat.zip));
    });

    test('an entry that escapes the destination is skipped', () async {
      await Path(at('evil.zip')).writeArchive({
        '../escaped.txt': utf8.encode('nope'),
        'safe.txt': utf8.encode('yes'),
      });
      final written = await Path(at('evil.zip')).unzipInto(at('dest'));
      expect(written.length, equals(1));
      expect(File(at('escaped.txt')).existsSync(), isFalse);
      expect(File(at('dest/safe.txt')).readAsStringSync(), equals('yes'));
    });

    test('an archive that is not there is empty, not a throw', () async {
      final missing = at('absent.zip');
      expect((await Path(missing).entries()).length, equals(0));
      expect(await Path(missing).extract('a.txt'), isNull);
      expect((await Path(missing).unzipInto(at('nowhere'))).length, 0);
    });

    test('an extension no format covers is refused', () async {
      writeFile(at('one/a.txt'), 'x');
      expect(() => ArchiveFormat.of('site.rar'), throwsArgumentError);
      expect(() => Path(at('one')).zipTo(at('one.rar')), throwsArgumentError);
      // A name with no extension has nothing to disagree with.
      expect(ArchiveFormat.of('archive'), equals(ArchiveFormat.zip));
      // And an explicit format still overrides the name.
      await Path(at('one')).zipTo(at('one.rar'), format: ArchiveFormat.zip);
      expect(File(at('one.rar')).existsSync(), isTrue);
    });

    test('deflate and inflate round-trip', () {
      final raw = utf8.encode('compress me' * 50);
      final packed = raw.gzip();
      expect(packed.length, lessThan(raw.length));
      expect(packed.gunzip(), equals(raw));
    });
  });

  group('Text', () {
    test('slug', () {
      expect('Hello, World!'.toSlug(), equals('hello-world'));
      expect('  Café  Déjà Vu '.toSlug(), equals('cafe-deja-vu'));
      expect('a/b'.toSlug(separator: '_'), equals('a_b'));
    });

    test('clean and strip', () {
      expect('  a   b\n c '.cleanWhitespace(), equals('a b c'));
      expect('<p>Hi <b>there</b></p>'.stripTags(), equals('Hi there'));
      expect('a​b'.cleanWhitespace(), equals('ab'));
    });

    test('clip', () {
      expect('short'.clip(20), equals('short'));
      expect('a long sentence here'.clip(10), equals('a long se…'));
      expect('anything'.clip(0), equals(''));
    });

    test('number and numbers', () {
      expect(r'$1,234.50'.extractNumber(), equals(1234.5));
      expect('no digits'.extractNumber(), isNull);
      expect('-42 items'.extractNumber(), equals(-42));
      expect('3 of 7 at 2.5'.extractNumbers().toList(), equals([3, 7, 2.5]));

      expect('(5)'.extractNumber(), equals(-5));
      expect('(1,234.50)'.extractNumber(), equals(-1234.5));
      expect('(3) and 4'.extractNumbers().toList(), equals([-3, 4]));

      expect('1e3'.extractNumber(), equals(1000));
      expect('1.5e3'.extractNumber(), equals(1500.0));
      expect('2E-2'.extractNumber(), equals(0.02));

      expect('1,2'.extractNumber(), equals(1));
      expect('1,2'.extractNumbers().toList(), equals([1, 2]));
      expect('1 234 567'.extractNumber(), equals(1234567));
      expect('12 34'.extractNumber(), equals(12));
      expect('1_000'.extractNumber(), equals(1000));
    });

    test('render fills a template and leaves a missing key empty', () {
      expect(
        'Hello {name}, {count} new'.render({'name': 'x', 'count': 3}),
        equals('Hello x, 3 new'),
      );
      expect('{a}-{b}'.render({'a': 1}), equals('1-'));
      expect('no slots'.render({'a': 1}), equals('no slots'));
      expect('{ a }'.render({'a': 1}), equals('{ a }'));
      expect('{a}{a}'.render({'a': 'x'}), equals('xx'));
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
          expect(letter.foldAccents(), equals(plain), reason: letter);
          expect(
            letter.toUpperCase().foldAccents(),
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
        expect(letter.foldAccents(), equals(plain), reason: letter);
        if (letter.toUpperCase() != letter) {
          expect(
            letter.toUpperCase().foldAccents(),
            equals(plain[0].toUpperCase() + plain.substring(1)),
            reason: letter.toUpperCase(),
          );
        }
      });

      expect(checked, equals(92));
      expect('日本語'.foldAccents(), equals('日本語'));
      expect('Заголовок'.foldAccents(), equals('Заголовок'));

      expect('Crème Brûlée'.toSlug(), equals('creme-brulee'));
      expect('Señor Muñoz'.toSlug(), equals('senor-munoz'));
      expect('Straße'.toSlug(), equals('strasse'));
    });

    test('title, upper, words, blank', () {
      expect('hELLO there'.titleCase(), equals('Hello There'));
      expect('hello'.capitalize(), equals('Hello'));
      expect('one two-three'.words().toList(), equals(['one', 'two', 'three']));
      expect('   \n '.isBlank, isTrue);
      expect(' x '.isBlank, isFalse);
    });

    test('between and betweens', () {
      const body = 'a "id":"one" b "id":"two" c';
      expect(body.allBetween('"id":"', '"').firstOrNull, equals('one'));
      expect(body.allBetween('"id":"', '"').toList(), equals(['one', 'two']));
      expect(body.allBetween('missing', '"').firstOrNull, isNull);
    });
  });

  group('Hash', () {
    test('sha, md5 and short', () {
      expect('abc'.hash().length, equals(64));
      expect('abc'.hash(.md5).length, equals(32));
      expect(
        'abc'.hash().substring(0, 8),
        equals('abc'.hash().substring(0, 8)),
      );
      expect('abc'.hash(), equals(utf8.encode('abc').hash()));
    });

    test('sign is stable and key-dependent', () {
      expect('body'.hmac('k1'), equals('body'.hmac('k1')));
      expect('body'.hmac('k1'), isNot('body'.hmac('k2')));
    });

    test('base64 round-trips', () {
      final encoded = 'hello'.toBase64();
      expect(utf8.decode(encoded.fromBase64()), equals('hello'));
    });
  });

  group('Time reads back', () {
    test('parse takes ISO first, then the loose forms', () {
      expect('2024-03-09T10:15:00Z'.date?.isUtc, isTrue);
      expect('2024-03-09'.date, equals(DateTime(2024, 3, 9)));
      expect('2024-03-09 10:15'.date, equals(DateTime(2024, 3, 9, 10, 15)));
      expect('2024/03/09'.date, equals(DateTime(2024, 3, 9)));
      expect(
        '09/03/2024'.date,
        equals(DateTime(2024, 3, 9)),
        reason: 'a two-digit first group is the day',
      );
      expect('09.03.2024'.date, equals(DateTime(2024, 3, 9)));
      expect('9 Mar 2024'.date, equals(DateTime(2024, 3, 9)));
      expect('March 9, 2024'.date, equals(DateTime(2024, 3, 9)));
    });

    test('parse reads back what stamp writes', () {
      final when = DateTime(2024, 3, 9, 10, 15, 30);
      expect(when.timestamp.date, equals(when));
      expect(
        when.toUtc().toIso8601String().date?.toUtc(),
        equals(when.toUtc()),
      );
    });

    test('a bad date is null rather than a throw', () {
      expect(''.date, isNull);
      expect('tomorrow'.date, isNull);
      expect('31/02/2024'.date, isNull, reason: 'no such day');
      expect('2024-13-01'.date, isNull);
      expect('1700000000'.date, isNull);
      expect('20240102'.date, equals(DateTime(2024, 1, 2)));
    });

    test('format carries the sign of a negative duration', () {
      expect((const Duration(seconds: -5)).format(), equals('-00:05'));
      expect((const Duration(seconds: -3725)).format(), equals('-01:02:05'));
      expect((const Duration(seconds: 3725)).format(), equals('01:02:05'));
      expect(Duration.zero.format(), equals('00:00'));
    });

    test('span reads the units a timeout is written in', () {
      expect('250ms'.duration, equals(250.ms));
      expect('30s'.duration, equals(30.s));
      expect('5m'.duration, equals(5.m));
      expect('2h'.duration, equals(2.h));
      expect('1d'.duration, equals(1.d));
      expect('1w'.duration, equals(7.d));
      expect('1h30m'.duration, equals(90.m));
      expect('2d 12h'.duration, equals(60.h));
      expect('1.5h'.duration, equals(90.m));
      expect('30'.duration, equals(30.s), reason: 'bare means seconds');
      expect(''.duration, isNull);
      expect('soon'.duration, isNull);
      expect('5 apples'.duration, isNull);
    });

    test('day is the grouping primitive', () {
      final noon = DateTime(2024, 3, 9, 12, 30, 15);
      expect(noon.startOfDay, equals(DateTime(2024, 3, 9)));
      expect(noon.toUtc().startOfDay.isUtc, isTrue);

      final stamps = [
        DateTime(2024, 3, 9, 1),
        DateTime(2024, 3, 9, 23),
        DateTime(2024, 3, 10, 5),
      ];
      expect(stamps.map((d) => d.startOfDay).toSet().length, equals(2));
    });

    test('int gained the two missing rungs', () {
      expect(2.h, equals(const Duration(hours: 2)));
      expect(3.d, equals(const Duration(days: 3)));
    });
  });

  group('Rand', () {
    test('pick, some and shuffle stay inside the pool', () {
      final pool = List.generate(10, (i) => i);
      expect(pool, contains(pool.randomItem()));
      final three = pool.shuffled().take(3).toList();
      expect(three, hasLength(3));
      expect(three.toSet(), hasLength(3));
      expect(pool.shuffled().take(99).toList(), hasLength(10));
      final shuffled = pool.shuffled();
      expect((shuffled.toList()..sort()), equals(pool));
      expect(() => (<int>[]).randomItem(), throwsStateError);
    });

    test('between, id, jitter and chance stay in range', () {
      for (var i = 0; i < 50; i++) {
        final n = Rand.between(5, 10);
        expect(n, allOf(greaterThanOrEqualTo(5), lessThan(10)));
      }
      expect(Rand.between(3, 3), equals(3));
      expect(Rand.id(16), hasLength(16));
      expect(Rand.id(), isNot(equals(Rand.id())));

      final jittered = (const Duration(seconds: 2)).jittered();
      expect(jittered, greaterThanOrEqualTo(const Duration(seconds: 2)));
      expect(jittered, lessThanOrEqualTo(const Duration(milliseconds: 2500)));

      expect(Rand.chance(1), isTrue);
      expect(Rand.chance(0), isFalse);
    });
  });
}
