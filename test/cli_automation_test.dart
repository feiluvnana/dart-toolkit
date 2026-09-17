import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('CLI Automation: Spinner & Lifecycle', () {
    test('Console.spin runs action and returns result', () async {
      final res = await Console.spin('Processing task', () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return 42;
      });
      expect(res, equals(42));
    });

    test('Console.spin rethrows on error', () async {
      expect(
        () => Console.spin('Failing task', () async {
          throw Exception('Task error');
        }),
        throwsA(isA<Exception>()),
      );
    });

    test('Console.spinner controls start, success, fail, info', () {
      final spinner = Console.spinner('Custom spinner');
      expect(() => spinner.start(), returnsNormally);
      expect(() => spinner.stop('Info note'), returnsNormally);
      expect(() => spinner.succeed('Done'), returnsNormally);
      expect(() => spinner.fail('Error'), returnsNormally);
    });

    test('onExit registers hook safely', () {
      expect(() => onExit(() {}), returnsNormally);
    });
  });
}
