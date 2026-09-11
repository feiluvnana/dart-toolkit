import 'dart:convert';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('zip', () {
    late FileSystemEntry work;

    setUp(() => work = io.dir.temp('dt_zip_'));
    tearDown(() => io.remove(work.path));

    String at(String name) => io.path.join(work.path, name);

    test('packs a folder and unpacks it back', () async {
      io.write(at('site/index.html'), '<h1>Home</h1>');
      io.write(at('site/css/app.css'), 'body{}');

      await format.zip.pack(at('site'), at('site.zip'));
      expect(io.has(at('site.zip')), isTrue);

      final files = await format.zip.unpack(at('site.zip'), at('out'));
      expect(files.collect(.count()), equals(2));
      expect(io.read(at('out/index.html')), equals('<h1>Home</h1>'));
      expect(io.read(at('out/css/app.css')), equals('body{}'));
    });

    test('lists and reads entries without unpacking', () async {
      io.write(at('src/a.txt'), 'alpha');
      io.write(at('src/b.txt'), 'beta');
      await format.zip.pack(at('src'), at('src.zip'));

      final names =
          (await format.zip.list(at('src.zip')))
              .transform(.where((e) => !e.folder))
              .transform(.map((e) => e.name))
              .collect(.list())
            ..sort();
      expect(names, equals(['a.txt', 'b.txt']));

      final bytes = await format.zip.read(at('src.zip'), 'b.txt');
      expect(utf8.decode(bytes!), equals('beta'));
      expect(await format.zip.read(at('src.zip'), 'missing.txt'), isNull);
    });

    test('bundles in-memory data', () async {
      await format.zip.bundle(at('mem.zip'), {
        'notes.txt': utf8.encode('from memory'),
      });
      final bytes = await format.zip.read(at('mem.zip'), 'notes.txt');
      expect(utf8.decode(bytes!), equals('from memory'));
    });

    test('round-trips through tar and tar.gz', () async {
      io.write(at('d/one.txt'), 'one');
      for (final name in ['d.tar', 'd.tar.gz', 'd.tgz']) {
        await format.zip.pack(at('d'), at(name));
        final out = at('un_${util.text.slug(name)}');
        await format.zip.unpack(at(name), out);
        expect(
          io.read(io.path.join(out, 'one.txt')),
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
      await format.zip.bundle(at('evil.zip'), {
        '../escaped.txt': utf8.encode('nope'),
        'safe.txt': utf8.encode('yes'),
      });
      final written = await format.zip.unpack(at('evil.zip'), at('dest'));
      expect(written.collect(.count()), equals(1));
      expect(io.has(at('escaped.txt')), isFalse);
      expect(io.read(at('dest/safe.txt')), equals('yes'));
    });

    test('an archive that is not there is empty, not a throw', () async {
      // Every other missing-path read in the library is empty: io.find,
      // io.csv.rows, format.json.read. This was the one that raised
      // PathNotFoundException.
      final missing = at('absent.zip');
      expect((await format.zip.list(missing)).collect(.count()), equals(0));
      expect(await format.zip.read(missing, 'a.txt'), isNull);
      expect(
        (await format.zip.unpack(missing, at('nowhere'))).collect(.count()),
        0,
      );
    });

    test('an extension no format covers is refused', () async {
      // `pack('site', 'site.rar')` used to write a zip, name it .rar and
      // report success, because Format.of fell back to zip for everything.
      io.write(at('one/a.txt'), 'x');
      expect(() => Format.of('site.rar'), throwsArgumentError);
      expect(
        () => format.zip.pack(at('one'), at('one.rar')),
        throwsArgumentError,
      );
      // A name with no extension has nothing to disagree with.
      expect(Format.of('archive'), equals(Format.zip));
      // And an explicit format still overrides the name.
      await format.zip.pack(at('one'), at('one.rar'), format: Format.zip);
      expect(io.has(at('one.rar')), isTrue);
    });

    test('deflate and inflate round-trip', () {
      final raw = utf8.encode('compress me' * 50);
      final packed = format.zip.deflate(raw);
      expect(packed.length, lessThan(raw.length));
      expect(format.zip.inflate(packed), equals(raw));
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
      expect(
        util.text.numbers('3 of 7 at 2.5').collect(.list()),
        equals([3, 7, 2.5]),
      );

      // A parenthesised number is an accounting negative. This used to come
      // back positive, so a scraped financial table read the wrong way round.
      expect(util.text.number('(5)'), equals(-5));
      expect(util.text.number('(1,234.50)'), equals(-1234.5));
      expect(util.text.numbers('(3) and 4').collect(.list()), equals([-3, 4]));

      // An exponent is part of the number. '1e3' used to be 1.
      expect(util.text.number('1e3'), equals(1000));
      expect(util.text.number('1.5e3'), equals(1500.0));
      expect(util.text.number('2E-2'), equals(0.02));

      // A separator groups digits only in whole threes, which is the rule the
      // space already followed and the comma did not: '1,2' used to be 12.
      expect(util.text.number('1,2'), equals(1));
      expect(util.text.numbers('1,2').collect(.list()), equals([1, 2]));
      expect(util.text.number('1 234 567'), equals(1234567));
      expect(util.text.number('12 34'), equals(12));
      expect(util.text.number('1_000'), equals(1000));
    });

    test('render fills a template and leaves a missing key empty', () {
      expect(
        util.text.render('Hello {name}, {count} new', {
          'name': 'x',
          'count': 3,
        }),
        equals('Hello x, 3 new'),
      );
      expect(util.text.render('{a}-{b}', {'a': 1}), equals('1-'));
      expect(util.text.render('no slots', {'a': 1}), equals('no slots'));
      expect(util.text.render('{ a }', {'a': 1}), equals('{ a }'));
      expect(util.text.render('{a}{a}', {'a': 'x'}), equals('xx'));
    });

    // The two parallel string constants this table used to be were indexed
    // against each other, and one extra `c` among the replacements shifted
    // every group after it by one: `è` folded to `c`, `ñ` to `i`, and
    // `slug('Señor Muñoz')` to `'seior-muioz'`. 14 of 71 letters were wrong
    // and nothing noticed, so every letter is named here explicitly. A
    // spot-check cannot catch a shift; a full table can.
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
          expect(util.text.fold(letter), equals(plain), reason: letter);
          // An upper-case input keeps its case.
          expect(
            util.text.fold(letter.toUpperCase()),
            equals(plain.toUpperCase()),
            reason: letter.toUpperCase(),
          );
        }
      });

      // The ligatures and the sharp s are two letters where they are spelled
      // out, which is why the table is a map of strings and not a string.
      const spelled = <String, String>{
        'ß': 'ss',
        'æ': 'ae',
        'œ': 'oe',
        'ĳ': 'ij',
        'þ': 'th',
      };
      spelled.forEach((letter, plain) {
        checked++;
        expect(util.text.fold(letter), equals(plain), reason: letter);
        // `ß`.toUpperCase() is `ß` in Dart, so there is no upper-case form to
        // check for it; the ligatures do have one and it keeps its case.
        if (letter.toUpperCase() != letter) {
          expect(
            util.text.fold(letter.toUpperCase()),
            equals(plain[0].toUpperCase() + plain.substring(1)),
            reason: letter.toUpperCase(),
          );
        }
      });

      expect(checked, equals(92));

      // A script this does not cover passes through untouched.
      expect(util.text.fold('日本語'), equals('日本語'));
      expect(util.text.fold('Заголовок'), equals('Заголовок'));

      // What the shift actually broke.
      expect(util.text.slug('Crème Brûlée'), equals('creme-brulee'));
      expect(util.text.slug('Señor Muñoz'), equals('senor-munoz'));
      expect(util.text.slug('Straße'), equals('strasse'));
    });

    test('title, upper, words, blank', () {
      expect(util.text.title('hELLO there'), equals('Hello There'));
      expect(util.text.upper('hello'), equals('Hello'));
      expect(
        util.text.words('one two-three').collect(.list()),
        equals(['one', 'two', 'three']),
      );
      expect(util.text.blank('   \n '), isTrue);
      expect(util.text.blank(' x '), isFalse);
    });

    test('between and betweens', () {
      const body = 'a "id":"one" b "id":"two" c';
      expect(util.text.between(body, '"id":"', '"'), equals('one'));
      expect(
        util.text.betweens(body, '"id":"', '"').collect(.list()),
        equals(['one', 'two']),
      );
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

  group('util.time reads back', () {
    test('parse takes ISO first, then the loose forms', () {
      expect(util.time.parse('2024-03-09T10:15:00Z')?.isUtc, isTrue);
      expect(util.time.parse('2024-03-09'), equals(DateTime(2024, 3, 9)));
      expect(
        util.time.parse('2024-03-09 10:15'),
        equals(DateTime(2024, 3, 9, 10, 15)),
      );
      expect(util.time.parse('2024/03/09'), equals(DateTime(2024, 3, 9)));
      expect(
        util.time.parse('09/03/2024'),
        equals(DateTime(2024, 3, 9)),
        reason: 'a two-digit first group is the day',
      );
      expect(util.time.parse('09.03.2024'), equals(DateTime(2024, 3, 9)));
      expect(util.time.parse('9 Mar 2024'), equals(DateTime(2024, 3, 9)));
      expect(util.time.parse('March 9, 2024'), equals(DateTime(2024, 3, 9)));
    });

    test('parse reads back what stamp writes', () {
      final when = DateTime(2024, 3, 9, 10, 15, 30);
      expect(util.time.parse(util.time.stamp(when)), equals(when));
      expect(
        util.time.parse(util.time.iso(when))?.toUtc(),
        equals(when.toUtc()),
      );
    });

    test('a bad date is null rather than a throw', () {
      expect(util.time.parse(''), isNull);
      expect(util.time.parse('tomorrow'), isNull);
      expect(util.time.parse('31/02/2024'), isNull, reason: 'no such day');
      expect(util.time.parse('2024-13-01'), isNull);
      // `DateTime.parse` reads a run of digits as ISO 8601 basic format, so a
      // Unix timestamp came back as year 170000 rolled to 169999-11-30.
      expect(util.time.parse('1700000000'), isNull);
      expect(util.time.parse('20240102'), equals(DateTime(2024, 1, 2)));
    });

    test('format carries the sign of a negative duration', () {
      // The sign used to reach the remainders: '00:-5' is not a time.
      expect(util.time.format(const Duration(seconds: -5)), equals('-00:05'));
      expect(
        util.time.format(const Duration(seconds: -3725)),
        equals('-01:02:05'),
      );
      expect(
        util.time.format(const Duration(seconds: 3725)),
        equals('01:02:05'),
      );
      expect(util.time.format(Duration.zero), equals('00:00'));
    });

    test('span reads the units a timeout is written in', () {
      expect(util.time.span('250ms'), equals(250.ms));
      expect(util.time.span('30s'), equals(30.s));
      expect(util.time.span('5m'), equals(5.m));
      expect(util.time.span('2h'), equals(2.h));
      expect(util.time.span('1d'), equals(1.d));
      expect(util.time.span('1w'), equals(7.d));
      expect(util.time.span('1h30m'), equals(90.m));
      expect(util.time.span('2d 12h'), equals(60.h));
      expect(util.time.span('1.5h'), equals(90.m));
      expect(util.time.span('30'), equals(30.s), reason: 'bare means seconds');
      expect(util.time.span(''), isNull);
      expect(util.time.span('soon'), isNull);
      expect(util.time.span('5 apples'), isNull);
    });

    test('day is the grouping primitive', () {
      final noon = DateTime(2024, 3, 9, 12, 30, 15);
      expect(util.time.day(noon), equals(DateTime(2024, 3, 9)));
      expect(util.time.day(noon.toUtc()).isUtc, isTrue);

      final stamps = [
        DateTime(2024, 3, 9, 1),
        DateTime(2024, 3, 9, 23),
        DateTime(2024, 3, 10, 5),
      ].seq;
      expect(stamps.collect(.count.by(util.time.day)).count, equals(2));
    });

    test('int gained the two missing rungs', () {
      expect(2.h, equals(const Duration(hours: 2)));
      expect(3.d, equals(const Duration(days: 3)));
    });
  });

  group('util.rand', () {
    test('pick, some and shuffle stay inside the pool', () {
      final pool = List.generate(10, (i) => i);
      expect(pool, contains(util.rand.pick(pool)));
      final three = util.rand.some(pool, 3);
      expect(three.collect(.list()), hasLength(3));
      expect(three.collect(.set()), hasLength(3));
      expect(util.rand.some(pool, 99).collect(.list()), hasLength(10));
      final shuffled = util.rand.shuffle(pool);
      expect(shuffled.transform(.sort()).collect(.list()), equals(pool));
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
