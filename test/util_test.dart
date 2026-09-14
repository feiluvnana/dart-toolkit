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

      await zip(at('site'), at('site.zip'));
      expect(File(at('site.zip')).existsSync(), isTrue);

      final files = await unzip(at('site.zip'), at('out'));
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
      await zip(at('src'), at('src.zip'));

      final names = (await listArchive(
        at('src.zip'),
      )).where((e) => !e.folder).map((e) => e.name).toList()..sort();
      expect(names, equals(['a.txt', 'b.txt']));

      final bytes = await extractFromArchive(at('src.zip'), 'b.txt');
      expect(utf8.decode(bytes!), equals('beta'));
      expect(await extractFromArchive(at('src.zip'), 'missing.txt'), isNull);
    });

    test('bundles in-memory data', () async {
      await zipBytes(at('mem.zip'), {'notes.txt': utf8.encode('from memory')});
      final bytes = await extractFromArchive(at('mem.zip'), 'notes.txt');
      expect(utf8.decode(bytes!), equals('from memory'));
    });

    test('round-trips through tar and tar.gz', () async {
      writeFile(at('d/one.txt'), 'one');
      for (final name in ['d.tar', 'd.tar.gz', 'd.tgz']) {
        await zip(at('d'), at(name));
        final out = at('un_${slugify(name)}');
        await unzip(at(name), out);
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
      await zipBytes(at('evil.zip'), {
        '../escaped.txt': utf8.encode('nope'),
        'safe.txt': utf8.encode('yes'),
      });
      final written = await unzip(at('evil.zip'), at('dest'));
      expect(written.length, equals(1));
      expect(File(at('escaped.txt')).existsSync(), isFalse);
      expect(File(at('dest/safe.txt')).readAsStringSync(), equals('yes'));
    });

    test('an archive that is not there is empty, not a throw', () async {
      final missing = at('absent.zip');
      expect((await listArchive(missing)).length, equals(0));
      expect(await extractFromArchive(missing, 'a.txt'), isNull);
      expect((await unzip(missing, at('nowhere'))).length, 0);
    });

    test('an extension no format covers is refused', () async {
      writeFile(at('one/a.txt'), 'x');
      expect(() => ArchiveFormat.of('site.rar'), throwsArgumentError);
      expect(() => zip(at('one'), at('one.rar')), throwsArgumentError);
      // A name with no extension has nothing to disagree with.
      expect(ArchiveFormat.of('archive'), equals(ArchiveFormat.zip));
      // And an explicit format still overrides the name.
      await zip(at('one'), at('one.rar'), format: ArchiveFormat.zip);
      expect(File(at('one.rar')).existsSync(), isTrue);
    });

    test('deflate and inflate round-trip', () {
      final raw = utf8.encode('compress me' * 50);
      final packed = gzipBytes(raw);
      expect(packed.length, lessThan(raw.length));
      expect(gunzipBytes(packed), equals(raw));
    });
  });

  group('Text', () {
    test('slug', () {
      expect(slugify('Hello, World!'), equals('hello-world'));
      expect(slugify('  Café  Déjà Vu '), equals('cafe-deja-vu'));
      expect(slugify('a/b', separator: '_'), equals('a_b'));
    });

    test('clean and strip', () {
      expect(cleanText('  a   b\n c '), equals('a b c'));
      expect(stripHtmlTags('<p>Hi <b>there</b></p>'), equals('Hi there'));
      expect(cleanText('a​b'), equals('ab'));
    });

    test('clip', () {
      expect(clipText('short', 20), equals('short'));
      expect(clipText('a long sentence here', 10), equals('a long se…'));
      expect(clipText('anything', 0), equals(''));
    });

    test('number and numbers', () {
      expect(extractNumber(r'$1,234.50'), equals(1234.5));
      expect(extractNumber('no digits'), isNull);
      expect(extractNumber('-42 items'), equals(-42));
      expect(extractNumbers('3 of 7 at 2.5').toList(), equals([3, 7, 2.5]));

      expect(extractNumber('(5)'), equals(-5));
      expect(extractNumber('(1,234.50)'), equals(-1234.5));
      expect(extractNumbers('(3) and 4').toList(), equals([-3, 4]));

      expect(extractNumber('1e3'), equals(1000));
      expect(extractNumber('1.5e3'), equals(1500.0));
      expect(extractNumber('2E-2'), equals(0.02));

      expect(extractNumber('1,2'), equals(1));
      expect(extractNumbers('1,2').toList(), equals([1, 2]));
      expect(extractNumber('1 234 567'), equals(1234567));
      expect(extractNumber('12 34'), equals(12));
      expect(extractNumber('1_000'), equals(1000));
    });

    test('render fills a template and leaves a missing key empty', () {
      expect(
        renderTemplate('Hello {name}, {count} new', {'name': 'x', 'count': 3}),
        equals('Hello x, 3 new'),
      );
      expect(renderTemplate('{a}-{b}', {'a': 1}), equals('1-'));
      expect(renderTemplate('no slots', {'a': 1}), equals('no slots'));
      expect(renderTemplate('{ a }', {'a': 1}), equals('{ a }'));
      expect(renderTemplate('{a}{a}', {'a': 'x'}), equals('xx'));
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
          expect(foldAccents(letter), equals(plain), reason: letter);
          expect(
            foldAccents(letter.toUpperCase()),
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
        expect(foldAccents(letter), equals(plain), reason: letter);
        if (letter.toUpperCase() != letter) {
          expect(
            foldAccents(letter.toUpperCase()),
            equals(plain[0].toUpperCase() + plain.substring(1)),
            reason: letter.toUpperCase(),
          );
        }
      });

      expect(checked, equals(92));
      expect(foldAccents('日本語'), equals('日本語'));
      expect(foldAccents('Заголовок'), equals('Заголовок'));

      expect(slugify('Crème Brûlée'), equals('creme-brulee'));
      expect(slugify('Señor Muñoz'), equals('senor-munoz'));
      expect(slugify('Straße'), equals('strasse'));
    });

    test('title, upper, words, blank', () {
      expect(titleCase('hELLO there'), equals('Hello There'));
      expect(capitalize('hello'), equals('Hello'));
      expect(
        wordsOf('one two-three').toList(),
        equals(['one', 'two', 'three']),
      );
      expect(isBlank('   \n '), isTrue);
      expect(isBlank(' x '), isFalse);
    });

    test('between and betweens', () {
      const body = 'a "id":"one" b "id":"two" c';
      expect(allTextBetween(body, '"id":"', '"').firstOrNull, equals('one'));
      expect(
        allTextBetween(body, '"id":"', '"').toList(),
        equals(['one', 'two']),
      );
      expect(allTextBetween(body, 'missing', '"').firstOrNull, isNull);
    });
  });

  group('Hash', () {
    test('sha, md5 and short', () {
      expect(sha256Hash('abc').length, equals(64));
      expect(md5Hash('abc').length, equals(32));
      expect(
        sha256Hash('abc').substring(0, 8),
        equals(sha256Hash('abc').substring(0, 8)),
      );
      expect(sha256Hash('abc'), equals(sha256Hash(utf8.encode('abc'))));
    });

    test('sign is stable and key-dependent', () {
      expect(hmacSha256('body', 'k1'), equals(hmacSha256('body', 'k1')));
      expect(hmacSha256('body', 'k1'), isNot(hmacSha256('body', 'k2')));
    });

    test('base64 round-trips', () {
      final encoded = toBase64('hello');
      expect(utf8.decode(fromBase64(encoded)), equals('hello'));
    });
  });

  group('Time reads back', () {
    test('parse takes ISO first, then the loose forms', () {
      expect(parseTime('2024-03-09T10:15:00Z')?.isUtc, isTrue);
      expect(parseTime('2024-03-09'), equals(DateTime(2024, 3, 9)));
      expect(
        parseTime('2024-03-09 10:15'),
        equals(DateTime(2024, 3, 9, 10, 15)),
      );
      expect(parseTime('2024/03/09'), equals(DateTime(2024, 3, 9)));
      expect(
        parseTime('09/03/2024'),
        equals(DateTime(2024, 3, 9)),
        reason: 'a two-digit first group is the day',
      );
      expect(parseTime('09.03.2024'), equals(DateTime(2024, 3, 9)));
      expect(parseTime('9 Mar 2024'), equals(DateTime(2024, 3, 9)));
      expect(parseTime('March 9, 2024'), equals(DateTime(2024, 3, 9)));
    });

    test('parse reads back what stamp writes', () {
      final when = DateTime(2024, 3, 9, 10, 15, 30);
      expect(parseTime(timestamp(when)), equals(when));
      expect(
        parseTime(when.toUtc().toIso8601String())?.toUtc(),
        equals(when.toUtc()),
      );
    });

    test('a bad date is null rather than a throw', () {
      expect(parseTime(''), isNull);
      expect(parseTime('tomorrow'), isNull);
      expect(parseTime('31/02/2024'), isNull, reason: 'no such day');
      expect(parseTime('2024-13-01'), isNull);
      expect(parseTime('1700000000'), isNull);
      expect(parseTime('20240102'), equals(DateTime(2024, 1, 2)));
    });

    test('format carries the sign of a negative duration', () {
      expect(formatDuration(const Duration(seconds: -5)), equals('-00:05'));
      expect(
        formatDuration(const Duration(seconds: -3725)),
        equals('-01:02:05'),
      );
      expect(formatDuration(const Duration(seconds: 3725)), equals('01:02:05'));
      expect(formatDuration(Duration.zero), equals('00:00'));
    });

    test('span reads the units a timeout is written in', () {
      expect(parseDuration('250ms'), equals(250.ms));
      expect(parseDuration('30s'), equals(30.s));
      expect(parseDuration('5m'), equals(5.m));
      expect(parseDuration('2h'), equals(2.h));
      expect(parseDuration('1d'), equals(1.d));
      expect(parseDuration('1w'), equals(7.d));
      expect(parseDuration('1h30m'), equals(90.m));
      expect(parseDuration('2d 12h'), equals(60.h));
      expect(parseDuration('1.5h'), equals(90.m));
      expect(parseDuration('30'), equals(30.s), reason: 'bare means seconds');
      expect(parseDuration(''), isNull);
      expect(parseDuration('soon'), isNull);
      expect(parseDuration('5 apples'), isNull);
    });

    test('day is the grouping primitive', () {
      final noon = DateTime(2024, 3, 9, 12, 30, 15);
      expect(startOfDay(noon), equals(DateTime(2024, 3, 9)));
      expect(startOfDay(noon.toUtc()).isUtc, isTrue);

      final stamps = [
        DateTime(2024, 3, 9, 1),
        DateTime(2024, 3, 9, 23),
        DateTime(2024, 3, 10, 5),
      ];
      expect(stamps.map(startOfDay).toSet().length, equals(2));
    });

    test('int gained the two missing rungs', () {
      expect(2.h, equals(const Duration(hours: 2)));
      expect(3.d, equals(const Duration(days: 3)));
    });
  });

  group('Rand', () {
    test('pick, some and shuffle stay inside the pool', () {
      final pool = List.generate(10, (i) => i);
      expect(pool, contains(randomPick(pool)));
      final three = randomShuffle(pool).take(3).toList();
      expect(three, hasLength(3));
      expect(three.toSet(), hasLength(3));
      expect(randomShuffle(pool).take(99).toList(), hasLength(10));
      final shuffled = randomShuffle(pool);
      expect((shuffled.toList()..sort()), equals(pool));
      expect(() => randomPick(<int>[]), throwsStateError);
    });

    test('between, id, jitter and chance stay in range', () {
      for (var i = 0; i < 50; i++) {
        final n = randomBetween(5, 10);
        expect(n, allOf(greaterThanOrEqualTo(5), lessThan(10)));
      }
      expect(randomBetween(3, 3), equals(3));
      expect(randomId(16), hasLength(16));
      expect(randomId(), isNot(equals(randomId())));

      final jittered = jitter(const Duration(seconds: 2));
      expect(jittered, greaterThanOrEqualTo(const Duration(seconds: 2)));
      expect(jittered, lessThanOrEqualTo(const Duration(milliseconds: 2500)));

      expect(randomChance(1), isTrue);
      expect(randomChance(0), isFalse);
    });
  });
}
