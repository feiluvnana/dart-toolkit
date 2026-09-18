import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

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

  group('Logger levels', () {
    late StringBuffer out;
    late StringBuffer err;

    setUp(() {
      out = StringBuffer();
      err = StringBuffer();
      ConsoleIo.out = out;
      ConsoleIo.err = err;
      Ansi.enabled = false;
    });

    tearDown(() {
      ConsoleIo.reset();
      Ansi.enabled = null;
      Logger.level = LogLevel.info;
    });

    test('default level emits info and above but not debug', () {
      Logger.debug('nope');
      Logger.info('yes');
      Logger.warn('warned');
      Logger.error('boom');

      expect(out.toString(), isNot(contains('nope')));
      expect(out.toString(), contains('yes'));
      expect(err.toString(), contains('warned'));
      expect(err.toString(), contains('boom'));
    });

    test('debug level includes verbose diagnostics', () {
      Logger.level = LogLevel.debug;
      Logger.debug('verbose detail');
      expect(out.toString(), contains('verbose detail'));
    });

    test('warn level suppresses info and ok', () {
      Logger.level = LogLevel.warn;
      Logger.info('hidden');
      Logger.ok('hidden too');
      Logger.stages(2)('hidden step');
      Logger.warn('visible');

      expect(out.toString(), isNot(contains('hidden')));
      expect(err.toString(), contains('visible'));
    });

    test('silent suppresses everything including errors', () {
      Logger.level = LogLevel.silent;
      Logger.info('x');
      Logger.error('y');
      expect(out.toString(), isEmpty);
      expect(err.toString(), isEmpty);
    });

    test('silenced() restores the previous level afterwards, async bodies included', () async {
      Logger.level = LogLevel.info;
      final result = await Logger.silenced(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        Logger.info('muted');
        return 42;
      });
      expect(result, equals(42));
      expect(out.toString(), isEmpty);
      expect(Logger.level, equals(LogLevel.info));

      Logger.info('audible');
      expect(out.toString(), contains('audible'));
    });
  });

  group('Prompt flexibility', () {
    late StringBuffer out;

    setUp(() {
      out = StringBuffer();
      ConsoleIo.out = out;
      Ansi.enabled = false;
    });

    tearDown(() {
      ConsoleIo.reset();
      Ansi.enabled = null;
    });

    /// Feeds [lines] to prompts, then end-of-input.
    void feed(List<String> lines) {
      final queue = List<String>.from(lines);
      ConsoleIo.input = () => queue.isEmpty ? null : queue.removeAt(0);
    }

    test('select works with non-String choices via display', () {
      feed(['2']);
      final servers = [(name: 'alpha', region: 'us'), (name: 'beta', region: 'eu')];
      final picked = Prompt.select('Target', servers, display: (s) => '${s.name} (${s.region})');
      expect(picked.name, equals('beta'));
      expect(out.toString(), contains('alpha (us)'));
      expect(out.toString(), contains('beta (eu)'));
    });

    test('select infers String choices exactly as before', () {
      feed(['3']);
      final env = Prompt.select('Environment', ['dev', 'staging', 'prod']);
      expect(env, equals('prod'));
    });

    test('select returns the default on empty input', () {
      feed(['']);
      final env = Prompt.select('Environment', ['dev', 'staging'], defaultTo: 'staging');
      expect(env, equals('staging'));
      expect(out.toString(), contains('(default)'));
    });

    test('ask re-prompts until validate accepts', () {
      feed(['abc', '8080']);
      final port = Prompt.ask('Port', validate: (v) => int.tryParse(v) == null ? 'Must be a number' : null);
      expect(port, equals('8080'));
      expect(out.toString(), contains('Must be a number'));
    });

    test('ask falls back to the default at end of input instead of hanging', () {
      ConsoleIo.input = () => null; // immediate end of input
      final value = Prompt.ask('Name', defaultTo: 'fallback');
      expect(value, equals('fallback'));
    });

    test('required ask throws rather than looping when input is exhausted', () {
      ConsoleIo.input = () => null; // immediate end of input
      expect(() => Prompt.ask('Name', required: true), throwsA(isA<StateError>()));
    });
  });

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

  group('cli', () {
    test('--version prints name and version', () async {
      final out = StringBuffer();
      ConsoleIo.out = out;
      try {
        await (Cli(name: 'demo', version: '1.2.3')..action((_) => fail('not run'))).run(['--version']);
        expect(out.toString().trim(), 'demo 1.2.3');
      } finally {
        ConsoleIo.reset();
      }
    });
  });

  group('cli', () {
    test('a ✓ cell is one column wide, so table borders stay aligned', () {
      final buf = StringBuffer();
      ConsoleIo.out = buf;
      Ansi.enabled = false;
      try {
        Console.table(
          headers: ['a', 'b'],
          rows: [
            ['✓ ok', 'x'],
            ['plain', 'y'],
          ],
        );
      } finally {
        ConsoleIo.reset();
        Ansi.enabled = null;
      }
      final widths = buf.toString().trimRight().split('\n').map((l) => l.runes.length).toSet();
      expect(widths.length, equals(1));
    });

    test('Logger.warn goes to stderr with Logger.error', () {
      final err = StringBuffer();
      ConsoleIo.err = err;
      try {
        Logger.warn('careful');
      } finally {
        ConsoleIo.reset();
      }
      expect(err.toString(), contains('careful'));
    });
  });

  group('cli', () {
    test('an ArgumentError in the action is not a usage error', () async {
      final cli = CliCommand('demo')..action((ctx) => throw ArgumentError('bug in the action'));
      expect(() => cli.run([]), throwsA(isA<ArgumentError>()));
    });

    test('a usage error is a UsageException with the message', () async {
      final cli = CliCommand('demo')..number('n');
      expect(
        () => cli.run(['--n', 'x']),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('Invalid numeric value'))),
      );
    });

    test('ctx.cancel is cancelled when the action ends, and exit hooks run when it throws', () async {
      CancelToken? seen;
      var hookRan = false;
      onExit(() => hookRan = true);
      final cli = Cli(name: 'demo')
        ..action((ctx) {
          seen = ctx.cancel;
          expect(ctx.cancel.isCancelled, isFalse);
          throw StateError('bug');
        });
      await expectLater(cli.run([]), throwsStateError);
      expect(hookRan, isTrue);
      expect(seen!.isCancelled, isTrue);
    });
  });

  group('ConsoleIo seam', () {
    late StringBuffer out;

    setUp(() {
      out = StringBuffer();
      ConsoleIo.out = out;
    });

    tearDown(() {
      ConsoleIo.reset();
      Ansi.enabled = null;
      Env.remove('NO_COLOR');
    });

    test('captures subprocess output, not just Logger output', () async {
      Logger.ok('via Logger');
      await run('echo SUBPROCESS_MARKER');

      expect(out.toString(), contains('via Logger'));
      expect(out.toString(), contains('SUBPROCESS_MARKER'));
    });

    test('quiet: true still suppresses subprocess output', () async {
      final result = await run('echo QUIET_MARKER', quiet: true);

      expect(result.stdout, contains('QUIET_MARKER'));
      expect(out.toString(), isNot(contains('QUIET_MARKER')));
    });

    test('a redirected sink is never treated as a terminal', () {
      expect(ConsoleIo.isTerminal, isFalse);
      expect(ConsoleIo.columns, isNull);
    });

    test('a redirected sink disables ANSI unless explicitly overridden', () {
      expect(Ansi.enabled, isFalse);

      Ansi.enabled = true;
      expect(Ansi.enabled, isTrue);
    });

    test('Ansi resolves override, then NO_COLOR, then the sink', () {
      ConsoleIo.reset();

      // 1. An explicit override wins over everything.
      Ansi.enabled = true;
      Env.set('NO_COLOR', '1');
      expect(Ansi.enabled, isTrue, reason: 'explicit override beats NO_COLOR');

      // 2. With no override, NO_COLOR read from Env disables styling. The value
      //    lives in Env only -- Platform.environment never sees it -- so this
      //    pins Env as the source Ansi consults.
      Ansi.enabled = null;
      expect(Platform.environment.containsKey('NO_COLOR'), isFalse);
      expect(Env.has('NO_COLOR'), isTrue);
      expect(Ansi.enabled, isFalse);
    });

    test('ConsoleMultiProgress reports each completion without a terminal', () {
      final progress = Console.multiProgress(total: 3, slots: 2, message: 'files', columns: 80);

      var completed = 0;
      for (final name in ['a.txt', 'b.txt', 'c.txt']) {
        final path = Path('out/$name');
        final url = 'https://example.com/$name'.url;
        progress.report(
          BatchDownloadProgress(
            completed: completed,
            total: 3,
            written: completed,
            current: Downloading(url, path, received: 512, total: 1024),
          ),
        );
        completed++;
        progress.report(
          BatchDownloadProgress(
            completed: completed,
            total: 3,
            written: completed,
            current: Downloaded(url, path, 1024),
          ),
        );
      }
      progress.done('finished');

      final lines = out.toString().trim().split('\n');
      expect(lines.length, greaterThanOrEqualTo(4));
      for (final name in ['a.txt', 'b.txt', 'c.txt']) {
        expect(lines.where((l) => l.contains(name)).length, equals(1), reason: '\$name reported exactly once');
      }
      expect(lines.last, contains('finished'));
    });

    test('report() renders a BatchProgress without the caller restating its fields', () {
      final progress = Console.multiProgress(slots: 2, message: 'files', columns: 80);
      final url = 'https://example.com/a.txt'.url;
      final path = Path('out/a.txt');

      progress.report(
        BatchDownloadProgress(
          completed: 0,
          total: null,
          written: 0,
          current: Downloading(url, path, received: 512, total: 1024),
        ),
      );
      expect(progress.total, equals(0), reason: 'an open stream has no total yet');

      progress.report(BatchDownloadProgress(completed: 1, total: 2, written: 1, current: Downloaded(url, path, 1024)));
      expect(progress.total, equals(2), reason: 'total is revised as the source discovers work');

      progress.report(
        BatchDownloadProgress(completed: 2, total: 2, written: 1, current: DownloadSkipped(url, Path('out/b.txt'))),
      );
      progress.done('finished');

      final lines = out.toString().trim().split('\n');
      expect(lines.any((l) => l.contains('a.txt') && l.contains('[done]')), isTrue);
      expect(lines.any((l) => l.contains('b.txt') && l.contains('[skipped]')), isTrue);
    });

    test('ConsoleProgress without a terminal reports each new tenth, not each tick', () {
      final progress = Console.progress(3, message: 'files', columns: 80);
      progress
        ..tick()
        ..tick()
        ..tick();
      progress.done('finished');
      expect(out.toString().trim().split('\n').length, equals(4));

      out.clear();
      final fine = Console.progress(1000, message: 'steps', columns: 80);
      for (var i = 0; i < 1000; i++) {
        fine.tick();
      }
      fine.done();
      expect(out.toString().trim().split('\n').length, lessThanOrEqualTo(11), reason: 'one line per tenth');
    });
  });
}
