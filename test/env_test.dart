import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Environment & .env utilities', () {
    tearDown(() {
      Env.clear();
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
}
