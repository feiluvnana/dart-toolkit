import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Core Either', () {
    test('Left and Right properties and pattern matching', () {
      final Either<String, int> right = Right(42);
      final Either<String, int> left = Left('error');

      expect(right.isRight, isTrue);
      expect(right.isLeft, isFalse);
      expect(right.rightOrNull, equals(42));
      expect(right.leftOrNull, isNull);

      expect(left.isLeft, isTrue);
      expect(left.isRight, isFalse);
      expect(left.leftOrNull, equals('error'));
      expect(left.rightOrNull, isNull);

      // fold
      expect(right.fold((l) => 'L: $l', (r) => 'R: $r'), equals('R: 42'));
      expect(left.fold((l) => 'L: $l', (r) => 'R: $r'), equals('L: error'));

      // map
      final mappedRight = right.mapRight((r) => r * 2);
      expect(mappedRight, equals(const Right<String, int>(84)));

      final mappedLeft = left.mapRight((r) => r * 2);
      expect(mappedLeft, equals(const Left<String, int>('error')));

      // mapLeft
      final leftMapped = left.mapLeft((l) => l.toUpperCase());
      expect(leftMapped, equals(const Left<String, int>('ERROR')));
    });

    test('Either.tryCatchSync and Either.tryCatch', () async {
      final syncSuccess = Either.tryCatchSync(() => 10 + 5);
      expect(syncSuccess, equals(const Right<Object, int>(15)));

      final syncFailure = Either.tryCatchSync<int>(() => throw FormatException('bad'));
      expect(syncFailure.isLeft, isTrue);
      expect(syncFailure.leftOrNull, isA<FormatException>());

      final asyncSuccess = await Either.tryCatch(() async => 'hello');
      expect(asyncSuccess, equals(const Right<Object, String>('hello')));

      final asyncFailure = await Either.tryCatch<String>(() async => throw StateError('failed'));
      expect(asyncFailure.isLeft, isTrue);
      expect(asyncFailure.leftOrNull, isA<StateError>());

      // tryCatch also accepts a synchronous closure.
      expect(await Either.tryCatch(() => 1), equals(const Right<Object, int>(1)));
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

    test('JsonPath throws on unsupported slice and filter expressions', () {
      final jsonDoc = JsonDocument([1, 2, 3, 4, 5]);
      // Slices must throw UnsupportedError
      expect(() => jsonDoc.$(r'$.a[1:3]'), throwsA(isA<UnsupportedError>()));
      // Filters must throw UnsupportedError
      expect(() => jsonDoc.$(r'$.a[?(@.v > 20)]'), throwsA(isA<UnsupportedError>()));
      // Invalid unclosed brackets
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

    test('Either.tryCatchSync captures any thrown error, whatever its type', () {
      final parsed = Either.tryCatchSync(() => int.parse('not_a_num'));
      expect(parsed.isLeft, isTrue);
      expect(parsed.leftOrNull, isA<FormatException>());

      // Narrowing happens afterwards, so no error type can be unrepresentable.
      final narrowed = Either.tryCatchSync<int>(() => throw StateError('boom')).mapLeft((e) => FormatException('\$e'));
      expect(narrowed.isLeft, isTrue);
      expect(narrowed.leftOrNull, isA<FormatException>());
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
      final outcome = await Either.tryCatch(() async => _boom());
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
    tearDown(() {
      Env.reset();
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
      expect(Env.require('TEST_VAR_XYZ'), equals('12345'));
      expect(Env.has('TEST_VAR_XYZ'), isTrue);
      expect(Env.all().containsKey('TEST_VAR_XYZ'), isTrue);
    });

    test('Env.set and Env.get work in-memory', () {
      expect(Env.has('MY_CUSTOM_CONFIG'), isFalse);
      Env.set('MY_CUSTOM_CONFIG', 'enabled');
      expect(Env.has('MY_CUSTOM_CONFIG'), isTrue);
      expect(Env.get('MY_CUSTOM_CONFIG'), equals('enabled'));
    });

    test('Env.require throws StateError when missing', () {
      expect(() => Env.require('DEFINITELY_MISSING_VAR_9999'), throwsA(isA<StateError>()));
    });

    test('Env.get is null when missing; ?? supplies the fallback', () {
      expect(Env.get('NON_EXISTENT_VAR') ?? 'fallback_val', equals('fallback_val'));
      expect(Env.isCI, isA<bool>());
    });

    test('Env.parse without override preserves a value loaded earlier', () {
      Env.remove('AUDIT_FIRST_WINS');
      Env.parse('AUDIT_FIRST_WINS=first');
      Env.parse('AUDIT_FIRST_WINS=second');
      expect(Env.get('AUDIT_FIRST_WINS'), equals('first'));
      Env.parse('AUDIT_FIRST_WINS=third', override: true);
      expect(Env.get('AUDIT_FIRST_WINS'), equals('third'));
      Env.remove('AUDIT_FIRST_WINS');
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
