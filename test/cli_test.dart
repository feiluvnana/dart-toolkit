import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

enum Mode { debug, release }

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

    test('Console.spin renders the done and failed lines', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      Io.out = out;
      Io.err = err;
      addTearDown(Io.reset);

      await Console.spin('Working', () async => 1, done: 'Finished');
      await expectLater(
        Console.spin('Working', () async => throw Exception('nope'), failed: 'Gave up'),
        throwsA(isA<Exception>()),
      );

      expect(Io.stripAnsi(out.toString()), contains('Finished'));
      expect(Io.stripAnsi(err.toString()), contains('Gave up'));
    });

    test('Console.spinner is a handle the caller ends itself', () async {
      final out = StringBuffer();
      Io.out = out;
      addTearDown(Io.reset);

      final spinner = Console.spinner('Connecting');
      expect(spinner.isSpinning, isTrue);
      spinner.text = 'Fetching the index';
      expect(spinner.text, equals('Fetching the index'));
      spinner.succeed('index ready');

      expect(spinner.isSpinning, isFalse);
      expect(Io.stripAnsi(out.toString()), contains('index ready'));
      // A second ending is not a second line.
      spinner.fail('ignored');
      expect(Io.stripAnsi(out.toString()), isNot(contains('ignored')));
    });

    test('a spinner ends on stderr when it fails or warns', () {
      final out = StringBuffer();
      final err = StringBuffer();
      Io.out = out;
      Io.err = err;
      addTearDown(Io.reset);

      Console.spinner('One').fail('broke');
      Console.spinner('Two').warn('careful');
      Console.spinner('Three').stop();

      expect(Io.stripAnsi(err.toString()), contains('broke'));
      expect(Io.stripAnsi(err.toString()), contains('careful'));
      // stop() ends it with no final line: without a terminal each spinner still announces
      // itself when it starts, so what `stop` owes is the absence of an ending, not silence.
      expect(Io.stripAnsi(out.toString()), isNot(contains('✓')));
      expect(Io.stripAnsi(out.toString()), contains('Three...'));
    });

    test('SpinnerStyle takes frames of its own', () {
      const pulse = SpinnerStyle(['a', 'b'], interval: Duration(milliseconds: 10));
      expect(pulse.frames, equals(['a', 'b']));
      expect(SpinnerStyle.braille.frames.first, equals('⠋'));
      expect(SpinnerStyle.braille.frames, hasLength(10));

      final out = StringBuffer();
      Io.out = out;
      addTearDown(Io.reset);
      // Without a terminal the first frame is what gets written.
      Console.spinner('Waiting', style: pulse).stop();
      expect(Io.stripAnsi(out.toString()), contains('a Waiting'));
    });

    test('Console.writeln writes unlevelled, and ignores the log level', () {
      final out = StringBuffer();
      Io.out = out;
      addTearDown(Io.reset);

      Console.level = LogLevel.silent;
      addTearDown(() => Console.level = LogLevel.info);
      Console.info('levelled line');
      Console.writeln('bare line');

      final text = Io.stripAnsi(out.toString());
      expect(text, contains('bare line'));
      expect(text, isNot(contains('levelled line')));
    });

    test('onExit registers hook safely', () {
      expect(() => Lifecycle.onExit(() {}), returnsNormally);
    });
  });

  group('Console log levels', () {
    late StringBuffer out;
    late StringBuffer err;

    setUp(() {
      out = StringBuffer();
      err = StringBuffer();
      Io.out = out;
      Io.err = err;
      Io.color = false;
    });

    tearDown(() {
      Io.reset();
      Io.color = null;
      Console.level = LogLevel.info;
    });

    test('default level emits info and above but not debug', () {
      Console.debug('nope');
      Console.info('yes');
      Console.warn('warned');
      Console.error('boom');

      expect(out.toString(), isNot(contains('nope')));
      expect(out.toString(), contains('yes'));
      expect(err.toString(), contains('warned'));
      expect(err.toString(), contains('boom'));
    });

    test('debug level includes verbose diagnostics', () {
      Console.level = LogLevel.debug;
      Console.debug('verbose detail');
      expect(out.toString(), contains('verbose detail'));
    });

    test('warn level suppresses info and ok', () {
      Console.level = LogLevel.warn;
      Console.info('hidden');
      Console.ok('hidden too');
      Console.stages(2)('hidden step');
      Console.warn('visible');

      expect(out.toString(), isNot(contains('hidden')));
      expect(err.toString(), contains('visible'));
    });

    test('silent suppresses everything including errors', () {
      Console.level = LogLevel.silent;
      Console.info('x');
      Console.error('y');
      expect(out.toString(), isEmpty);
      expect(err.toString(), isEmpty);
    });

    test('silenced() restores the previous level afterwards, async bodies included', () async {
      Console.level = LogLevel.info;
      final result = await Console.silenced(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        Console.info('muted');
        return 42;
      });
      expect(result, equals(42));
      expect(out.toString(), isEmpty);
      expect(Console.level, equals(LogLevel.info));

      Console.info('audible');
      expect(out.toString(), contains('audible'));
    });
  });

  group('Prompt flexibility', () {
    late StringBuffer out;

    setUp(() {
      out = StringBuffer();
      Io.out = out;
      Io.color = false;
    });

    tearDown(() {
      Io.reset();
      Io.color = null;
    });

    /// Feeds [lines] to prompts, then end-of-input.
    void feed(List<String> lines) {
      final queue = List<String>.from(lines);
      Io.input = () => queue.isEmpty ? null : queue.removeAt(0);
    }

    test('select works with non-String choices via display', () {
      feed(['2']);
      final servers = [(name: 'alpha', region: 'us'), (name: 'beta', region: 'eu')];
      final picked = Console.select('Target', servers, display: (s) => '${s.name} (${s.region})');
      expect(picked.name, equals('beta'));
      expect(out.toString(), contains('alpha (us)'));
      expect(out.toString(), contains('beta (eu)'));
    });

    test('select infers String choices exactly as before', () {
      feed(['3']);
      final env = Console.select('Environment', ['dev', 'staging', 'prod']);
      expect(env, equals('prod'));
    });

    test('select returns the default on empty input', () {
      feed(['']);
      final env = Console.select('Environment', ['dev', 'staging'], or: 'staging');
      expect(env, equals('staging'));
      expect(out.toString(), contains('(default)'));
    });

    test('ask re-prompts until validate accepts', () {
      feed(['abc', '8080']);
      final port = Console.ask('Port', validate: (v) => int.tryParse(v) == null ? 'Must be a number' : null);
      expect(port, equals('8080'));
      expect(out.toString(), contains('Must be a number'));
    });

    test('ask falls back to the default at end of input instead of hanging', () {
      Io.input = () => null; // immediate end of input
      final value = Console.ask('Name', or: 'fallback');
      expect(value, equals('fallback'));
    });

    test('required ask throws rather than looping when input is exhausted', () {
      Io.input = () => null; // immediate end of input
      expect(() => Console.ask('Name', required: true), throwsA(isA<StateError>()));
    });
  });

  group('CLI', () {
    test('command with option, subcommand, and action execution', () async {
      var executed = false;
      String? parsedOut;
      int? parsedConcurrency;
      bool? isVerbose;

      final verbose = Opt.flag('verbose', abbr: 'v');
      final concurrency = Opt.number('concurrency', abbr: 'c').or(4);
      final out = Opt.text('out', abbr: 'o').or('dist');

      final cli = Cli(
        commands: [
          CliCommand(
            'fetch',
            description: 'Fetch data',
            options: [verbose],
            commands: [
              CliCommand(
                'scrape',
                description: 'Scrape URLs',
                options: [concurrency, out],
                handler: (ctx) {
                  executed = true;
                  isVerbose = ctx(verbose);
                  parsedConcurrency = ctx(concurrency);
                  parsedOut = ctx(out);
                },
              ),
            ],
          ),
        ],
      );

      await cli.run(['fetch', 'scrape', '-c', '8', '--out', 'output', '--verbose']);

      expect(executed, isTrue);
      expect(isVerbose, isTrue);
      expect(parsedConcurrency, equals(8));
      expect(parsedOut, equals('output'));
    });

    test('every option kind is behind Opt, including the flag', () async {
      final kinds = <CliOption<Object?>>[
        Opt.flag('f'),
        Opt.text('t'),
        Opt.number('n'),
        Opt.among('a', Mode.values),
        Opt.by('b', DateTime.parse),
      ];
      expect(kinds.map((o) => o.name), ['f', 't', 'n', 'a', 'b']);

      bool? flagged;
      final flag = Opt.flag('dry', abbr: 'd');
      await CliCommand('app', options: [flag], handler: (ctx) => flagged = ctx(flag)).run(['-d']);
      expect(flagged, isTrue);
    });

    test('an option carries its own type, so reading it needs no lookup or cast', () async {
      final jobs = Opt.number('jobs').or(4);
      final watch = Opt.flag('watch');
      final mode = Opt.among('mode', Mode.values);
      final out = Opt.text('out');

      Object? readJobs;
      Object? readWatch;
      Object? readMode;
      Object? readOut;

      final cli = Cli(
        commands: [
          CliCommand(
            'build',
            options: [jobs, watch, mode, out],
            handler: (ctx) {
              // Each of these is statically typed by its option; nothing here is a cast.
              final int j = ctx(jobs);
              final bool w = ctx(watch);
              final Mode? m = ctx(mode);
              final String? o = ctx(out);
              (readJobs, readWatch, readMode, readOut) = (j, w, m, o);
            },
          ),
        ],
      );

      // The default lives on the option, and a number is parsed once during parsing.
      await cli.run(['build']);
      expect(readJobs, isA<int>());
      expect(readJobs, equals(4));
      expect(readWatch, isFalse);
      expect(readMode, isNull);
      expect(readOut, isNull);

      await cli.run(['build', '--jobs', '9', '--watch', '--mode', 'release', '--out', 'dist']);
      expect(readJobs, equals(9));
      expect(readWatch, isTrue);
      expect(readMode, equals(Mode.release));
      expect(readOut, equals('dist'));
    });

    test('Console log methods execute cleanly', () {
      expect(() => Console.stages(3)('Processing...'), returnsNormally);
      expect(() => Console.ok('Done'), returnsNormally);
      expect(() => Console.info('Info note'), returnsNormally);
      expect(() => Console.warn('Warning note'), returnsNormally);
      expect(() => Console.error('Error note'), returnsNormally);
    });

    test('Console table, rule, and progress execute cleanly', () {
      expect(() => Console.rule('Summary'), returnsNormally);
      expect(
        () => Table.cells(
          ['Name', 'Value'],
          [
            ['Alpha', 10],
            ['Beta', 20],
          ],
        ).show(),
        returnsNormally,
      );

      final progress = Console.progress(10, message: 'Tasks');
      progress.tick(5, 'Halfway');
      progress.tick(5, 'Completed');
      progress.done('Finished');
    });

    test('ProgressBar truncates long labels to fit within terminal width', () {
      final progress = Console.progress(556, message: 'Audio Tracks', columns: 80);
      final line = progress.formatLine(
        'DISC.21／ LB!キャラクターソング・semicrystalline.Little Busters! original arrange album・Rockstar Busters! 他より #11',
      );

      // Line length in terminal columns must not exceed terminalColumns - 1
      expect(line.length, lessThanOrEqualTo(80));
      expect(line.contains('...'), isTrue);
      expect(line.startsWith('  Audio Tracks: ['), isTrue);
    });

    test('TaskBoard formats header and multiple worker slots correctly', () {
      final multi = Console.tasks(total: 10, slots: 3, message: 'Downloading Assets', columns: 80);

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
      String? chosenFormat;

      final format = Opt.among('format', Mode.values).or(Mode.debug);
      final cli = CliCommand(
        'app',
        commands: [
          CliCommand('build', options: [format], handler: (ctx) => chosenFormat = ctx(format).name),
        ],
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
      bool? isDryRun;
      int? concurrency;

      final dryRun = Opt.flag('dry-run', abbr: 'd');
      final workers = Opt.number('concurrency', abbr: 'c').or(4);

      final cli = CliCommand(
        'app',
        commands: [
          CliCommand(
            'serve',
            options: [dryRun, workers],
            handler: (ctx) {
              isDryRun = ctx(dryRun);
              concurrency = ctx(workers);
            },
          ),
        ],
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
      int? offset;
      List<String>? rest;

      final offsetOpt = Opt.number('offset', abbr: 'o');

      final cli = Cli(
        commands: [
          CliCommand(
            'seek',
            options: [offsetOpt],
            handler: (ctx) {
              offset = ctx(offsetOpt);
              rest = ctx.rest;
            },
          ),
        ],
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
      bool? verbose;
      bool? dry;
      int? jobs;
      List<String>? rest;
      final verboseOpt = Opt.flag('verbose', abbr: 'v');
      final dryOpt = Opt.flag('dry-run', abbr: 'd');
      final jobsOpt = Opt.number('jobs', abbr: 'j').or(1);
      final cli = CliCommand(
        'app',
        options: [verboseOpt, dryOpt, jobsOpt],
        commands: [
          CliCommand(
            'build',
            handler: (ctx) {
              verbose = ctx(verboseOpt);
              dry = ctx(dryOpt);
              jobs = ctx(jobsOpt);
              rest = ctx.rest;
            },
          ),
        ],
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
      Io.out = out;
      try {
        final tokenOpt = Opt.text('token');
        final cli = CliCommand('app', options: [tokenOpt], handler: (ctx) => token = ctx(tokenOpt));
        await cli.run(['--token', '--help']);
        expect(token, equals('--help'));
        expect(out.toString(), isNot(contains('Usage')));

        await cli.run(['--help']);
        expect(out.toString(), contains('Usage'));
      } finally {
        Io.reset();
      }
    });

    test('Opt.by parses whatever a function of your own returns', () async {
      final since = Opt.by('since', DateTime.parse);
      final port = Opt.by('port', Uri.parse).or(Uri.parse('http://localhost'));
      DateTime? parsed;
      Uri? url;

      final cli = CliCommand(
        'app',
        options: [since, port],
        handler: (ctx) {
          parsed = ctx(since);
          url = ctx(port);
        },
      );

      await cli.run(['--since', '2026-09-21', '--port', 'https://example.com']);
      expect(parsed, DateTime(2026, 9, 21));
      expect(url, Uri.parse('https://example.com'));

      await cli.run([]);
      expect(parsed, isNull, reason: 'no default, so the type is nullable');
      expect(url, Uri.parse('http://localhost'));

      // Anything the parser throws is a usage error, not a crash.
      expect(
        () => cli.run(['--since', 'not-a-date']),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('Invalid value "not-a-date"'))),
      );
    });

    test('a default outside the choices fails at declaration', () {
      expect(() => Opt.among('mode', Mode.values).or(Mode.debug), returnsNormally);
      expect(() => Opt.among('mode', ['a', 'b']).or('c'), throwsArgumentError);
    });

    test('an option with no default reads as null; one with a default cannot be null', () async {
      String? name;
      int? port;
      final nameOpt = Opt.text('name');
      final portOpt = Opt.number('port');
      final sizeOpt = Opt.number('size').or(10);

      final cli = CliCommand(
        'app',
        options: [nameOpt, portOpt, sizeOpt],
        handler: (ctx) {
          // `nameOpt` and `portOpt` are nullable types; `sizeOpt` is not, and needs no `!`.
          name = ctx(nameOpt);
          port = ctx(portOpt);
          expect(ctx(sizeOpt), equals(10));
          expect(ctx.given(nameOpt), isFalse);
        },
      );
      await cli.run([]);
      expect(name, isNull);
      expect(port, isNull);
    });

    test('CLI subcommand inherits option defaults from parent hierarchy', () async {
      String? parentFmt;
      String? subFmt;

      final format = Opt.text('format').or('all');
      final cli = Cli(
        options: [format],
        commands: [CliCommand('download', handler: (ctx) => subFmt = ctx(format))],
        handler: (ctx) => parentFmt = ctx(format),
      );

      // Parent sees default
      await cli.run([]);
      expect(parentFmt, equals('all'));

      // Subcommand sees parent default
      await cli.run(['download']);
      expect(subFmt, equals('all'));
    });

    test('Io sink overrides capture output cleanly', () {
      final outBuffer = StringBuffer();
      final errBuffer = StringBuffer();
      Io.out = outBuffer;
      Io.err = errBuffer;

      try {
        Console.info('Hello from Console');
        Console.error('Oops from Console');
        expect(outBuffer.toString(), contains('Hello from Console'));
        expect(errBuffer.toString(), contains('Oops from Console'));
      } finally {
        Io.reset();
      }
    });

    test('a required option is enforced at parse time', () async {
      String? token;
      final tokenOpt = Opt.text('token', abbr: 't', description: 'API token').required();
      final cli = CliCommand('app', options: [tokenOpt], handler: (ctx) => token = ctx(tokenOpt));

      await cli.run(['--token', 'abc']);
      expect(token, equals('abc'));

      expect(
        () => cli.run([]),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('Missing required option'))),
      );

      // Required is also enforced from an ancestor command, and shows up in help.
      final nested = CliCommand(
        'app',
        options: [Opt.number('port').required()],
        commands: [CliCommand('serve', handler: (_) {})],
      );
      expect(() => nested.run(['serve']), throwsA(isA<UsageException>()));
    });

    test('a declared default reaches the context with no read-site argument', () async {
      String? format;
      int? workers;
      final formatOpt = Opt.among('format', ['mp3', 'all']).or('all');
      final workersOpt = Opt.number('workers').or(4);

      final cli = Cli(
        options: [formatOpt, workersOpt],
        handler: (ctx) {
          format = ctx(formatOpt);
          workers = ctx(workersOpt);
        },
      );

      await cli.run([]);
      expect(format, equals('all'));
      expect(workers, equals(4));
    });

    test('exit listeners are awaited, async ones included', () async {
      var asyncHookFinished = false;
      Lifecycle.onExit(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        asyncHookFinished = true;
      });
      // Cli.run fires the listeners in its finally, which is the only public way in now
      // that there is no third spelling for "run them".
      await Cli(name: 'demo', handler: (_) {}).run([]);
      expect(asyncHookFinished, isTrue);
    });

    test('onExit runs every listener, in order, and each returns its own removal', () async {
      final order = <int>[];
      Lifecycle.onExit(() => order.add(1));
      final dropSecond = Lifecycle.onExit(() => order.add(2));
      Lifecycle.onExit(() => order.add(3));
      dropSecond();

      await Cli(name: 'demo', handler: (_) {}).run([]);
      expect(order, [1, 3], reason: 'registration order, and the removed one stayed out');
    });

    test('onExit(null) forgets every listener', () async {
      var ran = false;
      Lifecycle.onExit(() => ran = true);
      expect(Lifecycle.onExit(null), returnsNormally, reason: 'answers a no-op, not null');
      await Cli(name: 'demo', handler: (_) {}).run([]);
      expect(ran, isFalse);
    });
  });

  group('ANSI composition', () {
    tearDown(() => Io.color = null);

    test('nested styles reopen after an inner reset', () {
      Io.color = true;
      final composed = '${'a'.red}b';
      expect(composed.bold, equals('\x1B[1m\x1B[31ma\x1B[0m\x1B[1mb\x1B[0m'));
      expect(Io.stripAnsi(composed.bold), equals('ab'));
    });

    test('styling is a no-op when ANSI is disabled', () {
      Io.color = false;
      expect('${'a'.red}b'.bold, equals('ab'));
    });
  });

  group('cli', () {
    test('--version prints name and version', () async {
      final out = StringBuffer();
      Io.out = out;
      try {
        await Cli(name: 'demo', version: '1.2.3', handler: (_) => fail('not run')).run(['--version']);
        expect(out.toString().trim(), 'demo 1.2.3');
      } finally {
        Io.reset();
      }
    });
  });

  group('cli', () {
    test('a ✓ cell is one column wide, so table borders stay aligned', () {
      final buf = StringBuffer();
      Io.out = buf;
      Io.color = false;
      try {
        Table.cells(
          ['a', 'b'],
          [
            ['✓ ok', 'x'],
            ['plain', 'y'],
          ],
        ).show();
      } finally {
        Io.reset();
        Io.color = null;
      }
      final widths = buf.toString().trimRight().split('\n').map((l) => l.runes.length).toSet();
      expect(widths.length, equals(1));
    });

    test('Console.warn goes to stderr with Console.error', () {
      final err = StringBuffer();
      Io.err = err;
      try {
        Console.warn('careful');
      } finally {
        Io.reset();
      }
      expect(err.toString(), contains('careful'));
    });
  });

  group('cli', () {
    test('an ArgumentError in the action is not a usage error', () async {
      final cli = CliCommand('demo', handler: (ctx) => throw ArgumentError('bug in the action'));
      expect(() => cli.run([]), throwsA(isA<ArgumentError>()));
    });

    test('a usage error is a UsageException with the message', () async {
      final cli = CliCommand('demo', options: [Opt.number('n')]);
      expect(
        () => cli.run(['--n', 'x']),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('Invalid numeric value'))),
      );
    });

    test('ctx.cancel is cancelled when the action ends, and exit hooks run when it throws', () async {
      CancelToken? seen;
      var hookRan = false;
      Lifecycle.onExit(() => hookRan = true);
      final cli = Cli(
        name: 'demo',
        handler: (ctx) {
          seen = ctx.cancel;
          expect(ctx.cancel.isCancelled, isFalse);
          expect(Cancel.token, same(ctx.cancel), reason: 'the action runs inside a Cancel.scope');
          throw StateError('bug');
        },
      );
      await expectLater(cli.run([]), throwsStateError);
      expect(hookRan, isTrue);
      expect(seen!.isCancelled, isTrue);
    });
  });

  group('Io seam', () {
    late StringBuffer out;

    setUp(() {
      out = StringBuffer();
      Io.out = out;
    });

    tearDown(() {
      Io.reset();
      Io.color = null;
      Env.remove('NO_COLOR');
    });

    test('captures subprocess output, not just Console output', () async {
      Console.ok('via Console');
      await run('echo SUBPROCESS_MARKER');

      expect(out.toString(), contains('via Console'));
      expect(out.toString(), contains('SUBPROCESS_MARKER'));
    });

    test('quiet: true still suppresses subprocess output', () async {
      final result = await run('echo QUIET_MARKER', quiet: true);

      expect(result.stdout, contains('QUIET_MARKER'));
      expect(out.toString(), isNot(contains('QUIET_MARKER')));
    });

    test('a redirected sink is never treated as a terminal', () {
      expect(Io.isTerminal, isFalse);
      expect(Io.columns, isNull);
    });

    test('a redirected sink disables ANSI unless explicitly overridden', () {
      expect(Io.color, isFalse);

      Io.color = true;
      expect(Io.color, isTrue);
    });

    test('Ansi resolves override, then NO_COLOR, then the sink', () {
      Io.reset();

      // 1. An explicit override wins over everything.
      Io.color = true;
      Env.set('NO_COLOR', '1');
      expect(Io.color, isTrue, reason: 'explicit override beats NO_COLOR');

      // 2. With no override, NO_COLOR read from Env disables styling. The value
      //    lives in Env only -- Platform.environment never sees it -- so this
      //    pins Env as the source Ansi consults.
      Io.color = null;
      expect(Platform.environment.containsKey('NO_COLOR'), isFalse);
      expect(Env.has('NO_COLOR'), isTrue);
      expect(Io.color, isFalse);
    });

    test('TaskBoard reports each completion without a terminal', () {
      final progress = Console.tasks(total: 3, slots: 2, message: 'files', columns: 80);

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
      final progress = Console.tasks(slots: 2, message: 'files', columns: 80);
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

    test('ProgressBar without a terminal reports each new tenth, not each tick', () {
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

  group('Console log scoping', () {
    test('silencing one task does not silence a concurrent one', () async {
      final out = StringBuffer();
      Io.out = out;
      addTearDown(Io.reset);
      await Future.wait([
        Console.silenced(() async => await Future<void>.delayed(const Duration(milliseconds: 20))),
        Future(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          Console.info('concurrent');
        }),
      ]);
      expect(out.toString(), contains('concurrent'));
    });

    test('silenced suppresses its own body and restores afterwards', () async {
      final out = StringBuffer();
      Io.out = out;
      addTearDown(Io.reset);
      await Console.silenced(() async => Console.info('hidden'));
      Console.info('shown');
      expect(out.toString(), isNot(contains('hidden')));
      expect(out.toString(), contains('shown'));
    });
  });
}
