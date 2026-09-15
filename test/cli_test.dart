import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('CLI', () {
    test('command with option, subcommand, and action execution', () async {
      final cli = Cli();
      var executed = false;
      String? parsedOut;
      int? parsedConcurrency;
      bool? isVerbose;

      cli
          .command('fetch', description: 'Fetch data')
          .option('verbose', flag: true)
          .subcommand('scrape', description: 'Scrape URLs')
          .option('concurrency', abbreviated: true, numeric: true, defaultTo: '4')
          .option('out', abbreviated: true, defaultTo: 'dist')
          .action((ctx) {
            executed = true;
            isVerbose = ctx.flag('verbose');
            parsedConcurrency = ctx.number('concurrency');
            parsedOut = ctx.option('out');
          });

      await cli.run(['fetch', 'scrape', '-concurrency', '8', '-out', 'output', '--verbose']);

      expect(executed, isTrue);
      expect(isVerbose, isTrue);
      expect(parsedConcurrency, equals(8));
      expect(parsedOut, equals('output'));
    });

    test('Logger methods execute cleanly', () {
      expect(() => Logger.step(1, 3, 'Processing...'), returnsNormally);
      expect(() => Logger.ok('Done'), returnsNormally);
      expect(() => Logger.info('Info note'), returnsNormally);
      expect(() => Logger.warn('Warning note'), returnsNormally);
      expect(() => Logger.error('Error note'), returnsNormally);
    });

    test('Console table, rule, and progress execute cleanly', () {
      expect(() => Console.rule('Summary'), returnsNormally);
      expect(
        () => Console.table(
          headers: ['Name', 'Value'],
          rows: [
            ['Alpha', 10],
            ['Beta', 20],
          ],
        ),
        returnsNormally,
      );

      final progress = Console.progress(10, message: 'Tasks');
      progress.tick(5, 'Halfway');
      progress.tick(5, 'Completed');
      progress.done('Finished');
    });
  });
}
