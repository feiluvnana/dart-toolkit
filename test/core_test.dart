import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/src/core.dart';
import 'package:test/test.dart' hide Retry;

import 'support.dart';

void main() {
  group('core', () {
    test('FileBridge writes a file whose name leaves no room for a temporary name', () async {
      final dir = tempDir('tk_long');
      final path = '$dir/${'a' * 245}.txt';
      await FileBridge.write(path, [1]);
      FileBridge.writeSync(path, [1, 2]);
      expect(File(path).readAsBytesSync(), [1, 2]);
      expect(Directory(dir).listSync(), hasLength(1));
    });
  });

  group('FileBridge.settle claims', () {
    Future<List<int>> slow(String text) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return utf8.encode(text);
    }

    test('two saves at once under rename land on two names', () async {
      final to = '${tempDir()}/a.txt';
      final saved = await Future.wait([
        for (final text in ['first', 'second']) FileBridge.save(to, Conflict.rename, 'x', () => slow(text)),
      ]);
      expect(saved.toSet(), hasLength(2));
      expect({for (final f in saved) File(f).readAsStringSync()}, {'first', 'second'});
    });

    test('a claimed name is taken under every policy, and free again once released', () async {
      final to = '${tempDir()}/b.txt';
      final first = FileBridge.save(to, Conflict.skip, 'x', () => slow('first'));
      await Future<void>.delayed(const Duration(milliseconds: 20)); // settled, and still writing
      expect(
        await FileBridge.save(to, Conflict.skip, 'x', () => slow('second')).settled,
        isA<Done<Object?, Path>>().having((d) => d.fresh, 'fresh', isFalse),
      );
      await expectLater(
        FileBridge.save(to, Conflict.fail, 'x', () => slow('third')),
        throwsA(isA<PathExistsException>()),
      );
      await first;
      expect(File(to).readAsStringSync(), 'first');
      await FileBridge.save(to, Conflict.overwrite, 'x', () => slow('fourth'));
      expect(File(to).readAsStringSync(), 'fourth');
    });
  });

  group('Core or', () {
    int reading(int v) => v;
    String throwing() => throw MissingException('<a> has no href');
    String malformed() => throw const FormatException('unclosed tag at 3');
    String unsupported() => throw UnsupportedError('dart_toolkit_native did not load');
    String broken() => throw StateError('a caller got the arguments wrong');
    Object absentObject() => throw MissingException('<a> has no href');

    test('or answers the value when the reading succeeds', () {
      expect((() => reading(7)).or(0), 7);
      expect((() => reading(7)).or(99), 7);
    });

    test('a MissingException becomes the fallback, and the message is the reading own', () {
      expect((() => throwing()).or(''), '');
      expect((() => throwing()).or('fallback'), 'fallback');
      // the guard is unreachable, so `orNull` is what stands in for it
      final found = (() => throwing()).orNull;
      expect(found, isNull);
      // and without a door the same reading throws, naming what was missing
      expect(() => throwing(), throwsA(isA<MissingException>().having((e) => e.message, 'message', contains('href'))));
    });

    test('a MissingException is an Exception, not an Error: absence is the caller\'s to catch', () {
      expect(const MissingException('x'), isA<Exception>());
      expect(const MissingException('x'), isNot(isA<Error>()));
      expect('${const MissingException('x')}', 'Missing x');
      // a StateError is a broken call, so `on StateError` never reads an absence as one
      expect(() {
        try {
          throwing();
        } on StateError {
          return;
        }
      }, throwsA(isA<MissingException>()));
    });

    test('orNull answers the value when the reading succeeds, unannotated', () {
      // the absence door carries no inference hazard: `T?` is the return type outright, so there is
      // no type argument to solve and no context needed to get the right answer
      expect((() => reading(7)).orNull, 7);
      expect((() => Uri.parse('https://x.dev/a.mp3')).orNull, Uri.parse('https://x.dev/a.mp3'));
      expect((() => <String>['a']).orNull, ['a']);
      // and it replaces a twin member outright
      expect((() => throwing()).orNull, isNull);
    });

    test('only a MissingException becomes the fallback; every other failure travels', () {
      int rangeReading(int v) => throw RangeError('out of range');
      int argumentReading(int v) => int.parse('not a number');

      // a malformed document is never silently skipped — the FormatException travels on
      expect(() => (() => malformed()).or('skipped'), throwsA(isA<FormatException>()));
      // and so does a missing native library
      expect(() => (() => unsupported()).or('skipped'), throwsA(isA<UnsupportedError>()));
      // a bad type argument and a range error travel too
      expect(() => (() => argumentReading(1)).or(0), throwsFormatException);
      expect(() => (() => rangeReading(1)).or(0), throwsA(isA<RangeError>()));

      // and the absence door is just as narrow
      expect(() => (() => malformed()).orNull, throwsFormatException);
      expect(() => (() => unsupported()).orNull, throwsUnsupportedError);

      // the MissingException beside them does not
      expect((() => throwing()).or('skipped'), 'skipped');
      // and a plain StateError is a broken call, not an absence: it travels too, so the
      // package's own bugs are never read as "nothing there"
      expect(() => (() => broken()).or('skipped'), throwsStateError);
      expect(() => (() => broken()).orNull, throwsStateError);
    });

    test('the default is typed by the default: every row of the inference table', () {
      final int anInt = (() => reading(3)).or(0);
      final String aString = (() => throwing()).or('');
      final List<String> aList = (() => <String>['a']).or(const <String>[]);
      final Uri aUri = (() => Uri.parse('https://x.dev')).or(Uri.parse('https://fallback'));

      expect(
        [anInt, aString, aList, aUri],
        equals([
          3,
          '',
          ['a'],
          Uri.parse('https://x.dev'),
        ]),
      );
    });

    test('a default that does not fit the reading is a compile error', () {
      // `T or(T)` solves one type for both: `(() => 'x'.trim()).or(false)` is rejected by the
      // analyzer with "The argument type 'bool' can't be assigned to the parameter type 'String'",
      // and so is `(() => 'x'.trim()).or(null)`. It cannot be asserted at runtime, so the
      // soundness is pinned by the shape: every default below is a `T`, and each reading is one.
      int anIntReading(int v) => v;
      expect((() => anIntReading(1)).or(0), isA<int>());
      expect((() => anIntReading(1)).orNull, isA<int?>());
    });

    test('a wide reading keeps its own type: the default does not re-type it', () {
      // `Env.get('PORT')` is an `Object` reading, so `.or(8080)` is an `Object` and
      // `final int port = …` does not compile. Typing the reading is the caller's move:
      // `Env.get<int>('PORT')`, which `or` then answers as an int.
      final Object raw = 'a string';
      final Object withDefault = (() => raw).or(false);
      final Object withEmpty = (() => raw).or('');
      final Object thrownAway = (() => absentObject()).or(false);

      expect(withDefault, 'a string'); // the value is there, so it stands, whatever its type
      expect(withEmpty, 'a string'); // and again, rather than the fallback's type
      expect(thrownAway, isFalse); // only a MissingException takes the fallback, typed as the Object it is

      final Object number = 42;
      expect((() => number).or(0), 42);
      expect((() => number).or(-1), 42);
    });

    test('an async reading gets an awaited door, because its absence arrives in the Future', () async {
      Future<String> absent() async => throw MissingException('nothing matched');
      Future<String> present() async => 'found';

      // an `async` body throws into the returned Future, so only an awaited door sees the absence
      expect(await (() => present()).orNull, 'found');
      expect(await (() => absent()).orNull, isNull);

      expect(await (() => present()).or('none'), 'found');
      expect(await (() => absent()).or('none'), 'none');
      // a Future default reads as one
      expect(await (() => absent()).or(Future<String>.value('none')), 'none');

      // the awaited door is just as narrow about what it catches
      Future<String> malformed() async => throw const FormatException('bad page');
      expect(() => (() => malformed()).orNull, throwsFormatException);
    });

    test('a thunk defers, so the reading has not run before the door does', () {
      var ran = false;
      int reading() {
        ran = true;
        return 7;
      }

      // `els.link.orNull` would have thrown at the getter, before any door ran
      expect(ran, isFalse);
      expect((() => reading()).orNull, 7);
      expect(ran, isTrue);
    });

    test('or covers the absence of a reading without a twin member', () {
      final Map<String, String> attrs = {'title': 'a title'};
      String attr(String name) => attrs[name] ?? (throw MissingException('<a> has no $name'));

      // a guaranteed value, unchanged
      expect(attr('title'), 'a title');
      // the door, for a default that is a capability no twin had
      expect((() => attr('alt')).or(attrs['title']!), 'a title');
      // and for an expected absence
      expect((() => attr('alt')).orNull, isNull);
    });
  });

  group('Environment & .env utilities', () {
    test('a bare number is seconds and a numeric string is an epoch, in Env, Row and JSON', () {
      Env.set('TK_WAIT', '90');
      expect(Env.get<Duration>('TK_WAIT'), const Duration(seconds: 90));
      Env.set('TK_WAIT', '250ms');
      expect(Env.get<Duration>('TK_WAIT'), const Duration(milliseconds: 250));
      expect('1700000000'.to<DateTime>(), DateTime.utc(2023, 11, 14, 22, 13, 20));
      expect('1.5'.to<Duration>(), const Duration(milliseconds: 1500));
    });

    test('a # is a comment only after whitespace, and an escaped quote stays inside its quotes', () {
      final env = Env.parse('URL=http://x/#frag\nPASS=a#b\nQ="say \\"hi\\" \\\\ ok"\nWEB_PORT=80 # web\n');
      expect(env['URL'], 'http://x/#frag');
      expect(env['PASS'], 'a#b');
      expect(env['Q'], r'say "hi" \ ok');
      expect(env['WEB_PORT'], '80');
    });

    test('expand: reads earlier lines and the environment; single quotes and \\\$ stay literal', () {
      Env.set('TK_HOST', 'example.com');
      final env = Env.parse(
        'TK_PORT=8080\n'
        'TK_URL=http://\${TK_HOST}:\$TK_PORT/api\n'
        'TK_Q="\$TK_PORT and \\\$TK_PORT"\n'
        "TK_RAW='\$TK_PORT'\n"
        'TK_NONE=[\${TK_UNSET_XYZ}]\n',
        expand: true,
      );
      expect(env['TK_URL'], 'http://example.com:8080/api');
      expect(env['TK_Q'], r'8080 and $TK_PORT');
      expect(env['TK_RAW'], r'$TK_PORT');
      expect(env['TK_NONE'], '[]');
      expect(Env.parse(r'TK_LIT=$TK_PORT')['TK_LIT'], r'$TK_PORT');
    });

    test('load looks in the working directory, then beside the running script', () async {
      final beside = File('test/.env.tk_load')..writeAsStringSync('TK_LOADED=beside\n');
      addTearDown(() => beside.existsSync() ? beside.deleteSync() : null);
      await Env.scope(() async {
        expect(await Env.load('.env.tk_load', override: true), {'TK_LOADED': 'beside'});
        expect(Env.get<String>('TK_LOADED'), 'beside');
        final here = File('.env.tk_load')..writeAsStringSync('TK_LOADED=cwd\n');
        addTearDown(() => here.existsSync() ? here.deleteSync() : null);
        expect(await Env.load('.env.tk_load', override: true), {'TK_LOADED': 'cwd'});
        expect(await Env.load('.env.tk_nowhere'), isEmpty);
      });
    });

    test('a prompt reads through Io.readLine, which is async and scriptable', () async {
      await Io.scope(() async {
        expect(await Io.readLine(), 'first');
        expect(await Io.readLine(), isNull);
      }, stdin: Stream.value(utf8.encode('first\n')));
    });

    test('Io.readLine reads piped or redirected stdin line by line to its end', () async {
      final dir = Directory('.dart_tool/tk_readline')..createSync(recursive: true);
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File('${dir.path}/main.dart')
        ..writeAsStringSync('''
import 'package:dart_toolkit/core.dart';
void main() async {
  for (String? line; (line = await Io.readLine()) != null;) {
    print('[\$line]');
  }
}
''');
      final child = await Process.start(Platform.resolvedExecutable, [script.path]);
      child.stdin.write('a\nb€\n\nlast');
      await child.stdin.close();
      final out = await child.stdout.transform(utf8.decoder).join();
      expect(await child.exitCode, 0);
      expect(out.split(RegExp(r'\r?\n')).where((l) => l.isNotEmpty), ['[a]', '[b€]', '[]', '[last]']);
      if (Platform.isWindows) return;
      final input = File('${dir.path}/in.txt')..writeAsStringSync('x\ny€\n');
      final redirected = await Process.run('/bin/sh', [
        '-c',
        '"\$0" "\$1" < "\$2"',
        Platform.resolvedExecutable,
        script.path,
        input.path,
      ], stdoutEncoding: utf8);
      expect(redirected.exitCode, 0, reason: '${redirected.stderr}');
      expect('${redirected.stdout}'.split('\n').where((l) => l.isNotEmpty), ['[x]', '[y€]']);
    });

    test('Io.lines and friends read piped stdin in chunks, a character two writes cut arriving whole', () async {
      final dir = Directory('.dart_tool/tk_lines')..createSync(recursive: true);
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File('${dir.path}/main.dart')
        ..writeAsStringSync('''
import 'package:dart_toolkit/core.dart';
void main(List<String> args) async {
  switch (args.first) {
    case 'lines':
      await for (final line in Io.lines()) print('[\$line]');
    case 'read':
      print('[\${await Io.read()}]');
  }
}
''');
      final euro = utf8.encode('€');
      for (final mode in ['lines', 'read']) {
        final child = await Process.start(Platform.resolvedExecutable, [script.path, mode]);
        child.stdin.add([...utf8.encode('a\r\nb'), euro[0]]);
        await child.stdin.flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        child.stdin.add([...euro.sublist(1), ...utf8.encode('\n\nlast')]);
        await child.stdin.close();
        final out = await child.stdout.transform(utf8.decoder).join();
        expect(await child.exitCode, 0, reason: mode);
        final want = mode == 'lines' ? '[a]\n[b€]\n[]\n[last]\n' : '[a\nb€\n\nlast]\n';
        // `print`'s own line endings.
        final got = mode == 'lines'
            ? out.replaceAll(Platform.lineTerminator, '\n')
            : out.replaceFirst(RegExp(r'\r?\n$'), '\n');
        expect(got, want, reason: mode);
      }
    });

    test('Env.load parses keys, values, quotes, and comments', () {
      final sample = '''
# Comments should be ignored
API_URL=https://api.example.com
PORT=8080 # Trailing comment
export SECRET_KEY="super secret key with spaces"
ESCAPED_NEWLINE="line1\\nline2"
SINGLE_QUOTED='single quote value'
''';

      final env = Env.parse(sample);
      expect(env['API_URL'], equals('https://api.example.com'));
      expect(env['PORT'], equals('8080'));
      expect(env['SECRET_KEY'], equals('super secret key with spaces'));
      expect(env['ESCAPED_NEWLINE'], equals('line1\nline2'));
      expect(env['SINGLE_QUOTED'], equals('single quote value'));
      expect(env.containsKey('#'), isFalse);
      expect(Env.has('API_URL'), isFalse, reason: 'parse is pure');
    });

    test('Env.set shows in Env.all, what a child gets', () async {
      await Env.scope(() async {
        Env.set('TEST_VAR_XYZ', '12345');
        expect(Env.get<String>('TEST_VAR_XYZ'), equals('12345'));
        expect(Env.all['TEST_VAR_XYZ'], '12345');
      });
      expect(Env.has('TEST_VAR_XYZ'), isFalse);
    });

    test('Env.set and Env.get work in-memory', () {
      expect(Env.has('MY_CUSTOM_CONFIG'), isFalse);
      Env.set('MY_CUSTOM_CONFIG', 'enabled');
      expect(Env.has('MY_CUSTOM_CONFIG'), isTrue);
      expect(Env.get('MY_CUSTOM_CONFIG'), equals('enabled'));
    });

    test('Env.get throws naming the key when missing; or is the door for its absence', () {
      expect(
        () => Env.get('DEFINITELY_MISSING_VAR_9999'),
        throwsA(isA<MissingException>().having((e) => e.message, 'message', contains('DEFINITELY_MISSING_VAR_9999'))),
      );
      expect((() => Env.get('NON_EXISTENT_VAR')).or('fallback_val'), equals('fallback_val'));
      expect((() => Env.get('NON_EXISTENT_VAR')).orNull, isNull);
    });

    test('an empty variable is unset for get, orNull, has and parse', () {
      Env.set('TK_EMPTY_VAR', '');
      expect((() => Env.get('TK_EMPTY_VAR')).orNull, isNull);
      expect(Env.has('TK_EMPTY_VAR'), isFalse);
      expect((() => Env.get('TK_EMPTY_VAR')).or('d'), 'd');
      expect((() => Env.get<int>('TK_EMPTY_VAR')).or(7), 7);
      expect(() => Env.get('TK_EMPTY_VAR'), throwsA(isA<MissingException>()));
      Env.set('TK_EMPTY_VAR', 'filled');
      expect(Env.get('TK_EMPTY_VAR'), 'filled');
      expect(Env.has('TK_EMPTY_VAR'), isTrue);
    });

    test('or types Env.get by the default, and a value that does not parse still throws', () {
      Env.set('OR_INT', ' 42 ');
      Env.set('OR_DOUBLE', '1.5');
      Env.set('OR_NUM', '3');
      Env.set('OR_STR', ' x ');
      expect((() => Env.get<int>('OR_INT')).or(8080), 42);
      expect((() => Env.get<double>('OR_DOUBLE')).or(0.0), 1.5);
      expect((() => Env.get<num>('OR_NUM')).or(0), 3);
      // a `double` default is a `num`, so it fits a `num` reading; the value is there, so it
      // stands rather than the fallback re-typing it to a `double`
      expect((() => Env.get<num>('OR_NUM')).or(0.5), 3);
      expect((() => Env.get<String>('OR_STR')).or('d'), ' x ');
      expect((() => Env.get<int>('OR_MISSING_XYZ')).or(9), 9);
      expect(Env.get<int>('OR_INT'), 42, reason: 'a type argument parses without a door');
      final Object untyped = Env.get('OR_STR');
      expect(untyped, ' x ', reason: 'no type: the text');
      for (final (raw, want) in [
        ('true', true),
        ('YES', true),
        ('1', true),
        ('False', false),
        ('no', false),
        ('0', false),
      ]) {
        Env.set('OR_BOOL', raw);
        expect((() => Env.get<bool>('OR_BOOL')).or(!want), want, reason: raw);
      }
      Env.set('OR_BAD', 'eighty');
      // a default covers an absent variable, never a malformed one — that is a broken setting,
      // and it travels on through `or` as a FormatException
      expect((() => Env.get<int>('OR_MISSING_XYZ')).or(80), 80);
      expect(
        () => (() => Env.get<int>('OR_BAD')).or(80),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', allOf(contains('OR_BAD'), contains('int')))),
      );
      expect(() => (() => Env.get<bool>('OR_BAD')).or(true), throwsFormatException);
      expect(() => Env.get<int>('OR_BAD'), throwsFormatException);
      expect(() => Env.get<DateTime>('OR_BAD'), throwsFormatException);
      expect(() => Env.get<List<String>>('OR_INT'), throwsArgumentError);
    });

    test('Env.get(or:) is typed by its default; a present value wins, a wrong one throws', () {
      final port = Env.get('OR_ABSENT_PORT_XYZ', or: 8080);
      expect(port, isA<int>());
      expect(port, 8080);
      expect(Env.get('OR_ABSENT_DEBUG_XYZ', or: false), isFalse);
      Env.set('OR_PRESENT_PORT', '9090');
      expect(Env.get('OR_PRESENT_PORT', or: 8080), 9090);
      Env.set('OR_EMPTY', '');
      expect(Env.get('OR_EMPTY', or: 'd'), 'd', reason: 'an empty variable is unset');
      Env.set('OR_WRONG', 'eighty');
      expect(() => Env.get('OR_WRONG', or: 8080), throwsFormatException);
      final Object wide = Env.get('OR_ABSENT_WIDE_XYZ', or: 5);
      expect(wide, 5);
      expect(() => Env.get<int>('OR_ABSENT_PORT_XYZ'), throwsA(isA<MissingException>()));
    });

    test('Env.load without override keeps a value set earlier', () async {
      final dir = tempDir();
      Future<void> write(String text) async => File('$dir/.env').writeAsStringSync(text);
      await Env.scope(() async {
        await write('TK_FIRST_WINS=first');
        await Env.load('$dir/.env');
        await write('TK_FIRST_WINS=second');
        await Env.load('$dir/.env');
        expect(Env.get('TK_FIRST_WINS'), equals('first'));
        await write('TK_FIRST_WINS=third');
        await Env.load('$dir/.env', override: true);
        expect(Env.get('TK_FIRST_WINS'), equals('third'));
      });
    });

    test('.env: a quoted value spans lines; a line with no key is skipped', () {
      final parsed = Env.parse(
        'KEY="-----BEGIN\nabc\n-----END"\n=novalue\nexport\tTAB=1\nOPEN="never closes\nNEXT=2\nS=\'a\nb\'',
      );
      expect(parsed, {
        'KEY': '-----BEGIN\nabc\n-----END',
        'TAB': '1',
        'OPEN': '"never closes',
        'NEXT': '2',
        'S': 'a\nb',
      });
    });

    test('.env: a value spans lines only to a quote that ends a line, keeping its whitespace', () {
      final parsed = Env.parse('F="open\nG=1\nH="tab" x\nL="  first   \n  next"\nS=\'a\nT=\'b\' c');
      expect(parsed, {'F': '"open', 'G': '1', 'H': 'tab', 'L': '  first   \n  next', 'S': "'a", 'T': 'b'});
    });

    test('Env.parse handles unclosed quotes without quadratic blowup', () {
      final input = 'UNCLOSED="start of value\n${List.filled(5000, 'KEY=val').join('\n')}';
      final watch = Stopwatch()..start();
      final parsed = Env.parse(input);
      expect(watch.elapsedMilliseconds, lessThan(300));
      expect(parsed['UNCLOSED'], '"start of value');
      expect(parsed['KEY'], 'val');
    });

    test('Env.parse repeated key has last line win in both parsed and Env.get', () {
      final parsed = Env.parse('REPEAT_KEY=first\nREPEAT_KEY=second\n');
      expect(parsed['REPEAT_KEY'], 'second');
    });
  });

  group('durations, dates and sizes', () {
    test('Duration short getters', () {
      expect(500.ms, equals(const Duration(milliseconds: 500)));
      expect(5.s, equals(const Duration(seconds: 5)));
      expect(2.m, equals(const Duration(minutes: 2)));
      expect(3.h, equals(const Duration(hours: 3)));
      expect(1.d, equals(const Duration(days: 1)));
    });

    test('Duration.humanize formats nicely', () {
      expect(350.ms.humanized, equals('350ms'));
      expect(45.s.humanized, equals('45s'));
      expect((2.m + 15.s).humanized, equals('2m 15s'));
      expect((1.h + 5.m + 2.s).humanized, equals('1h 5m 2s'));
    });

    test('DateTime.format writes the tokens to<DateTime>(format:) reads, and reads back', () {
      final t = DateTime.utc(2026, 3, 7, 9, 5, 2);
      expect(t.format('yyyy-MM-dd HH:mm:ss'), '2026-03-07 09:05:02');
      expect(t.format('dd/MM/yy'), '07/03/26');
      expect(t.format('yyyyMMdd_HHmm'), '20260307_0905');
      expect(t.format('Tuesday y M'), 'Tuesday y M');
      expect(DateTime.utc(33).format('yyyy'), '0033');
      for (final f in ['dd/MM/yyyy HH:mm:ss', 'yyyyMMddHHmmss']) {
        expect(t.format(f).to<DateTime>(format: f), t);
      }
      expect(t.format('yy-MM-dd').to<DateTime>(format: 'yy-MM-dd'), DateTime.utc(2026, 3, 7));
    });

    test('the coercion reads clock lengths, ISO 8601 durations, RFC dates, month names and sizes', () {
      expect('3:45'.to<Duration>(), 3.m + 45.s);
      expect('1:02:03'.to<Duration>(), 1.h + 2.m + 3.s);
      expect('-0:30'.to<Duration>(), (-30).s);
      expect('4:13.5'.to<Duration>(), 4.m + 13.5.s);
      expect(() => '3:75'.to<Duration>(), throwsFormatException);
      expect('PT4M13S'.to<Duration>(), 4.m + 13.s);
      expect('P1DT2H'.to<Duration>(), 1.d + 2.h);
      expect('P2W'.to<Duration>(), 14.d);
      expect('PT0.5S'.to<Duration>(), 500.ms);
      expect(() => 'P1M'.to<Duration>(), throwsFormatException);
      expect(() => 'PT'.to<Duration>(), throwsFormatException);

      expect('Sun, 06 Nov 1994 08:49:37 GMT'.to<DateTime>(), DateTime.utc(1994, 11, 6, 8, 49, 37));
      expect('Wed, 02 Oct 2002 13:00:00 +0200'.to<DateTime>(), DateTime.utc(2002, 10, 2, 11));
      expect('Wed, 02 Oct 02 08:00:00 EST'.to<DateTime>(), DateTime.utc(2002, 10, 2, 13));
      expect('Sunday, 06-Nov-94 08:49:37 GMT'.to<DateTime>(), DateTime.utc(1994, 11, 6, 8, 49, 37));
      expect('Sun Nov  6 08:49:37 1994'.to<DateTime>(), DateTime.utc(1994, 11, 6, 8, 49, 37));
      expect(() => 'Sun, 31 Feb 1994 08:49:37 GMT'.to<DateTime>(), throwsFormatException);
      expect('08 October 2026'.to<DateTime>(format: 'dd MMMM yyyy'), DateTime.utc(2026, 10, 8));
      expect('Oct 08, 2026'.to<DateTime>(format: 'MMM dd, yyyy'), DateTime.utc(2026, 10, 8));
      expect('08 sept 2026'.to<DateTime>(format: 'dd MMMM yyyy'), DateTime.utc(2026, 9, 8));
      expect(DateTime.utc(2026, 10, 8).format('dd MMM yyyy, MMMM'), '08 Oct 2026, October');

      expect('1.5 GB'.to<int>(), 1610612736);
      expect('512 B'.to<int>(), 512);
      expect('20MiB'.to<int>(), 20 << 20);
      expect('1,5 KB'.to<int>(decimal: ','), 1536);
      expect((5000 << 30).humanBytes.to<num>(), closeTo(5000 << 30, 0.05 * (1 << 40)));
      expect(() => 'GB'.to<int>(), throwsFormatException);
    });

    test('humanized rounds to what it shows and reads back through to<Duration>', () {
      expect(1999.ms.humanized, '2s');
      expect(1949.ms.humanized, '1.9s');
      expect(9.96.s.humanized, '10s');
      expect(59.6.s.humanized, '1m');
      expect(999.6.ms.humanized, '1s');
      expect((2.d + 2.h + 40.s).humanized, '2d 2h');
      expect((1.d + 30.m).humanized, '1d 1h');
      for (final d in [1949.ms, 125.ms, 2.d + 2.h, 1.h + 5.m + 2.s, (-90).s]) {
        expect(d.humanized.to<Duration>().humanized, d.humanized);
      }
    });

    test('Duration.jitter adds variance within bounds', () {
      final base = 1000.ms;
      for (var i = 0; i < 20; i++) {
        final jittered = base.jittered(0.2);
        expect(jittered.inMilliseconds, greaterThanOrEqualTo(800));
        expect(jittered.inMilliseconds, lessThanOrEqualTo(1200));
      }
    });

    test('humanBytes picks the unit after rounding', () {
      expect(1048575.humanBytes, '1.0 MB');
      expect(1023.7.humanBytes, '1.0 KB');
      expect((1024 * 1024 * 1024 - 1).humanBytes, '1.0 GB');
      expect(1023.humanBytes, '1023 B');
      expect((3 << 40).humanBytes, '3.0 TB');
      expect((2 << 50).humanBytes, '2.0 PB');
    });

    test('humanBytes and humanized scale a negative value and keep its sign', () {
      expect((-1536).humanBytes, '-1.5 KB');
      expect((-512).humanBytes, '-512 B');
      expect((-90).s.humanized, '-1m 30s');
      expect((-350).ms.humanized, '-350ms');
    });

    test('jittered keeps sub-millisecond precision', () {
      const d = Duration(microseconds: 900);
      expect(d.jittered(0), d);
    });
  });

  group('CancelToken', () {
    test('registering one function twice gives independent slots', () {
      final token = CancelToken();
      var count = 0;
      void listener() => count++;

      final off1 = token.onCancel(listener);
      final off2 = token.onCancel(listener);

      off1();
      token.cancel();
      expect(count, 1);
      off2();
    });

    test('a throwing listener is the zone\'s uncaught error', () {
      final errors = <Object>[];
      runZonedGuarded(
        () {
          final token = CancelToken();
          token.onCancel(() => throw 'listener error');
          token.cancel();
        },
        (e, st) {
          errors.add(e);
        },
      );
      expect(errors, contains('listener error'));
    });
  });

  group('terminal text: width, truncate, pad and wrap', () {
    test('TextBridge.width: printable ASCII is its length; escapes, controls and DEL take the full path', () {
      expect(TextBridge.width(''), 0);
      expect(TextBridge.width('plain ascii, 123 ~!'), 19);
      expect(TextBridge.width('\x1b[31mred\x1b[0m'), 3);
      expect(TextBridge.width('a\tb'), 2);
      expect(TextBridge.width('a\x7fb'), 2);
      expect(TextBridge.width('café'), 4);
    });

    test('TextBridge.width measures wide dingbats and skin tone modifiers correctly', () {
      expect(TextBridge.width('✅'), 2);
      expect(TextBridge.width('❌'), 2);
      expect(TextBridge.width('☕'), 2);
      expect(TextBridge.width('⚡'), 2);
      // '👍' is 2, skin tone modifier is 0, so '👍🏽' is 2
      expect(TextBridge.width('👍🏽'), 2);
    });

    test('Io.width counts a ZWJ sequence as one glyph, and truncate never splits one', () {
      expect(TextBridge.width('👨‍👩‍👧'), 2);
      expect(TextBridge.width('a👩‍💻b'), 4);
      expect(TextBridge.truncate('👨‍👩‍👧 family photo', 5), '👨‍👩‍👧 f…');
      expect(TextBridge.truncate('👨‍👩‍👧 family photo', 2), '…');
    });

    test('truncate keeps every escape, so a style cut short still closes', () {
      const red = '\x1b[31m', reset = '\x1b[0m';
      expect(TextBridge.truncate('${red}error$reset: disk full', 6), '${red}error$reset…');
      expect(TextBridge.truncate('${red}a long message$reset', 4), '${red}a l…$reset');
      expect(TextBridge.truncate('short', 5), 'short');
      expect(TextBridge.truncate('short', 0), '');
    });

    test('pad fills to a width in columns, placed by align; wrap breaks at spaces', () {
      expect(TextBridge.pad('日本', 6), '日本  ');
      expect(TextBridge.pad('ab', 5, align: Align.right), '   ab');
      expect(TextBridge.pad('ab', 5, align: Align.center), ' ab  ');
      expect(TextBridge.pad('toolong', 3), 'toolong');
      expect(TextBridge.wrap('one two three\nfour', 7), ['one two', 'three', 'four']);
      expect(TextBridge.wrap('a enormousword b', 4), ['a', 'enormousword', 'b']);
    });
  });

  group('source hygiene', () {
    test('no library file holds a control byte that makes it binary to grep', () {
      // A raw NUL in a string literal once made an entire 756-line file invisible to
      // grep, ripgrep and code search.
      final offenders = [
        for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
          if (f.path.endsWith('.dart') && f.readAsBytesSync().any((b) => b < 9 || (b > 13 && b < 32))) f.path,
      ];
      expect(offenders, isEmpty);
    });
  });

  test('num units: fractions and ints', () {
    expect(1.5.s, const Duration(milliseconds: 1500));
    expect(30.s, const Duration(seconds: 30));
    expect(0.25.ms, const Duration(microseconds: 250));
    expect(2.h, const Duration(hours: 2));
    expect(1536.humanBytes, '1.5 KB');
  });

  group('batch and task outcomes', () {
    test('Batch.merge: a part that fails before the others is no unhandled error', () async {
      final slow = [1].parallelize((i) async {
        await 200.ms.delay();
        return i;
      });
      final fast = [2].parallelize<int>((i) async => throw Exception('boom $i'));
      await expectLater(Batch.merge([slow, fast]), throwsA(isA<BatchException<int, int>>()));
    });

    test('a cleanup runs uncancelled when the scope around the task is cancelled', () async {
      final stop = CancelToken();
      final seen = <String>[];
      late Task<int> task;
      final scope = Cancel.scope(() {
        task = Task.run('t', (work) async {
          work.defer(() async {
            seen.add('cancelled: ${Cancel.isCancelled}');
            await 10.ms.delay();
            seen.add('finished');
          });
          await 10.s.delay();
          return 0;
        });
        return task;
      }, token: stop);
      await 20.ms.delay();
      stop.cancel('bye');
      await expectLater(scope, throwsA(isA<CancelledException>()));
      expect(seen, ['cancelled: false', 'finished']);
      expect(await task.statuses.toList(), [isA<Stopped<Object?, int>>()], reason: 'no cleanup warning');
    });

    test('an isolate batch cancelled while its isolates start runs no item', () async {
      final dir = tempDir();
      final batch = ['$dir/a', '$dir/b'].parallelize(_markAfterASecond, isolate: true, concurrency: 2);
      await Future<void>.delayed(Duration.zero);
      batch.cancel('stop');
      expect((await batch.settled).every((s) => s is Stopped), isTrue);
      await 1500.ms.delay();
      expect(Directory(dir).listSync(), isEmpty);
    });

    test('a scope timeout is a TimeoutException for a batch, and for a task that ignores it', () async {
      await expectLater(
        Cancel.scope(() => [1, 2].parallelize((i) => 1.s.delay()), timeout: 50.ms),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(
        Cancel.scope(() => Task.run('deaf', (w) => Future<void>.delayed(1500.ms)), timeout: 50.ms),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('Batch.timeout cancels the batch and names it, as Task.timeout does', () async {
      final batch = [1, 2].parallelize((i) => 1.s.delay());
      await expectLater(
        batch.timeout(50.ms),
        throwsA(isA<TimeoutException>().having((e) => '$e', 'text', contains('timed out after 50ms'))),
      );
      expect((await batch.settled).every((s) => s is Stopped), isTrue);
    });

    test('a batch inside a task reports each item that ends, not every 32nd', () async {
      final task = Task.run(
        'outer',
        (work) => List.generate(6, (i) => i).parallelize((i) => (80 * (i + 1)).ms.delay(), concurrency: 6),
      );
      final heard = [
        await for (final s in task.statuses)
          if (s case Running(:final received)) received,
      ];
      expect(heard, containsAll([1, 2, 3, 4, 5, 6]));
    });

    test('parallelize refuses a negative Retry at the call', () {
      expect(() => [1].parallelize((i) => i, retry: Retry(int.parse('-1'))), throwsArgumentError);
    });
  });

  group('deadlines', () {
    test('cancelled deadlines keep no timer: a script exits when its work does', () async {
      final dir = Directory('.dart_tool/tk_deadline')..createSync(recursive: true);
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File('${dir.path}/main.dart')
        ..writeAsStringSync('''
import 'package:dart_toolkit/src/core.dart';
void main() {
  // What a request does with its 30 s timeout: armed, then cancelled when the answer comes.
  ClockInternals.after(const Duration(seconds: 30), () => print('fired')).cancel();
  final a = ClockInternals.after(const Duration(seconds: 30), () => print('fired'));
  final b = ClockInternals.after(const Duration(seconds: 40), () => print('fired'));
  a.cancel();
  b.cancel();
}
''');
      final watch = Stopwatch()..start();
      final run = await Process.run(Platform.resolvedExecutable, [script.path]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(run.stdout, isEmpty);
      expect(watch.elapsed, lessThan(const Duration(seconds: 20)), reason: 'not held until the 30 s deadline');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('Store', () {
    const a = Key<int>('a', or: 0), b = Key<int>('b', or: 0);

    test('the lock is re-entrant: a write inside update, a sub-store inside the lock', () async {
      final store = Store.memory();
      await store.update(a, (v) async {
        await store.write(b, 2);
        return v + 1;
      });
      expect([await store.read(a), await store.read(b)], [1, 2]);
      await store.lock(() => (store / 'crawl').write(a, 3));
      expect(await (store / 'crawl').read(a), 3);
    });

    test('nullable keys of lists of maps and maps of lists come back', () async {
      const maps = Key<List<Map<String, Object?>>?>('maps', or: null);
      const lists = Key<Map<String, List<String>>?>('lists', or: null);
      final store = Store.memory();
      await store.write(maps, [
        {'x': 1},
      ]);
      await store.write(lists, {
        'k': ['v'],
      });
      expect(await store.read(maps), [
        {'x': 1},
      ]);
      expect(await store.read(lists), {
        'k': ['v'],
      });
      const plain = Key<Map<String, List<String>>>('plain', or: {});
      await store.write(plain, {
        'k': ['v'],
      });
      expect(await store.read(plain), isA<Map<String, List<String>>>());
    });

    test('clearing a store never written makes no folder', () async {
      final dir = tempDir();
      await Store('$dir/never').clear();
      expect(Directory('$dir/never').existsSync(), isFalse);
    });
  });

  group('coercion: type arguments and zones', () {
    test('a type the reading cannot make is an ArgumentError, as in Env.get', () {
      expect(() => '1'.to<List<int>>(), throwsArgumentError);
      Env.set('TK_LIST', '1');
      expect(() => Env.get<List<int>>('TK_LIST'), throwsArgumentError);
    });

    test('text without a zone reads as UTC, as format: and RFC dates do', () {
      expect('2026-10-09 10:00'.to<DateTime>(), DateTime.utc(2026, 10, 9, 10));
      expect('2026-10-09t10:00:01.5'.to<DateTime>(), DateTime.utc(2026, 10, 9, 10, 0, 1, 500));
      expect('2026-10-09'.to<DateTime>(), DateTime.utc(2026, 10, 9));
      expect('2026-10-09T10:00+02:00'.to<DateTime>(), DateTime.utc(2026, 10, 9, 8));
      expect('09/10/2026'.to<DateTime>(), DateTime.utc(2026, 10, 9));
    });

    test('compareNatural orders as its key does', () {
      const words = ['a', 'A', 'a2', 'a10', 'a02', 'a/b', 'a b', 'a-1', 'é', 'İx', '0', '00', 'x9y', 'x10y', '', '/'];
      for (final x in words) {
        for (final y in words) {
          final byKey = CoerceBridge.naturalKey(x).compareTo(CoerceBridge.naturalKey(y));
          expect(compareNatural(x, y).sign, (byKey != 0 ? byKey : x.compareTo(y)).sign, reason: '$x vs $y');
        }
      }
    });
  });

  group('the absence doors: T?, or:, the thunk', () {
    test('a nullable type argument answers null for an unset variable, and parses a set one', () {
      Env.set('TK_ABSENCE_PORT', '42');
      expect(Env.get<int?>('TK_ABSENCE_NOPE'), isNull);
      expect(Env.get<String?>('TK_ABSENCE_NOPE'), isNull);
      expect(Env.get<int?>('TK_ABSENCE_PORT'), 42);
      expect(() => Env.get('TK_ABSENCE_NOPE'), throwsA(isA<MissingException>()), reason: 'untyped still throws');
      expect(() => Env.get<int>('TK_ABSENCE_NOPE'), throwsA(isA<MissingException>()));
    });

    test('the thunk takes a missing file as absence', () async {
      final missing = File('${Directory.systemTemp.path}/tk_absent_${DateTime.now().microsecondsSinceEpoch}.json');
      expect(await (() => missing.readAsString()).or('{}'), '{}');
      expect((() => missing.readAsStringSync()).orNull, isNull);
    });
  });
}

/// An isolate's item: after a second (or a cancel), writes [path].
Future<void> _markAfterASecond(String path) async {
  await 1.s.delay();
  File(path).writeAsStringSync('ran');
}
