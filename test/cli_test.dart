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
  @override
  Object? get error => null;
  const _Task(this.taskId, this.label, this.ratio, this.received, this.total, this.status, this.isDone);
}

class _Batch implements BatchProgress {
  @override
  final int completed;
  @override
  final int? total;
  @override
  int get failed => 0;
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
      spinner.text = 'Fetching the index';
      expect(spinner.text, equals('Fetching the index'));
      expect(Io.stripAnsi(out.toString()), isEmpty, reason: 'still spinning: no ending yet');
      spinner.succeed('index ready');

      // The ending says how long it took, which is what `elapsed` was read for.
      expect(Io.stripAnsi(out.toString()), matches(RegExp(r'✓ index ready \(\d+ms\)')));
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
      expect(Io.stripAnsi(err.toString()), isNot(contains('✓')));
      expect(Io.stripAnsi(err.toString()), contains('Three...'));
    });

    test('a spinner draws braille, or ASCII where the locale cannot', () async {
      const source = """
        void main() {
          Console.spinner('Waiting').stop();
          Lifecycle.onExit(null);
        }
      """;
      final utf8 = await _script(source, env: {'LC_ALL': 'en_US.UTF-8', 'TERM': 'xterm'});
      final ascii = await _script(source, env: {'LC_ALL': 'C', 'TERM': 'xterm'});
      final console = await _script(source, env: {'LC_ALL': 'en_US.UTF-8', 'TERM': 'linux'});
      // Without a terminal the first frame is what gets written.
      expect(utf8.stderr, contains('⠋ Waiting...'));
      expect(ascii.stderr, contains('- Waiting...'));
      expect(console.stderr, contains('- Waiting...'));
    }, testOn: '!windows');

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
    // A prompt writes to stderr, so `app > out.txt` captures none of the questions.
    late StringBuffer out;
    late StringBuffer stdoutText;

    setUp(() {
      out = StringBuffer();
      stdoutText = StringBuffer();
      Io.out = stdoutText;
      Io.err = out;
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

    test('select works with non-String choices via display', () async {
      feed(['2']);
      final servers = [(name: 'alpha', region: 'us'), (name: 'beta', region: 'eu')];
      final picked = await Console.select('Target', servers, display: (s) => '${s.name} (${s.region})');
      expect(picked.name, equals('beta'));
      expect(out.toString(), contains('alpha (us)'));
      expect(out.toString(), contains('beta (eu)'));
    });

    test('select infers String choices exactly as before', () async {
      feed(['3']);
      final env = await Console.select('Environment', ['dev', 'staging', 'prod']);
      expect(env, equals('prod'));
    });

    test('select shows an enum by its name, and what it returns is never nullable', () async {
      feed(['release']);
      const Mode? given = null;
      // `Mode`, not `Mode?`: the `??` reads as the answer or the prompt.
      final Mode mode = given ?? await Console.select('Mode', Mode.values);
      expect(mode, Mode.release);
      expect(out.toString(), contains('2) release'));
      expect(out.toString(), isNot(contains('Mode.')));
    });

    test('select returns the default on empty input', () async {
      feed(['']);
      final env = await Console.select('Environment', ['dev', 'staging'], or: 'staging');
      expect(env, equals('staging'));
      expect(out.toString(), contains('(default)'));
    });

    test('confirm and secret read the same line source', () async {
      feed(['n', 'hunter2']);
      expect(await Console.confirm('Go on?'), isFalse);
      expect(await Console.secret('Password'), 'hunter2');
      expect(await Console.confirm('Again?', or: false), isFalse); // end of input: the default
    });

    test('ask re-prompts until validate accepts', () async {
      feed(['abc', '8080']);
      final port = await Console.ask('Port', validate: (v) => int.tryParse(v) == null ? 'Must be a number' : null);
      expect(port, equals('8080'));
      expect(out.toString(), contains('Must be a number'));
    });

    test('ask falls back to the default at end of input instead of hanging', () async {
      Io.input = () => null; // immediate end of input
      final value = await Console.ask('Name', or: 'fallback');
      expect(value, equals('fallback'));
    });

    test('required ask throws rather than looping when input is exhausted', () async {
      Io.input = () => null; // immediate end of input
      await expectLater(Console.ask('Name', required: true), throwsA(isA<StateError>()));
    });

    test('every word of a prompt goes to stderr, none to stdout', () async {
      feed(['x', '1', 'y']);
      await Console.ask('Name');
      await Console.select('Pick', ['a', 'b']);
      await Console.confirm('Sure?');
      expect(stdoutText.toString(), isEmpty);
      expect(out.toString(), allOf(contains('Name'), contains('Pick'), contains('Sure?')));
    });

    test('confirm asks again on an answer that is neither yes nor no', () async {
      feed(['yse', 'yes']);
      expect(await Console.confirm('Go on?', or: false), isTrue, reason: 'a typo of yes used to be a no');
      expect(out.toString(), contains('Please answer y or n.'));
    });

    test('select refuses a default that is not among the choices, before asking', () {
      expect(() => Console.select('Pick', ['a', 'b'], or: 'c'), throwsArgumentError);
      expect(out.toString(), isEmpty);
    });
  });

  group('CLI', () {
    test('command with option, subcommand, and action execution', () async {
      var executed = false;
      String? parsedOut;
      int? parsedConcurrency;
      bool? isVerbose;

      final verbose = Opt.flag('verbose').abbr('v');
      final concurrency = Opt.number('concurrency').abbr('c').or(4);
      final out = Opt.text('out').abbr('o').or('dist');

      final cli = Cli(
        commands: [
          CliCommand(
            'fetch',
            'Fetch data',
            values: [verbose],
            commands: [
              CliCommand(
                'scrape',
                'Scrape URLs',
                values: [concurrency, out],
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
      final flag = Opt.flag('dry').abbr('d');
      await CliCommand('app', '', values: [flag], handler: (ctx) => flagged = ctx(flag)).run(['-d']);
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
            '',
            values: [jobs, watch, mode, out],
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
      final err = StringBuffer();
      Io.err = err;
      addTearDown(Io.reset);
      Console.progress(556, message: 'Audio Tracks', columns: 80).tick(
        0,
        'DISC.21／ LB!キャラクターソング・semicrystalline.Little Busters! original arrange album・Rockstar Busters! 他より #11',
      );
      final line = err.toString().trimRight();

      // Line length in terminal columns must not exceed terminalColumns - 1
      expect(Io.width(line), lessThanOrEqualTo(79));
      expect(line.contains('...'), isTrue);
      expect(line.startsWith('  Audio Tracks: ['), isTrue);
    });

    test('TaskBoard counts completions and revises its total upward', () {
      final out = StringBuffer();
      final err = StringBuffer();
      Io.out = out;
      Io.err = err;
      addTearDown(Io.reset);
      final multi = Console.tasks(total: 10, slots: 3, message: 'Downloading Assets', columns: 80);

      multi.report(_batch(1, 10, _task('task1', 'song01.flac', 0.5, 500000, 1000000)));
      expect(err.toString(), isEmpty); // nothing durable until something finishes
      multi.report(_batch(2, 12, _task('song03', 'song03.flac', 1, 600000, 600000, status: 'done', done: true)));

      expect(multi.current, 2);
      expect(multi.total, 12);
      expect(err.toString(), contains('[2/12] song03.flac (585.9 KB) [done]'));
      expect(() => multi.done('All assets completed.'), returnsNormally);
      expect(out.toString(), contains('All assets completed.'));
    });

    test('choice accepts valid options and throws UsageException on invalid value', () async {
      // CliCommand.run throws; Cli.run would turn the error into exit code 64.
      String? chosenFormat;

      final format = Opt.among('format', Mode.values).or(Mode.debug);
      final cli = CliCommand(
        'app',
        '',
        commands: [
          CliCommand('build', '', values: [format], handler: (ctx) => chosenFormat = ctx(format).name),
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

      final dryRun = Opt.flag('dry-run').abbr('d');
      final workers = Opt.number('concurrency').abbr('c').or(4);

      final cli = CliCommand(
        'app',
        '',
        commands: [
          CliCommand(
            'serve',
            '',
            values: [dryRun, workers],
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

      final offsetOpt = Opt.number('offset').abbr('o');

      final cli = Cli(
        commands: [
          CliCommand(
            'seek',
            '',
            values: [offsetOpt],
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
      final verboseOpt = Opt.flag('verbose').abbr('v');
      final dryOpt = Opt.flag('dry-run').abbr('d');
      final jobsOpt = Opt.number('jobs').abbr('j').or(1);
      final cli = CliCommand(
        'app',
        '',
        values: [verboseOpt, dryOpt, jobsOpt],
        commands: [
          CliCommand(
            'build',
            '',
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
        final cli = CliCommand('app', '', values: [tokenOpt], handler: (ctx) => token = ctx(tokenOpt));
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
        '',
        values: [since, port],
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
        '',
        values: [nameOpt, portOpt, sizeOpt],
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
        values: [format],
        commands: [CliCommand('download', '', handler: (ctx) => subFmt = ctx(format))],
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
      final tokenOpt = Opt.text('token', 'API token').abbr('t').required();
      final cli = CliCommand('app', '', values: [tokenOpt], handler: (ctx) => token = ctx(tokenOpt));

      await cli.run(['--token', 'abc']);
      expect(token, equals('abc'));

      expect(
        () => cli.run([]),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('Missing required option'))),
      );

      // Required is also enforced from an ancestor command, and shows up in help.
      final nested = CliCommand(
        'app',
        '',
        values: [Opt.number('port').required()],
        commands: [CliCommand('serve', '', handler: (_) {})],
      );
      expect(() => nested.run(['serve']), throwsA(isA<UsageException>()));
    });

    test('a declared default reaches the context with no read-site argument', () async {
      String? format;
      int? workers;
      final formatOpt = Opt.among('format', ['mp3', 'all']).or('all');
      final workersOpt = Opt.number('workers').or(4);

      final cli = Cli(
        values: [formatOpt, workersOpt],
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

  group('a positional is a declared value, not a list to pick through', () {
    Future<String> usageOf(CliCommand command, List<String> args) async {
      final out = StringBuffer();
      Io.out = out;
      try {
        await command.run(args);
      } finally {
        Io.reset();
      }
      return out.toString();
    }

    test('it is typed, defaulted and required exactly as an option is', () async {
      final id = Arg.text('id').required();
      final count = Arg.number('count').or(3);
      Object? seenId;
      Object? seenCount;

      await CliCommand(
        'demo',
        '',
        values: [id, count],
        handler: (ctx) {
          seenId = ctx(id); // String, statically
          seenCount = ctx(count); // int, statically
        },
      ).run(['abc', '7']);

      expect(seenId, 'abc');
      expect(seenCount, 7);
    });

    test('a default fills an absent one, and a bad value is a usage error', () async {
      var seen = 0;
      final count = Arg.number('count').or(3);
      final cli = CliCommand('demo', '', values: [count], handler: (ctx) => seen = ctx(count));

      await cli.run([]);
      expect(seen, 3, reason: 'absent, so the default');
      expect(() => cli.run(['nine']), throwsA(isA<UsageException>()));
    });

    test('a missing required one names itself, and an extra one is refused', () {
      final id = Arg.text('id').required();
      final cli = CliCommand('demo', '', values: [id], handler: (_) {});

      expect(() => cli.run([]), throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('<id>'))));
      expect(
        () => cli.run(['a', 'b']),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('"b"'))),
      );
    });

    test('a variadic one takes the remainder, and required means at least one', () async {
      final tag = Arg.text('tag').required();
      final paths = Arg.text('paths').many().required();
      List<String>? seen;
      String? seenTag;
      final cli = CliCommand(
        'demo',
        '',
        values: [tag, paths],
        handler: (ctx) {
          seenTag = ctx(tag);
          seen = ctx(paths);
        },
      );

      await cli.run(['v1', 'a.txt', 'b.txt', 'c.txt']);
      expect(seenTag, 'v1');
      expect(seen, ['a.txt', 'b.txt', 'c.txt']);
      expect(() => cli.run(['v1']), throwsA(isA<UsageException>()));
    });

    test('a choice argument is matched by name, and an unknown one is refused', () async {
      final level = Arg.among('level', LogLevel.values).or(LogLevel.info);
      Object? seen;
      final cli = CliCommand('demo', '', values: [level], handler: (ctx) => seen = ctx(level));

      await cli.run(['warn']);
      expect(seen, LogLevel.warn);
      expect(() => cli.run(['loud']), throwsA(isA<UsageException>()));
    });

    test('a command that declares none keeps rest exactly as it was', () async {
      List<String>? seen;
      await CliCommand('demo', '', handler: (ctx) => seen = ctx.rest).run(['a', 'b', 'c']);
      expect(seen, ['a', 'b', 'c'], reason: 'nothing checked, nothing consumed');
    });

    test('the usage line says what the command takes and nothing it does not', () async {
      final help = await usageOf(
        CliCommand(
          'demo',
          'Does a thing',
          values: [Arg.text('id', 'Which one').required(), Arg.text('extra').many(), Opt.flag('verbose').abbr('v')],
          handler: (_) {},
        ),
        ['--help'],
      );

      expect(help, contains('Usage: demo <id> [extra...] [options]'));
      expect(help, isNot(contains('[command]')), reason: 'this program has no commands');
      expect(help, contains('Arguments:'));
      expect(help, contains('<id>'));
      expect(help, contains('Which one'));
      expect(help, contains('[extra...]'));
    });

    test('a program with commands still advertises them', () async {
      final help = await usageOf(CliCommand('demo', '', commands: [CliCommand('go', 'Go', handler: (_) {})]), [
        '--help',
      ]);
      expect(help, contains('Usage: demo [options] [command]'));
      expect(help, contains('Commands:'));
    });

    test('a subcommand prints its own arguments, not its parent\'s', () async {
      final help = await usageOf(
        CliCommand(
          'demo',
          '',
          commands: [
            CliCommand('go', 'Go', values: [Arg.text('where').required()], handler: (_) {}),
          ],
        ),
        ['go', '--help'],
      );
      expect(help, contains('Usage: demo go <where> [options]'));
    });

    test('taking -h for something else does not take --help with it', () async {
      final out = StringBuffer();
      Io.out = out;
      try {
        // A command with a `--host` still answers `--help`; `-h` is the one it took.
        await CliCommand(
          'demo',
          '',
          values: [Opt.text('host').abbr('h').or('127.0.0.1')],
          handler: (_) => fail('help should have run instead'),
        ).run(['--help']);
      } finally {
        Io.reset();
      }
      expect(out.toString(), contains('Usage: demo'));
      expect(out.toString(), contains('--help'));
      expect(out.toString(), isNot(contains('-h, --help')), reason: '-h belongs to --host now');
    });

    test('a command that declares its own help option keeps it', () async {
      var ran = false;
      await CliCommand('demo', '', values: [Opt.flag('help')], handler: (_) => ran = true).run(['--help']);
      expect(ran, isTrue, reason: 'the declared option won, and usage was not printed');
    });

    test('an option among the positionals is still an option', () async {
      final id = Arg.text('id').required();
      final loud = Opt.flag('loud').abbr('l');
      String? seen;
      var wasLoud = false;
      await CliCommand(
        'demo',
        '',
        values: [id, loud],
        handler: (ctx) {
          seen = ctx(id);
          wasLoud = ctx(loud);
        },
      ).run(['-l', 'abc']);
      expect(seen, 'abc');
      expect(wasLoud, isTrue);
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

    test('styling emits escapes even when stdout is redirected (CORE-4)', () {
      final out = StringBuffer();
      Io.out = out;
      addTearDown(Io.reset);
      expect('err'.red, contains('\x1B[31m'));
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
      final cli = CliCommand('demo', '', handler: (ctx) => throw ArgumentError('bug in the action'));
      expect(() => cli.run([]), throwsA(isA<ArgumentError>()));
    });

    test('a usage error is a UsageException with the message', () async {
      final cli = CliCommand('demo', '', values: [Opt.number('n')]);
      expect(
        () => cli.run(['--n', 'x']),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('"x" for option "--n"'))),
      );
    });

    test('what the action throws is one red line and exit 1; the hooks still run', () async {
      final r = await _script('''
        Future<void> main(List<String> a) => Cli(name: 'demo', handler: (ctx) {
          Lifecycle.onExit(() => print('hook ran, cancelled=\${ctx.cancel.isCancelled}'));
          throw StateError('bug');
        }).run(a);
      ''');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('✖ Bad state: bug'));
      expect(r.stderr, isNot(contains('#0')), reason: 'the trace is for --verbose');
      expect(r.stdout, contains('hook ran, cancelled=true'));
    });

    test('^C during a prompt ends the program through its exit hooks', () async {
      final process = await _start('''
        Future<void> main(List<String> a) => Cli(name: 'demo', handler: (ctx) async {
          Lifecycle.onExit(() => print('cleanup ran'));
          await Console.ask('Name');
          print('carried on');
        }).run(a);
      ''');
      final out = StringBuffer();
      final asked = Completer<void>();
      // The question is on stderr, and what the program prints on stdout.
      process.stderr.transform(const SystemEncoding().decoder).listen((s) {
        if (s.contains('Name:') && !asked.isCompleted) asked.complete();
      });
      process.stdout.transform(const SystemEncoding().decoder).listen(out.write);
      await asked.future.timeout(const Duration(seconds: 30));
      process.kill(ProcessSignal.sigint);
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 128 + ProcessSignal.sigint.signalNumber);
      expect(out.toString(), contains('cleanup ran'));
      expect(out.toString(), isNot(contains('carried on')));
    }, testOn: '!windows');
  });

  group('Io seam', () {
    late StringBuffer out;
    late StringBuffer err;

    setUp(() {
      out = StringBuffer();
      err = StringBuffer();
      Io.out = out;
      Io.err = err;
    });

    tearDown(() {
      Io.reset();
      Io.color = null;
      Env.set('NO_COLOR', '');
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

      final lines = err.toString().trim().split('\n');
      expect(lines.length, greaterThanOrEqualTo(3));
      for (final name in ['a.txt', 'b.txt', 'c.txt']) {
        expect(lines.where((l) => l.contains(name)).length, equals(1), reason: '$name reported exactly once');
      }
      expect(out.toString(), contains('finished'));
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
      progress.report(
        BatchDownloadProgress(completed: 1, total: null, written: 1, current: Downloaded(url, path, 1024)),
      );
      expect(err.toString(), contains('[1/?] a.txt'), reason: 'work done against no total is unknown, not out of 0');

      progress.report(BatchDownloadProgress(completed: 1, total: 2, written: 1, current: Downloaded(url, path, 1024)));
      expect(progress.total, equals(2), reason: 'total is revised as the source discovers work');

      progress.report(
        BatchDownloadProgress(completed: 2, total: 2, written: 1, current: DownloadSkipped(url, Path('out/b.txt'))),
      );
      progress.done('finished');

      final lines = err.toString().trim().split('\n');
      expect(lines.any((l) => l.contains('a.txt') && l.contains('[done]')), isTrue);
      expect(lines.any((l) => l.contains('b.txt') && l.contains('[skipped]')), isTrue);
      expect(out.toString(), contains('finished'));
    });

    test('ProgressBar without a terminal reports each new tenth, not each tick', () {
      final progress = Console.progress(3, message: 'files', columns: 80);
      progress
        ..tick()
        ..tick()
        ..tick();
      progress.done('finished');
      expect(err.toString().trim().split('\n').length, equals(3));
      expect(out.toString(), contains('finished'));

      err.clear();
      out.clear();
      final fine = Console.progress(1000, message: 'steps', columns: 80);
      for (var i = 0; i < 1000; i++) {
        fine.tick();
      }
      fine.done();
      expect(err.toString().trim().split('\n').length, lessThanOrEqualTo(11), reason: 'one line per tenth');
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

  group('what the command line can say', () {
    late StringBuffer out;
    setUp(() {
      out = StringBuffer();
      Io.out = out;
      Io.color = false;
    });
    tearDown(() {
      Io.reset();
      Io.color = null;
      Console.level = LogLevel.info;
      Env.set('TK_TEST_TOKEN', '');
    });

    final dry = Opt.flag('dry').abbr('d');
    final verbose = Opt.flag('verbose').abbr('v');
    final jobs = Opt.number('jobs').abbr('j');

    Future<CliContext> parse(List<String> argv, {List<CliValue<Object?>>? values}) async {
      late CliContext seen;
      await CliCommand('app', '', values: values ?? [dry, verbose, jobs], handler: (c) => seen = c).run(argv);
      return seen;
    }

    test('a flag takes =true or =false, and --no-<flag>, and nothing else', () async {
      expect((await parse(['--dry=false']))(dry), isFalse);
      expect((await parse(['--dry=true']))(dry), isTrue);
      expect((await parse(['--dry', '--no-dry']))(dry), isFalse);
      await expectLater(parse(['--dry=maybe']), throwsA(isA<UsageException>()));
      await expectLater(parse(['--no-jobs']), throwsA(isA<UsageException>()));
    });

    test('a bundle takes an attached value with or without =', () async {
      final n = Arg.number('n');
      final ctx = await parse(['-vj=4', '7'], values: [dry, verbose, jobs, n]);
      expect((ctx(verbose), ctx(jobs), ctx(n)), (true, 4, 7));
      expect((await parse(['-dj5']))(jobs), 5);
    });

    test('-5 is a positional number, not an unknown option', () async {
      final n = Arg.number('n');
      expect((await parse(['-5'], values: [dry, verbose, jobs, n]))(n), -5);
    });

    test('an unknown subcommand is a usage error that suggests the near one', () async {
      final app = CliCommand('app', '', commands: [CliCommand('build', '', handler: (_) {})]);
      await expectLater(
        app.run(['biuld']),
        throwsA(
          isA<UsageException>().having((e) => e.message, 'message', 'Unknown command "biuld". Did you mean "build"?'),
        ),
      );
    });

    test('a bad choice for an argument says argument, not option', () async {
      final mode = Arg.among('mode', ['a', 'b']);
      await expectLater(
        parse(['c'], values: [dry, verbose, jobs, mode]),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('argument <mode>'))),
      );
    });

    test('a subcommand\'s help shows the options it inherits', () async {
      await CliCommand(
        'app',
        '',
        values: [verbose],
        commands: [CliCommand('build', '', handler: (_) {})],
      ).run(['build', '--help']);
      expect(out.toString(), contains('Global options:'));
      expect(out.toString(), contains('-v, --verbose'));
    });

    test('many() collects every occurrence, in order', () async {
      final header = Opt.text('header').abbr('H').many();
      final ctx = await parse(['-H', 'a: 1', '--header=b: 2', '-Hc: 3'], values: [header]);
      expect(ctx(header), ['a: 1', 'b: 2', 'c: 3']);
      expect((await parse([], values: [header]))(header), isEmpty);
    });

    test('env() fills an option the command line left out, and satisfies required()', () async {
      final token = Opt.text('token').env('TK_TEST_TOKEN').required();
      await expectLater(parse([], values: [token]), throwsA(isA<UsageException>()));
      Env.set('TK_TEST_TOKEN', 'from-env');
      expect((await parse([], values: [token]))(token), 'from-env');
      expect((await parse(['--token', 'typed'], values: [token]))(token), 'typed');
      await CliCommand('app', '', values: [token]).run(['--help']);
      expect(out.toString(), contains('[env: TK_TEST_TOKEN]'));
    });

    test('Cli answers -v and -q by setting the log level, unless it declares its own', () async {
      await Cli(name: 'app', handler: (_) {}).run(['-v']);
      expect(Console.level, LogLevel.debug);
      Console.level = LogLevel.info;
      await Cli(name: 'app', handler: (_) {}).run(['--quiet']);
      expect(Console.level, LogLevel.warn);
      Console.level = LogLevel.info;
      late CliContext ctx;
      final own = Opt.flag('verbose');
      await Cli(name: 'app', values: [own], handler: (c) => ctx = c).run(['--verbose']);
      expect(ctx(own), isTrue);
      expect(Console.level, LogLevel.info);
    });

    test('--completion prints a script built from the declared tree', () async {
      final app = Cli(
        name: 'app',
        commands: [
          CliCommand('build', '', values: [Opt.among('mode', Mode.values)], handler: (_) {}),
        ],
      );
      await app.run(['--completion', 'bash']);
      expect(out.toString(), contains('complete -o default -F _app_completion app'));
      expect(out.toString(), contains(r'''"app build:--mode") COMPREPLY=($(compgen -W $'debug\nrelease' '''));
      out.clear();
      await app.run(['--completion=fish']);
      expect(out.toString(), contains("-a 'build'"));
      await expectLater(CliCommand('x', '').run([]), completes);
    });
  });

  group('the command line, the second audit', () {
    Future<String> helpOf(CliCommand command) async {
      final out = StringBuffer();
      Io.out = out;
      Io.color = false;
      try {
        await command.run(['--help']);
      } finally {
        Io.reset();
        Io.color = null;
      }
      return out.toString();
    }

    test('help says what each option takes, and a flag takes nothing', () async {
      final help = await helpOf(
        CliCommand(
          'demo',
          '',
          values: [
            Opt.number('num').abbr('n'),
            Opt.flag('dry').abbr('d'),
            Opt.among('mode', ['fast', 'slow']),
            Opt.text('name'),
          ],
          handler: (_) {},
        ),
      );
      expect(help, contains('-n, --num <int>'));
      expect(help, contains('--mode <fast|slow>'));
      expect(help, contains('--name <text>'));
      expect(help, isNot(contains('--dry <')));
    });

    test('values: holds Args and Opts in one list; the Args bind in order', () async {
      final a = Arg.text('a').required();
      final b = Arg.number('b').required();
      final loud = Opt.flag('loud');
      late (String, int, bool) seen;
      await CliCommand(
        'demo',
        '',
        values: [a, loud, b],
        handler: (ctx) => seen = (ctx(a), ctx(b), ctx(loud)),
      ).run(['x', '--loud', '7']);
      expect(seen, ('x', 7, true));
    });

    test('Arg.<kind>.many() parses each value, and required() means at least one', () async {
      final ns = Arg.number('ns').many();
      List<int>? seen;
      final cli = CliCommand('sum', '', values: [ns], handler: (ctx) => seen = ctx(ns));
      await cli.run(['1', '2', '3']);
      expect(seen, [1, 2, 3]);
      await cli.run([]);
      expect(seen, isEmpty);
      await expectLater(
        cli.run(['1', 'two']),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('argument <ns>'))),
      );
      final some = Arg.by('files', Uri.parse).many().required();
      await expectLater(
        CliCommand('x', '', values: [some], handler: (_) {}).run([]),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', 'Missing argument: <files>...')),
      );
    });

    test('-vd=false gives the value to the flag it follows', () async {
      final v = Opt.flag('verbose').abbr('v');
      final d = Opt.flag('dry').abbr('d');
      late (bool, bool) seen;
      await CliCommand('demo', '', values: [v, d], handler: (ctx) => seen = (ctx(v), ctx(d))).run(['-vd=false']);
      expect(seen, (true, false));
    });

    test('a mistyped option is offered the one it is close to', () async {
      await expectLater(
        CliCommand('demo', '', values: [Opt.text('name')], handler: (_) {}).run(['--nme', 'x']),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('Did you mean "--name"?'))),
      );
    });

    test('a bad number names the option it was given to', () async {
      await expectLater(
        CliCommand('demo', '', values: [Opt.number('top').abbr('n')], handler: (_) {}).run(['-n', 'abc']),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('option "--top"'))),
      );
    });

    test('a program of subcommands run with none exits 64, usage on stderr', () async {
      final process = await _start('''
        Future<void> main(List<String> a) => Cli(name: 'demo', commands: [CliCommand('go', '', handler: (_) {})]).run(a);
      ''');
      final out = process.stdout.transform(const SystemEncoding().decoder).join();
      final err = process.stderr.transform(const SystemEncoding().decoder).join();
      expect(await process.exitCode.timeout(const Duration(seconds: 30)), 64);
      expect(await out, isEmpty);
      expect(await err, contains('Usage:'));
    }, testOn: '!windows');

    test('-q silences a spinner and a board, but not a failure', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      Io.out = out;
      Io.err = err;
      Io.color = false;
      Console.level = LogLevel.warn;
      addTearDown(() {
        Io.reset();
        Io.color = null;
        Console.level = LogLevel.info;
      });
      await Console.spin('spinning', () async {}, done: 'spun');
      Console.progress(10, message: 'bar').tick(10);
      final board = Console.tasks(total: 1);
      board.done('boarded');
      expect(out.toString(), isEmpty);
      await expectLater(Console.spin('failing', () => throw StateError('boom')), throwsStateError);
      expect(err.toString(), contains('failing failed'));
    });

    test('a bar never draws a line wider than its columns', () {
      final out = StringBuffer();
      Io.out = out;
      addTearDown(Io.reset);
      Console.progress(10, message: 'a long message', columns: 15).tick(10, 'label');
      for (final line in out.toString().split('\n').where((l) => l.isNotEmpty)) {
        expect(Io.width(line), lessThanOrEqualTo(14), reason: line);
      }
    });

    test('the log verbs and Lifecycle.exit take any object', () {
      final err = StringBuffer();
      Io.err = err;
      Io.color = false;
      addTearDown(() {
        Io.reset();
        Io.color = null;
      });
      Console.warn(StateError('went wrong'));
      expect(err.toString(), contains('Bad state: went wrong'));
    });

    test('a board grows a row per task running at once, and no further than asked', () {
      final board = Console.tasks();
      expect(board.slots, isNull);
      expect(Console.tasks(slots: 2).slots, 2);
    });

    test('a choice with a space completes as one word in bash', () async {
      final app = Cli(
        name: 'app',
        values: [
          Opt.among('env', ['dry run', 'live']),
        ],
        handler: (_) {},
      );
      final out = StringBuffer();
      Io.out = out;
      try {
        await app.run(['--completion', 'bash']);
      } finally {
        Io.reset();
      }
      final dir = Directory.systemTemp.createTempSync('compl_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File('${dir.path}/c.sh')
        ..writeAsStringSync(
          '${out}COMP_WORDS=(app --env d); COMP_CWORD=2; _app_completion; '
          r'''printf '%s|' "${COMPREPLY[@]}"''',
        );
      final result = await Process.run('bash', [script.path]);
      expect(result.stdout, r'dry\ run|');
    }, testOn: '!windows');

    test('bash completion resolves --opt= with choices (CLI-9)', () async {
      final app = Cli(
        name: 'app',
        values: [
          Opt.among('mode', ['debug', 'release']),
        ],
        handler: (_) {},
      );
      final out = StringBuffer();
      Io.out = out;
      try {
        await app.run(['--completion', 'bash']);
      } finally {
        Io.reset();
      }
      final dir = Directory.systemTemp.createTempSync('compl_bash_eq_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File('${dir.path}/c.sh')
        ..writeAsStringSync(
          '${out}COMP_WORDS=(app --mode=d); COMP_CWORD=1; _app_completion; '
          r'''printf '%s|' "${COMPREPLY[@]}"''',
        );
      final result = await Process.run('bash', [script.path]);
      expect(result.stdout, contains('debug'));
    }, testOn: '!windows');

    test('fish completion uses _reachable and offers help (CLI-8)', () async {
      final app = Cli(
        name: 'app',
        values: [Opt.flag('quick').abbr('q')],
        commands: [
          CliCommand('sub', '', values: [Opt.flag('quiet').abbr('q')], handler: (_) {}),
        ],
        handler: (_) {},
      );
      final out = StringBuffer();
      Io.out = out;
      try {
        await app.run(['--completion', 'fish']);
      } finally {
        Io.reset();
      }
      final fish = out.toString();
      expect(fish, contains("-l help -d 'Print this help message'"));
      expect(fish, contains(r"test (__app_path) = \'app sub\'"));
    });
  });

  group('the call site, the fourth audit', () {
    Future<String> helpOf(CliCommand command) async {
      final out = StringBuffer();
      Io.out = out;
      Io.color = false;
      try {
        await command.run(['--help']);
      } finally {
        Io.reset();
        Io.color = null;
      }
      return out.toString();
    }

    test('the description is the second positional, and abbr() adds the short form', () async {
      final top = Opt.number('top', 'How many to show').abbr('n').or(10);
      final dry = Opt.flag('dry', 'Print, do not write').abbr('d');
      final id = Arg.text('id', 'What to fetch').required();
      int? seen;
      bool? wasDry;
      final go = CliCommand(
        'go',
        'Go and fetch',
        values: [id, top, dry],
        handler: (ctx) {
          seen = ctx(top);
          wasDry = ctx(dry);
        },
      );
      final root = CliCommand('app', 'The app', commands: [go]);

      final help = await helpOf(go);
      expect(help, contains('Go and fetch'));
      expect(help, contains('What to fetch'));
      expect(help, matches(RegExp(r'-n, --top <int>\s+How many to show \[default: 10\]')));
      expect(help, matches(RegExp(r'-d, --dry\s+Print, do not write')));
      expect(await helpOf(root), matches(RegExp(r'go\s+Go and fetch')));

      await root.run(['go', 'x', '-n', '3', '-d']);
      expect((seen, wasDry), (3, true));
    });

    test('abbr() keeps what the chain said before it, in any order', () async {
      final a = Opt.text('token').env('TK_TEST_TOKEN').abbr('t').required();
      final b = Opt.among('mode', Mode.values).or(Mode.debug).abbr('m');
      final c = Opt.text('header').abbr('H').many();
      late (String, Mode, List<String>) got;
      final cmd = CliCommand('x', '', values: [a, b, c], handler: (ctx) => got = (ctx(a), ctx(b), ctx(c)));
      await cmd.run(['-t', 'secret', '-H', '1', '-H', '2']);
      expect((got.$1, got.$2), ('secret', Mode.debug));
      expect(got.$3, ['1', '2']);
      await cmd.run(['-t', 's', '-m', 'release']);
      expect(got.$2, Mode.release);
      expect(await helpOf(cmd), contains('[env: TK_TEST_TOKEN] [required]'));
    });

    test('a print inside Cli.run is a durable write, like Console.writeln', () async {
      final out = StringBuffer();
      Io.out = out;
      addTearDown(Io.reset);
      await Cli(name: 'demo', handler: (_) => print('from print')).run([]);
      expect(out.toString(), 'from print\n');
    });

    test('Cli is named after its script, and throw is how a handler fails', () async {
      final named = await _script('''
        Future<void> main() => Cli(handler: (_) {}).run(['--completion', 'bash']);
      ''');
      expect(named.stdout, contains('complete -o default -F _main_completion main'));

      final failed = await _script('''
        Future<void> main() => Cli(handler: (_) async => throw 'no URL given').run([]);
      ''');
      expect(failed.exitCode, 1);
      expect(Io.stripAnsi(failed.stderr), contains('✖ no URL given'));
    });
  });

  group('ConsoleTheme and builders', () {
    late StringBuffer out;
    late StringBuffer err;
    setUp(() {
      Io.out = out = StringBuffer();
      Io.err = err = StringBuffer();
    });
    tearDown(() {
      Io.reset();
      Console.theme = const ConsoleTheme();
    });

    test('a log line is the theme\'s indent, mark and colour', () {
      Console.theme = ConsoleTheme(ok: '✔', indent: '', success: (s) => '<$s>', warning: (s) => s.toUpperCase());
      Console.ok('built');
      Console.warn('careful');
      Console.theme = const ConsoleTheme();
      Console.info('default');
      expect(out.toString(), '<✔ built>\n  ℹ default\n');
      expect(err.toString(), '⚠ CAREFUL\n');
    });

    test('themed() scopes a theme to its body and what it awaits', () async {
      await Future.wait([
        Console.themed(const ConsoleTheme(info: '>'), () async {
          await Future<void>.delayed(Duration.zero);
          Console.info('inside');
          Console.spinner('spun').succeed();
        }),
        Future<void>.delayed(Duration.zero, () => Console.info('beside')),
      ]);
      Console.info('after');
      expect(out.toString(), contains('  > inside\n'));
      expect(out.toString(), contains('  ℹ beside\n'));
      expect(out.toString(), endsWith('  ℹ after\n'));
      expect(err.toString(), contains('  ⠋ spun...'), reason: 'the scoped theme kept the default frames');
    });

    test('a spinner draws the theme\'s frames and marks; line: draws the whole line', () {
      Console.theme = const ConsoleTheme(frames: ['o'], ok: '+', error: 'x');
      Console.spinner('Two').succeed();
      Console.spinner('Three').fail('nope');
      final views = <SpinnerView>[];
      Console.spinner('Four', line: (s) => 'start ${(views..add(s)).last.text} ${s.frame}').stop();
      expect(err.toString(), contains('  o Two...\n'));
      expect(out.toString(), matches(RegExp(r'^  \+ Two \(\d+ms\)\n$')));
      expect(err.toString(), matches(RegExp(r'  x nope \(\d+ms\)\n')));
      expect(err.toString(), endsWith('start Four o\n'));
      expect(views.single.isLive, isFalse, reason: 'without a terminal: the line a log keeps');
    });

    test('a bar draws the theme\'s glyphs; line: draws it from a ProgressView', () async {
      Console.theme = const ConsoleTheme(fill: '#', empty: '.');
      Console.progress(4, message: 'up', columns: 80).tick(2);
      final views = <ProgressView>[];
      final bar = Console.progress(
        4,
        columns: 40,
        line: (p) =>
            '${(views..add(p)).last.bar(4)}|${p.bar(4, head: '>')}|${p.percent}|${p.current}/${p.total}|${p.label}',
      )..tick(0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      bar.tick(2, 'x');
      expect(err.toString().split('\n'), [
        '  up: [##########..........] 50% (2/4)',
        '....|....|0|0/4|null',
        '##..|#>..|50|2/4|x',
        '',
      ]);
      final p = views.last;
      expect(p.columns, 39);
      expect(p.isLive, isFalse);
      // Two steps in no less than 100 ms: at most 20 a second, so at least 100 ms to go.
      expect(p.rate, inInclusiveRange(1e-9, 20));
      expect(p.eta, greaterThanOrEqualTo(const Duration(milliseconds: 100)));
      expect(p.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 100)));
    });

    test('a board hands task: a TaskView with its number, state, bytes and speed', () async {
      final views = <TaskView>[];
      final board = Console.tasks(
        total: 3,
        columns: 80,
        task: (t) => '${(views..add(t)).last.index}/${t.count} ${t.name}',
      );
      board.report(_batch(0, 3, _task('a', 'a.bin', 0, 0, 1000)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      board.report(_batch(0, 3, _task('a', 'a.bin', 0.5, 500, 1000)));
      board.report(_batch(0, 3, _task('b', 'b.bin', null, null, null, status: 'skipped', done: true)));
      board.report(_batch(1, 3, _task('a', 'a.bin', 1, 1000, 1000, status: 'done', done: true)));
      board.report(_batch(3, 3, _task('c', 'c.bin', null, null, null, status: 'failed', done: true)));
      board.done();
      expect(err.toString(), '2/3 b.bin\n1/3 a.bin\n3/3 c.bin\n');
      final [b, a, c] = views;
      expect([b.state, a.state, c.state], [TaskState.skipped, TaskState.done, TaskState.failed]);
      expect((a.bytes, a.bytesTotal, a.fraction, a.percent), (1000, 1000, 1.0, 100));
      // 500 bytes in no less than 100 ms, then 500 more weighted by the time they took:
      // at most 5000/s plus 500/1.5.
      expect(a.speed, inInclusiveRange(1, 5334));
      expect(a.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 100)));
      expect(a.batch.bytes, 1000);
      expect(a.batch.bytesTotal, isNull, reason: 'c has not been heard of yet');
      expect(c.batch.bytesTotal, 1000, reason: 'every task sized; a skip and a failure add nothing');
      expect(c.batch.fraction, 1.0);
      expect(a.batch.speed, greaterThan(0));
    });

    test('the default board line without a terminal is unchanged by the views', () {
      Console.tasks(
        total: 2,
        columns: 80,
      ).report(_batch(1, 2, _task('a', 'a.bin', 1, 2048, 2048, status: 'done', done: true)));
      expect(err.toString(), '  [1/2] a.bin (2.0 KB) [done]\n');
    });

    test('rule and prompts draw with the theme', () async {
      Console.theme = const ConsoleTheme(
        border: Border(top: '='),
        prompt: '? ',
        promptEnd: ' › ',
      );
      Console.rule();
      Io.input = () => 'sam';
      expect(await Console.ask('Name'), 'sam');
      expect(out.toString(), '${'=' * 80}\n');
      expect(err.toString(), '? Name › ');
    });

    test('ascii is ASCII everywhere, tables included', () {
      Console.theme = ConsoleTheme.ascii;
      Console.ok('a');
      Console.rule();
      Table.cells(
        ['k'],
        [
          ['v'],
        ],
      ).show();
      expect(out.toString(), '  + a\n${'-' * 80}\n+---+\n| k |\n+---+\n| v |\n+---+\n');
    });

    test('a terminal that cannot draw Unicode gets the ASCII theme', () async {
      final ascii = await _script(
        '''
        void main() {
          Console.ok('done');
          Table.cells(['k'], [['v']]).show();
          Lifecycle.onExit(null);
        }
      ''',
        env: {'LC_ALL': 'C', 'TERM': 'xterm'},
      );
      expect(Io.stripAnsi(ascii.stdout), '  + done\n+---+\n| k |\n+---+\n| v |\n+---+\n');
    }, testOn: '!windows');

    test('Table.show takes a Border, an alignment per column and a cell builder', () {
      final t = Table.cells(
        ['name', 'n'],
        [
          ['a', 1],
          ['bcd', 100],
        ],
      );
      t.show(border: Border.ascii, align: 'cr');
      t.show(border: Border.none, cell: (row, column) => column == 'n' ? '#${row.text(column)}' : row.text(column));
      t.show(border: Border.markdown);
      expect(
        out.toString(),
        '+------+-----+\n'
        '| name |   n |\n'
        '+------+-----+\n'
        '|  a   |   1 |\n'
        '| bcd  | 100 |\n'
        '+------+-----+\n'
        '  name   n\n'
        '  a      #1\n'
        '  bcd    #100\n'
        '| name | n   |\n'
        '|------|-----|\n'
        '| a    | 1   |\n'
        '| bcd  | 100 |\n',
      );
    });
  });
}

/// Runs [source] as a program of its own: what `Cli.run` does to the process — exit codes,
/// signals — cannot be watched from inside the test runner.
Future<ShellResult> _script(String source, {Map<String, String>? env}) async {
  final process = await _start(source, env: env);
  final (out, err) = await (
    process.stdout.transform(const SystemEncoding().decoder).join(),
    process.stderr.transform(const SystemEncoding().decoder).join(),
  ).wait;
  return ShellResult(command: 'script', exitCode: await process.exitCode, stdout: out, stderr: err);
}

Future<Process> _start(String source, {Map<String, String>? env}) async {
  final dir = await Directory.systemTemp.createTemp('cli_script_');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/main.dart')
    ..writeAsStringSync("import 'package:dart_toolkit/dart_toolkit.dart';\n$source");
  final packages = File('.dart_tool/package_config.json').absolute.path;
  return Process.start(Platform.resolvedExecutable, ['--packages=$packages', file.path], environment: env);
}
