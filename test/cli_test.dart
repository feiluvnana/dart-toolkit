import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

/// A [TaskProgress] for tests, so the renderer is driven the way `report` is in a program.
class _Task implements TaskProgress {
  @override
  final String taskId;
  @override
  final String label;
  @override
  final double? ratio;
  @override
  final int? received;
  @override
  final int? total;
  @override
  final String? status;
  @override
  final bool isDone;
  const _Task(this.taskId, this.label, this.ratio, this.received, this.total, this.status, this.isDone);
}

class _Batch implements BatchProgress {
  @override
  final int completed;
  @override
  final int? total;
  @override
  final TaskProgress current;
  const _Batch(this.completed, this.total, this.current);
}

_Task _task(String id, String label, double? ratio, int? received, int? total, {String? status, bool done = false}) =>
    _Task(id, label, ratio, received, total, status, done);
_Batch _batch(int completed, int? total, TaskProgress current) => _Batch(completed, total, current);

void main() {
  group('CLI', () {
    test('command with option, subcommand, and action execution', () async {
      final cli = Cli();
      var executed = false;
      String? parsedOut;
      int? parsedConcurrency;
      bool? isVerbose;

      cli.command(
        'fetch',
        description: 'Fetch data',
        build: (fetch) => fetch
          ..flag('verbose', abbr: 'v')
          ..command(
            'scrape',
            description: 'Scrape URLs',
            build: (scrape) => scrape
              ..number('concurrency', abbr: 'c', defaultTo: 4)
              ..option('out', abbr: 'o', defaultTo: 'dist')
              ..action((ctx) {
                executed = true;
                isVerbose = ctx.flag('verbose');
                parsedConcurrency = ctx.number('concurrency');
                parsedOut = ctx.option('out');
              }),
          ),
      );

      await cli.run(['fetch', 'scrape', '-c', '8', '--out', 'output', '--verbose']);

      expect(executed, isTrue);
      expect(isVerbose, isTrue);
      expect(parsedConcurrency, equals(8));
      expect(parsedOut, equals('output'));
    });

    test('option kinds are mutually exclusive and typed', () async {
      final cli = Cli();
      Object? rawNumber;

      cli.command(
        'build',
        build: (build) => build
          ..number('jobs', defaultTo: 4)
          ..flag('watch')
          ..choice('mode', ['debug', 'release'])
          ..option('out')
          ..action((ctx) => rawNumber = ctx.values['jobs']),
      );

      // Each declaration produces exactly one kind. The old shape let
      // flag: true and numeric: true coexist on one option.
      final build = cli.subcommands['build']!;
      expect(build.options['jobs'], isA<CliNumber>());
      expect(build.options['watch'], isA<CliFlag>());
      expect(build.options['mode'], isA<CliChoice>());
      expect(build.options['out'], isA<CliValue>());

      // A numeric option is parsed once, not re-parsed on every read.
      await cli.run(['build']);
      expect(rawNumber, isA<int>());
      expect(rawNumber, equals(4));

      await cli.run(['build', '--jobs', '9']);
      expect(rawNumber, equals(9));
    });

    test('Logger methods execute cleanly', () {
      expect(() => Logger.stages(3)('Processing...'), returnsNormally);
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
      final progress = Console.progress(556, message: 'Audio Tracks', columns: 80);
      final line = progress.formatLine(
        'DISC.21／ LB!キャラクターソング・semicrystalline.Little Busters! original arrange album・Rockstar Busters! 他より #11',
      );

      // Line length in terminal columns must not exceed terminalColumns - 1
      expect(line.length, lessThanOrEqualTo(80));
      expect(line.contains('...'), isTrue);
      expect(line.startsWith('  Audio Tracks: ['), isTrue);
    });

    test('ConsoleMultiProgress formats header and multiple worker slots correctly', () {
      final multi = Console.multiProgress(total: 10, slots: 3, message: 'Downloading Assets', columns: 80);

      // Initial state (all slots idle)
      var lines = multi.formatLines();
      expect(lines.length, equals(4)); // 1 header + 3 slots
      expect(lines[0], contains('Downloading Assets: [--------------------] 0% (0/10)'));
      expect(lines[1], contains('├─ (idle)'));
      expect(lines[2], contains('├─ (idle)'));
      expect(lines[3], contains('└─ (idle)'));

      // Update active slots
      multi.report(_batch(1, 10, _task('task1', 'song01.flac', 0.5, 500000, 1000000)));
      multi.report(_batch(1, 10, _task('task2', 'song02.flac', 0.8, 800000, 1000000)));

      lines = multi.formatLines();
      expect(lines[0], contains('10% (1/10)'));
      expect(lines[1], contains('song01.flac'));
      expect(lines[1], contains('50%'));
      expect(lines[1], contains('488.3 KB/976.6 KB'));
      expect(lines[2], contains('song02.flac'));
      expect(lines[2], contains('80%'));
      expect(lines[3], contains('└─ (idle)'));

      multi.report(_batch(2, 10, _task('song03.flac', 'song03.flac', 0.5, 300000, 600000, status: 'done', done: true)));

      lines = multi.formatLines();
      expect(lines[0], contains('20% (2/10)'));
      expect(lines.any((l) => l.contains('song03.flac') && l.contains('[done]')), isTrue);

      expect(() => multi.done('All assets completed.'), returnsNormally);
    });

    test('choice accepts valid options and throws UsageException on invalid value', () async {
      // CliCommand.run throws; Cli.run would turn the error into exit code 64.
      final cli = CliCommand('app');
      String? chosenFormat;

      cli.command(
        'build',
        build: (build) => build
          ..choice('format', ['debug', 'release'], defaultTo: 'debug')
          ..action((ctx) => chosenFormat = ctx.option('format')),
      );

      // Valid option
      await cli.run(['build', '--format', 'release']);
      expect(chosenFormat, equals('release'));

      // Default value when omitted
      await cli.run(['build']);
      expect(chosenFormat, equals('debug'));

      // Invalid value throws UsageException
      expect(() => cli.run(['build', '--format', 'invalid_mode']), throwsA(isA<UsageException>()));
    });

    test('flag and number helpers configure and validate correctly', () async {
      final cli = CliCommand('app');
      bool? isDryRun;
      int? concurrency;

      cli.command(
        'serve',
        build: (serve) => serve
          ..flag('dry-run', abbr: 'd')
          ..number('concurrency', abbr: 'c', defaultTo: 4)
          ..action((ctx) {
            isDryRun = ctx.flag('dry-run');
            concurrency = ctx.number('concurrency');
          }),
      );

      // Shorthand abbreviations
      await cli.run(['serve', '-d', '-c', '8']);
      expect(isDryRun, isTrue);
      expect(concurrency, equals(8));

      // Defaults
      await cli.run(['serve']);
      expect(isDryRun, isFalse);
      expect(concurrency, equals(4));

      // Invalid numeric option throws UsageException
      expect(() => cli.run(['serve', '-c', 'not_a_number']), throwsA(isA<UsageException>()));
    });

    test('CLI handles negative option values and double dash terminator properly', () async {
      final cli = Cli();
      int? offset;
      List<String>? rest;

      cli.command(
        'seek',
        build: (seek) => seek
          ..number('offset', abbr: 'o')
          ..action((ctx) {
            offset = ctx.numberOrNull('offset');
            rest = ctx.rest;
          }),
      );

      // Negative value with --offset
      await cli.run(['seek', '--offset', '-5', 'file.txt']);
      expect(offset, equals(-5));
      expect(rest, equals(['file.txt']));

      // Negative value with -o
      await cli.run(['seek', '-o', '-10', 'audio.flac']);
      expect(offset, equals(-10));
      expect(rest, equals(['audio.flac']));

      // Double dash terminator
      await cli.run(['seek', '--offset', '20', '--', '--not-an-option', '-x']);
      expect(offset, equals(20));
      expect(rest, equals(['--not-an-option', '-x']));
    });

    test('options before the subcommand, combined short flags and attached values parse', () async {
      final cli = CliCommand('app');
      bool? verbose;
      bool? dry;
      int? jobs;
      List<String>? rest;
      cli
        ..flag('verbose', abbr: 'v')
        ..flag('dry-run', abbr: 'd')
        ..number('jobs', abbr: 'j', defaultTo: 1)
        ..command(
          'build',
          build: (b) => b.action((ctx) {
            verbose = ctx.flag('verbose');
            dry = ctx.flag('dry-run');
            jobs = ctx.number('jobs');
            rest = ctx.rest;
          }),
        );

      await cli.run(['-v', 'build', '-dj4', 'target']);
      expect(verbose, isTrue);
      expect(dry, isTrue);
      expect(jobs, equals(4));
      expect(rest, equals(['target']));

      await cli.run(['build', '-vd', '--jobs=2']);
      expect(verbose, isTrue);
      expect(dry, isTrue);
      expect(jobs, equals(2));
    });

    test('--help as an option value or after -- is a value, not a request for help', () async {
      String? token;
      final out = StringBuffer();
      ConsoleIo.out = out;
      try {
        final cli = CliCommand('app')
          ..option('token')
          ..action((ctx) => token = ctx.option('token'));
        await cli.run(['--token', '--help']);
        expect(token, equals('--help'));
        expect(out.toString(), isNot(contains('Usage')));

        await cli.run(['--help']);
        expect(out.toString(), contains('Usage'));
      } finally {
        ConsoleIo.reset();
      }
    });

    test('a choice default outside the choices fails at declaration', () {
      expect(() => CliCommand('app').choice('mode', ['a', 'b'], defaultTo: 'c'), throwsArgumentError);
    });

    test('option() and number() are non-null; the OrNull forms are for absent optionals', () async {
      String? name;
      int? port;
      Object? error;
      final cli = CliCommand('app')
        ..option('name')
        ..number('port')
        ..action((ctx) {
          name = ctx.optionOrNull('name');
          port = ctx.numberOrNull('port');
          try {
            ctx.option('name');
          } catch (e) {
            error = e;
          }
        });
      await cli.run([]);
      expect(name, isNull);
      expect(port, isNull);
      expect(error, isA<StateError>());
    });

    test('CLI subcommand inherits option defaults from parent hierarchy', () async {
      final cli = Cli();
      String? parentFmt;
      String? subFmt;

      cli
          .option('format', defaultTo: 'all')
          .command('download', build: (sub) => sub.action((ctx) => subFmt = ctx.option('format')))
          .action((ctx) => parentFmt = ctx.option('format'));

      // Parent sees default
      await cli.run([]);
      expect(parentFmt, equals('all'));

      // Subcommand sees parent default
      await cli.run(['download']);
      expect(subFmt, equals('all'));
    });

    test('ConsoleIo sink overrides capture output cleanly', () {
      final outBuffer = StringBuffer();
      final errBuffer = StringBuffer();
      ConsoleIo.out = outBuffer;
      ConsoleIo.err = errBuffer;

      try {
        Logger.info('Hello from Logger');
        Logger.error('Oops from Logger');
        expect(outBuffer.toString(), contains('Hello from Logger'));
        expect(errBuffer.toString(), contains('Oops from Logger'));
      } finally {
        ConsoleIo.reset();
      }
    });

    test('a required option is enforced at parse time', () async {
      String? token;
      final cli = CliCommand('app')
        ..option('token', abbr: 't', required: true, description: 'API token')
        ..action((ctx) => token = ctx.option('token'));

      await cli.run(['--token', 'abc']);
      expect(token, equals('abc'));

      expect(
        () => cli.run([]),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('Missing required option'))),
      );

      // Required is also enforced from an ancestor command, and shows up in help.
      final nested = CliCommand('app')
        ..number('port', required: true)
        ..command('serve', build: (serve) => serve..action((_) {}));
      expect(() => nested.run(['serve']), throwsA(isA<UsageException>()));
    });

    test('a declared default reaches the context with no read-site argument', () async {
      String? format;
      int? workers;

      final cli = Cli()
        ..choice('format', ['mp3', 'all'], defaultTo: 'all')
        ..number('workers', defaultTo: 4)
        ..action((ctx) {
          format = ctx.option('format');
          workers = ctx.number('workers');
        });

      await cli.run([]);
      expect(format, equals('all'));
      expect(workers, equals(4));
    });

    test('exit hooks are awaited, async ones included', () async {
      var asyncHookFinished = false;
      final unreg = onExit(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        asyncHookFinished = true;
      });

      await runExitHooks();
      expect(asyncHookFinished, isTrue);
      unreg();
    });

    test('onExit manages multiple hooks and execution', () async {
      var hook1Executed = false;
      var hook2Executed = false;

      final unreg1 = onExit(() => hook1Executed = true);
      final unreg2 = onExit(() => hook2Executed = true);

      await runExitHooks();
      expect(hook1Executed, isTrue);
      expect(hook2Executed, isTrue);

      unreg1();
      unreg2();
    });
  });

  group('ANSI composition', () {
    tearDown(() => Ansi.enabled = null);

    test('nested styles reopen after an inner reset', () {
      Ansi.enabled = true;
      final composed = '${'a'.red}b';
      expect(composed.bold, equals('\x1B[1m\x1B[31ma\x1B[0m\x1B[1mb\x1B[0m'));
      expect(Ansi.strip(composed.bold), equals('ab'));
    });

    test('styling is a no-op when ANSI is disabled', () {
      Ansi.enabled = false;
      expect('${'a'.red}b'.bold, equals('ab'));
    });
  });
}
