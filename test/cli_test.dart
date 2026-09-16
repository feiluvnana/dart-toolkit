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
          .option('verbose', flag: true, abbr: 'v')
          .subcommand('scrape', description: 'Scrape URLs')
          .option('concurrency', abbr: 'c', numeric: true, defaultTo: '4')
          .option('out', abbr: 'o', defaultTo: 'dist')
          .action((ctx) {
            executed = true;
            isVerbose = ctx.flag('verbose');
            parsedConcurrency = ctx.number('concurrency');
            parsedOut = ctx.option('out');
          });

      await cli.run(['fetch', 'scrape', '-c', '8', '--out', 'output', '--verbose']);

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

    test('ConsoleProgress truncates long labels to fit within terminal width', () {
      final progress = Console.progress(556, message: 'Audio Tracks', terminalColumns: 80);
      final line = progress.formatLine(
        'DISC.21／ LB!キャラクターソング・semicrystalline.Little Busters! original arrange album・Rockstar Busters! 他より #11',
      );

      // Line length in terminal columns must not exceed terminalColumns - 1
      expect(line.length, lessThanOrEqualTo(80));
      expect(line.contains('...'), isTrue);
      expect(line.startsWith('  Audio Tracks: ['), isTrue);
    });

    test('ConsoleMultiProgress formats header and multiple worker slots correctly', () {
      final multi = Console.multiProgress(10, slots: 3, message: 'Downloading Assets', terminalColumns: 80);

      // Initial state (all slots idle)
      var lines = multi.formatLines();
      expect(lines.length, equals(4)); // 1 header + 3 slots
      expect(lines[0], contains('Downloading Assets: [--------------------] 0% (0/10)'));
      expect(lines[1], contains('├─ (idle)'));
      expect(lines[2], contains('├─ (idle)'));
      expect(lines[3], contains('└─ (idle)'));

      // Update active slots
      multi.updateTask('task1', label: 'song01.flac', ratio: 0.5, received: 500000, total: 1000000);
      multi.updateTask('task2', label: 'song02.flac', ratio: 0.8, received: 800000, total: 1000000);
      multi.tick(1);

      lines = multi.formatLines();
      expect(lines[0], contains('10% (1/10)'));
      expect(lines[1], contains('song01.flac'));
      expect(lines[1], contains('50%'));
      expect(lines[1], contains('488.3 KB/976.6 KB'));
      expect(lines[2], contains('song02.flac'));
      expect(lines[2], contains('80%'));
      expect(lines[3], contains('└─ (idle)'));

      // Update from BatchDownloadProgress
      multi.update(
        BatchDownloadProgress(
          completed: 2,
          total: 10,
          newDownloads: 2,
          current: DownloadProgress(
            url: Uri.parse('http://example.com/song03.flac'),
            path: Path('song03.flac'),
            received: 300000,
            total: 600000,
            isDone: true,
          ),
        ),
      );

      lines = multi.formatLines();
      expect(lines[0], contains('20% (2/10)'));
      expect(lines.any((l) => l.contains('song03.flac') && l.contains('[done]')), isTrue);

      expect(() => multi.done('All assets completed.'), returnsNormally);
    });

    test('choice accepts valid options and throws ArgumentError on invalid value', () async {
      final cli = Cli();
      String? chosenFormat;

      cli.command('build').choice('format', ['debug', 'release'], defaultTo: 'debug').action((ctx) {
        chosenFormat = ctx.option('format');
      });

      // Valid option
      await cli.run(['build', '--format', 'release']);
      expect(chosenFormat, equals('release'));

      // Default value when omitted
      await cli.run(['build']);
      expect(chosenFormat, equals('debug'));

      // Invalid value throws ArgumentError
      expect(() => cli.run(['build', '--format', 'invalid_mode']), throwsA(isA<ArgumentError>()));
    });

    test('flag and number helpers configure and validate correctly', () async {
      final cli = Cli();
      bool? isDryRun;
      int? concurrency;

      cli.command('serve').flag('dry-run', abbr: 'd').number('concurrency', abbr: 'c', defaultTo: 4).action((ctx) {
        isDryRun = ctx.flag('dry-run');
        concurrency = ctx.number('concurrency');
      });

      // Shorthand abbreviations
      await cli.run(['serve', '-d', '-c', '8']);
      expect(isDryRun, isTrue);
      expect(concurrency, equals(8));

      // Defaults
      await cli.run(['serve']);
      expect(isDryRun, isFalse);
      expect(concurrency, equals(4));

      // Invalid numeric option throws ArgumentError
      expect(() => cli.run(['serve', '-c', 'not_a_number']), throwsA(isA<ArgumentError>()));
    });
  });
}
