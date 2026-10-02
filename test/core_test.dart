import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Core Either', () {
    test('Left and Right are read by pattern, leftOrNull and rightOrNull', () {
      final Either<String, int> right = Right(42);
      final Either<String, int> left = Left('error');

      expect(right is Right, isTrue);
      expect(right.rightOrNull, equals(42));
      expect(right.leftOrNull, isNull);

      expect(left is Left, isTrue);
      expect(left.leftOrNull, equals('error'));
      expect(left.rightOrNull, isNull);

      String describe(Either<String, int> e) => switch (e) {
        Left(:final value) => 'L: $value',
        Right(:final value) => 'R: $value',
      };
      expect(describe(right), 'R: 42');
      expect(describe(left), 'L: error');
    });

    test('rights, lefts and unwrap() read a batch still settling', () async {
      Future<List<Either<Object, int>>> batch() async => [const Right(1), Left(StateError('x')), const Right(3)];
      expect(await batch().rights, [1, 3]);
      expect(await batch().lefts, [isA<StateError>()]);
      await expectLater(batch().unwrap(), throwsStateError);
      expect(await Future.value(<Either<Object, int>>[const Right(2)]).unwrap(), [2]);
    });

    test('Either.unwrap returns the Right value or throws the Left value', () {
      expect(const Right<Object, int>(7).unwrap(), equals(7));

      final failure = FormatException('nope');
      expect(() => Left<Object, int>(failure).unwrap(), throwsA(same(failure)));
      expect(() => const Left<Object?, int>(null).unwrap(), throwsA(isA<StateError>()));
    });

    test('Iterable<Either>.unwrap / rights / lefts partition outcomes', () {
      final boom = StateError('boom');
      final outcomes = <Either<Object, int>>[const Right(1), Left(boom), const Right(3)];

      expect(outcomes.rights, equals([1, 3]));
      expect(outcomes.lefts, equals([boom]));
      expect(() => outcomes.unwrap(), throwsA(same(boom)));
      expect(<Either<Object, int>>[const Right(1), const Right(2)].unwrap(), equals([1, 2]));
    });

    test('Stream<Either>.unwrap forwards the first Left as a stream error', () {
      final boom = StateError('boom');
      final stream = Stream<Either<Object, int>>.fromIterable([const Right(1), Left(boom)]);
      expect(stream.unwrap(), emitsInOrder([1, emitsError(same(boom))]));
    });

    test('Stream<Either>.rights and lefts partition outcomes', () async {
      final boom = StateError('boom');
      Stream<Either<Object, int>> createStream() =>
          Stream<Either<Object, int>>.fromIterable([const Right(1), Left(boom), const Right(3)]);

      expect(await createStream().rights.toList(), equals([1, 3]));
      expect(await createStream().lefts.toList(), equals([boom]));
    });
  });

  group('JsonPath & String Pattern Evaluation', () {
    test('JsonPath parses and evaluates objects, arrays, and wildcards', () {
      final doc = {
        'items': [
          {'id': 1, 'name': 'Item 1'},
          {'id': 2, 'name': 'Item 2'},
        ],
      };
      final jsonDoc = JsonDocument(doc);
      final names = jsonDoc.$(r'$.items[*].name').map((d) => d.raw).toList();
      expect(names, equals(['Item 1', 'Item 2']));
    });

    test('JsonPath slices, and refuses filters with a FormatException', () {
      final jsonDoc = JsonDocument([1, 2, 3, 4, 5]);
      expect(jsonDoc.$(r'$[1:3]').map((e) => e.to<int>()), [2, 3]);
      // A filter is `.where` on the result, and says so.
      expect(() => jsonDoc.$(r'$[?(@.v > 20)]'), throwsA(isA<FormatException>()));
      expect(() => jsonDoc.$(r'$.a[unclosed'), throwsA(isA<FormatException>()));
    });

    test('String.match handles plain strings and RegExps without regex coercion', () {
      // Plain string with dot
      expect('axb'.match('a.b'), isNull);
      expect('a.b'.match('a.b'), equals('a.b'));

      // RegExp pattern
      expect('axb'.match(RegExp(r'a.b')), equals('axb'));
      expect('track-01.mp3'.match(RegExp(r'track-(\d+)'), 1), equals('01'));
    });
  });

  group('Either Subtype Equality & Typed Guards', () {
    test('Either == works across compatible subtype parameters', () {
      const leftObj = Left<Object, int>('err');
      const leftStr = Left<String, num>('err');
      expect(leftObj == leftStr, isTrue);

      const rightObj = Right<Object, int>(42);
      const rightNum = Right<String, num>(42);
      expect(rightObj == rightNum, isTrue);
    });
  });

  group('core', () {
    test('to<num>() parses numeric strings like to<double>() does', () {
      expect(JsonDocument('3.5').to<num>(), equals(3.5));
      expect(JsonDocument('3.5').to<double>(), equals(3.5));
      expect(JsonDocument('7').to<int>(), equals(7));
      expect(JsonDocument({'a': 1}).to<String>(), equals('{"a":1}'));
    });

    test(r'$..[0] applies the bracket to every descendant', () {
      final j = JsonDocument({
        'a': [10, 20],
        'b': {
          'c': [30],
        },
      });
      expect(j.$(r'$..[0]').map((d) => d.raw), equals([10, 30]));
      expect(j.$(r'$..a[0]').map((d) => d.raw), equals([10]));
    });

    test(r'doc[-1] and $[-1] agree', () {
      final j = JsonDocument([1, 2, 3]);
      expect(j[-1].raw, equals(3));
      expect(j.$(r'$[-1]').first.raw, equals(3));
    });

    test('Either keeps the stack trace of the failure it caught', () async {
      final [outcome] = await [0].parallelize((_) => _boom()).toList();
      try {
        outcome.unwrap();
        fail('should throw');
      } catch (_, st) {
        expect(st.toString(), contains('_boom'));
      }
    });
  });

  group('String Extensions', () {
    test('String.match extracts regex groups using RegExp pattern and matches literal strings', () {
      expect('Release version 9.4.2-alpha'.match(RegExp(r'version ([\d\.]+)'), 1), equals('9.4.2'));
      expect('DISC.05 (Original Soundtrack)'.match(RegExp(r'DISC\.(\d+)'), 1), equals('05'));
      expect('DISC.05'.match(RegExp(r'DISC\.(\d+)'), 1), equals('05'));
      expect('No match here'.match(RegExp(r'DISC\.(\d+)'), 1), isNull);
      expect('exact-match'.match('exact'), equals('exact'));
    });
  });

  group('Environment & .env utilities', () {
    test('a # is a comment only after whitespace, and an escaped quote stays inside its quotes', () {
      final env = Env.parse('URL=http://x/#frag\nPASS=a#b\nQ="say \\"hi\\" \\\\ ok"\nWEB_PORT=80 # web\n');
      expect(env['URL'], 'http://x/#frag');
      expect(env['PASS'], 'a#b');
      expect(env['Q'], r'say "hi" \ ok');
      expect(env['WEB_PORT'], '80');
    });

    test('a prompt reads through Io.readLine, which is async and scriptable', () async {
      final answers = ['first'];
      Io.input = () => answers.isEmpty ? null : answers.removeAt(0);
      addTearDown(Io.reset);
      expect(await Io.readLine(), 'first');
      expect(await Io.readLine(), isNull);
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
      expect(Env.get('PORT'), equals('8080'));
    });

    test('Env.parse with file content and Env.all()', () async {
      final sample = 'TEST_VAR_XYZ=12345\nANOTHER_VAR="test value"';
      final loaded = Env.parse(sample, override: true);
      expect(loaded['TEST_VAR_XYZ'], equals('12345'));
      expect(Env.get('TEST_VAR_XYZ'), equals('12345'));
      expect(Env.has('TEST_VAR_XYZ'), isTrue);
      expect(Env.all().containsKey('TEST_VAR_XYZ'), isTrue);
    });

    test('Env.set and Env.get work in-memory', () {
      expect(Env.has('MY_CUSTOM_CONFIG'), isFalse);
      Env.set('MY_CUSTOM_CONFIG', 'enabled');
      expect(Env.has('MY_CUSTOM_CONFIG'), isTrue);
      expect(Env.get('MY_CUSTOM_CONFIG'), equals('enabled'));
    });

    test('Env.get throws naming the key when missing; or: is the fallback', () {
      expect(
        () => Env.get('DEFINITELY_MISSING_VAR_9999'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('DEFINITELY_MISSING_VAR_9999'))),
      );
      expect(Env.get('NON_EXISTENT_VAR', or: 'fallback_val'), equals('fallback_val'));
      expect(Env.getOrNull('NON_EXISTENT_VAR'), isNull);
      expect(Env.isCI, isA<bool>());
    });

    test('an empty variable is unset for get, getOrNull, has and parse', () {
      Env.set('AUDIT_EMPTY', '');
      expect(Env.getOrNull('AUDIT_EMPTY'), isNull);
      expect(Env.has('AUDIT_EMPTY'), isFalse);
      expect(Env.get('AUDIT_EMPTY', or: 'd'), 'd');
      expect(() => Env.get('AUDIT_EMPTY'), throwsStateError);
      Env.parse('AUDIT_EMPTY=filled');
      expect(Env.get('AUDIT_EMPTY'), 'filled');
    });

    test('Env.parse without override preserves a value loaded earlier', () {
      Env.parse('AUDIT_FIRST_WINS=first');
      Env.parse('AUDIT_FIRST_WINS=second');
      expect(Env.get('AUDIT_FIRST_WINS'), equals('first'));
      Env.parse('AUDIT_FIRST_WINS=third', override: true);
      expect(Env.get('AUDIT_FIRST_WINS'), equals('third'));
    });
  });

  group('Duration Utilities', () {
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

    test('Duration.jitter adds variance within bounds', () {
      final base = 1000.ms;
      for (var i = 0; i < 20; i++) {
        final jittered = base.jittered(0.2);
        expect(jittered.inMilliseconds, greaterThanOrEqualTo(800));
        expect(jittered.inMilliseconds, lessThanOrEqualTo(1200));
      }
    });
  });

  group('edge cases', () {
    test('.env: a quoted value spans lines; a line with no key is skipped', () {
      final parsed = Env.parse(
        'KEY="-----BEGIN\nabc\n-----END"\n=novalue\nexport\tTAB=1\nOPEN="never closes\nNEXT=2\nS=\'a\nb\'',
        override: true,
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
      final parsed = Env.parse('F="open\nG=1\nH="tab" x\nL="  first   \n  next"\nS=\'a\nT=\'b\' c', override: true);
      expect(parsed, {'F': '"open', 'G': '1', 'H': 'tab', 'L': '  first   \n  next', 'S': "'a", 'T': 'b'});
    });

    test('humanBytes picks the unit after rounding', () {
      expect(1048575.humanBytes, '1.0 MB');
      expect(1023.7.humanBytes, '1.0 KB');
      expect((1024 * 1024 * 1024 - 1).humanBytes, '1.0 GB');
      expect(1023.humanBytes, '1023 B');
    });

    test('humanBytes and humanized scale a negative value and keep its sign', () {
      expect((-1536).humanBytes, '-1.5 KB');
      expect((-512).humanBytes, '-512 B');
      expect((-90).s.humanized, '-1m 30s');
      expect((-350).ms.humanized, '-350ms');
    });

    test('FileBridge writes a file whose name leaves no room for a temporary name', () async {
      final dir = Directory.systemTemp.createTempSync('tk_long');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/${'a' * 245}.txt';
      await FileBridge.write(path, [1]);
      FileBridge.writeSync(path, [1, 2]);
      expect(File(path).readAsBytesSync(), [1, 2]);
      expect(dir.listSync(), hasLength(1));
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
      expect(Env.get('REPEAT_KEY'), 'second');
    });

    test('jittered keeps sub-millisecond precision', () {
      const d = Duration(microseconds: 900);
      expect(d.jittered(0), d);
    });

    test('CancelToken: registering same function twice gives independent slots', () {
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

    test('CancelToken: throwing listener routes to Zone uncaught error', () {
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

    test('Io.width: printable ASCII is its length; escapes, controls and DEL take the full path', () {
      expect(Io.width(''), 0);
      expect(Io.width('plain ascii, 123 ~!'), 19);
      expect(Io.width('\x1b[31mred\x1b[0m'), 3);
      expect(Io.width('a\tb'), 2);
      expect(Io.width('a\x7fb'), 2);
      expect(Io.width('café'), 4);
    });

    test('Io.width measures wide dingbats and skin tone modifiers correctly', () {
      expect(Io.width('✅'), 2);
      expect(Io.width('❌'), 2);
      expect(Io.width('☕'), 2);
      expect(Io.width('⚡'), 2);
      // '👍' is 2, skin tone modifier is 0, so '👍🏽' is 2
      expect(Io.width('👍🏽'), 2);
    });

    test('Io.width counts a ZWJ sequence as one glyph, and truncate never splits one', () {
      expect(Io.width('👨‍👩‍👧'), 2);
      expect(Io.width('a👩‍💻b'), 4);
      expect(Io.truncate('👨‍👩‍👧 family photo', 5), '👨‍👩‍👧...');
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
}

Object _boom() => throw StateError('boom');
