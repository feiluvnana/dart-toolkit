import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Cli Tests', () {
    test('Cli parses flags, aliases, options, and positional args', () {
      final cli = Cli([
        '--concurrency=8',
        '-f',
        '--name',
        'Toolkit',
        'extra1',
        'extra2',
      ]);
      final force = cli.flag('force-compress', alias: 'f');
      final size = cli.number('concurrency', def: 4);
      final name = cli.option('name', def: 'default');
      final missing = cli.number('missing', def: 42);

      expect(force(), isTrue);
      expect(size(), equals(8));
      expect(name(), equals('Toolkit'));
      expect(missing(), equals(42));

      expect(cli.args, equals(['extra1', 'extra2']));
    });

    test('--no-x reads false and is not the same as being given', () {
      final cli = Cli(['--no-force']);
      final force = cli.flag('force', def: true);

      expect(force.negated(), isTrue);
      expect(force.given(), isFalse);
      expect(force(), isFalse);
    });

    test('an unparsed command line is empty, not the VM arguments', () {
      expect(Cli(const []).raw, isEmpty);
      expect(Cli(const []).args, isEmpty);
      expect(Cli(const []).switches, isEmpty);
    });

    test('short switches cluster, unless a declaration claims the token', () {
      // `switches` is the parser's own answer, before any declaration, which
      // is the only way to watch a token that is deliberately undeclared.
      expect(Cli(['-abc', 'file.txt']).switches.keys, ['a', 'b', 'c']);
      expect(Cli(['-abc', 'file.txt']).args, equals(['file.txt']));

      // A cluster member declared with a value ends the cluster and takes one.
      final valued = Cli(['-vo', 'dist', 'target']);
      final v = valued.flag('v');
      final o = valued.option('o');
      expect(v(), isTrue);
      expect(o(), equals('dist'));
      expect(valued.args, equals(['target']));

      // ...or the rest of the cluster itself.
      final inline = Cli(['-vodist']);
      inline.flag('v');
      expect(inline.option('o')(), equals('dist'));

      // A declared multi-letter short name is never split.
      final whole = Cli(['-rf']);
      expect(whole.flag('rf')(), isTrue);
      expect(whole.switches.keys, ['rf']);

      // Only all-letter tokens cluster.
      expect(Cli(['-p8']).switches.keys, ['p8']);
    });

    test('a declared flag does not swallow the next token', () {
      // Named `parsed`, not `cli`: the domain accessor is `cli` now, and this
      // test needs both it and a standalone `Cli` in one scope.
      final parsed = Cli(['build', '--verbose', 'main.dart']);
      final verbose = parsed.flag('verbose');
      expect(parsed.command, equals('build'));
      expect(parsed.args, equals(['build', 'main.dart']));
      expect(verbose(), isTrue);

      // The same has to hold for declarations made before `parse`.
      final shared = cli.flag('verbose', alias: 'v');
      cli.parse(['build', '--verbose', 'main.dart']);
      expect(cli.command, equals('build'));
      expect(cli.args, equals(['build', 'main.dart']));
      expect(shared(), isTrue);
    });

    test('an option resolves the command line, then env, then its default', () {
      final cli = Cli(const <String>[]);
      expect(cli.option('out', def: 'dist')(), equals('dist'));
      expect(cli.number('workers', def: 4)(), equals(4));
      expect(cli.decimal('rate', def: 1.5)(), closeTo(1.5, 0.001));
      expect(cli.flag('cache', def: true)(), isTrue);

      // The command line outranks the default.
      expect(
        (Cli(['--out', 'build']).option('out', def: 'dist'))(),
        equals('build'),
      );

      system.env.set('OUT_DIR', 'from-env');
      final env = Cli(const <String>[]);
      final out = env.option('out', env: 'OUT_DIR', def: 'dist');
      expect(out(), equals('from-env'));
      // ...but the command line still wins over the environment.
      final given = Cli(['--out', 'cli']).option('out', env: 'OUT_DIR');
      expect(given(), equals('cli'));
      // Reaching a value through env is not the same as it being given.
      expect(out.given(), isFalse);
      system.env.clear();
    });

    test(
      'a number that is not a number is reported, not silently defaulted',
      () {
        // This is what `get('concurrency', 4)` used to do: hand back 4 and let
        // the script run on a number nobody asked for.
        final cli = Cli(['--concurrency=fast']);
        final size = cli.number('concurrency', def: 4);

        expect(size(), equals(4));
        expect(
          () => cli.require(),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message.toString(),
              'message',
              allOf(contains('--concurrency'), contains('fast')),
            ),
          ),
        );
      },
    );

    test('choice reads an enum, and refuses a name the enum does not have', () {
      final ok = Cli(['--level=warn']);
      final level = ok.choice('level', LogLevel.values, def: LogLevel.info);
      expect(level(), LogLevel.warn);
      expect(() => ok.require(), returnsNormally);

      final absent = Cli(const <String>[]);
      expect(
        absent.choice('level', LogLevel.values, def: LogLevel.info)(),
        LogLevel.info,
      );

      final bad = Cli(['--level=shout']);
      bad.choice('level', LogLevel.values, def: LogLevel.info);
      expect(() => bad.require(), throwsA(isA<ArgumentError>()));
    });

    test('require accepts a default or an env variable as supplied', () {
      final withDef = Cli(const <String>[])
        ..option('out', def: 'dist', required: true);
      expect(() => withDef.require(), returnsNormally);

      final withEnv = Cli(const <String>[]);
      final token = withEnv.option('token', env: 'API_TOKEN', required: true);
      expect(() => withEnv.require(), throwsA(isA<ArgumentError>()));
      system.env.set('API_TOKEN', 'secret');
      expect(() => withEnv.require(), returnsNormally);
      expect(token(), equals('secret'));
      system.env.clear();
    });

    test('require rejects a value outside allowed', () {
      final bad = Cli(['--mode=fast'])
        ..option('mode', allowed: ['debug', 'release']);
      expect(
        () => bad.require(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            allOf(contains('--mode'), contains('debug'), contains('fast')),
          ),
        ),
      );

      final good = Cli(['--mode=release'])
        ..option('mode', allowed: ['debug', 'release']);
      expect(() => good.require(), returnsNormally);
    });

    test('list collects every occurrence, and csv splits one', () {
      final cli = Cli(['--tag=a, b ,c', '--tag', 'd']);
      expect(cli.list('tag', csv: true)(), equals(['a', 'b', 'c', 'd']));

      // Without csv the comma is just part of the value.
      expect(Cli(['--tag=a,b']).list('tag')(), equals(['a,b']));

      // Nothing given reads the declared default.
      expect(Cli(const <String>[]).list('tag', def: const ['x'])(), ['x']);
    });

    test('unknown names switches no declaration covers', () {
      final cli = Cli(['--verbose', '--verbse', '--no-cache', '-f'])
        ..flag('verbose', alias: 'f')
        ..flag('cache');
      expect(cli.unknown(), equals(['verbse']));

      final clean = Cli(['--verbose'])..flag('verbose');
      expect(clean.unknown(), isEmpty);
    });

    test('duration is the sixth option kind', () {
      final parser = Cli(['--timeout', '1h30m']);
      final timeout = parser.duration('timeout', def: 30.s);
      expect(timeout(), equals(90.m));

      final bare = Cli(['--timeout', '45']);
      expect(bare.duration('timeout', def: 30.s)(), equals(45.s));

      final missing = Cli(<String>[]);
      expect(missing.duration('timeout', def: 30.s)(), equals(30.s));

      final bad = Cli(['--timeout', 'soon']);
      final fallback = bad.duration('timeout', def: 30.s);
      expect(fallback(), equals(30.s), reason: 'a bad value reads as def');
      expect(
        () => bad.require(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('must be a duration'),
          ),
        ),
      );
    });

    test('date reads null when nothing was given', () {
      final parser = Cli(['--since', '2024-03-09']);
      expect(parser.date('since')(), equals(DateTime(2024, 3, 9)));

      final loose = Cli(['--since', '09/03/2024']);
      expect(loose.date('since')(), equals(DateTime(2024, 3, 9)));

      final absent = Cli(<String>[]);
      expect(
        absent.date('since')(),
        isNull,
        reason: '--since exists so a script can tell "not given" apart',
      );

      final defaulted = Cli(<String>[]);
      expect(
        defaulted.date('since', def: DateTime(2020))(),
        equals(DateTime(2020)),
      );

      final bad = Cli(['--since', 'whenever']);
      expect(bad.date('since')(), isNull);
      expect(
        () => bad.require(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('must be a date'),
          ),
        ),
      );
    });

    test('both kinds show their default in the usage block', () {
      final parser = Cli(<String>[])
        ..duration('timeout', def: 90.m, desc: 'Give up after')
        ..date('since', def: DateTime.utc(2024, 3, 9), desc: 'Only after');
      final usage = parser.usage();
      expect(usage, contains('--timeout'));
      expect(usage, contains('1h30m'));
      expect(usage, contains('--since'));
    });
  });

  group('Cli Commands', () {
    test(
      'run dispatches, scopes arguments and returns the exit code',
      () async {
        String? seen;
        final cli = Cli(['build', 'main.dart', '--out', 'build', '-r']);
        final out = cli.option(
          'out',
          alias: 'o',
          def: 'dist',
          desc: 'Output directory',
        );
        late final Opt<bool> release;
        final build = cli.handle('build', (sub) {
          // A command's own option and a global one both read from the scope
          // the handler was given, with no argument passed to either.
          seen = '${out()}|${sub.args}|${release()}';
          return 0;
        }, desc: 'Build the project');
        release = build.flag('release', alias: 'r', desc: 'Optimise');

        expect(await cli.run(syntax: 'tool'), equals(0));
        // The command name is gone from the positionals, and the global option
        // and the command's own flag are both readable.
        expect(seen, equals('build|[main.dart]|true'));
      },
    );

    test('a command option read outside its run says so', () {
      final cli = Cli(const <String>[]);
      final build = cli.handle('build', (_) => 0);
      final out = build.option('out', def: 'dist');

      expect(
        out.call,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('is not running'),
          ),
        ),
      );
      // ...and reads fine against a Cli handed to it directly.
      expect(out(Cli(['--out', 'x'])..option('out')), equals('x'));
    });

    test('run resolves nested commands under a group', () async {
      var ran = '';
      final cli = Cli(['remote', 'add', 'origin', '--url=git@example.com']);
      final remote = cli.group('remote', desc: 'Manage remotes');
      late final Opt<String> url;
      final add = remote.handle('add', (sub) {
        ran = '${url()}|${sub.args}';
        return 0;
      }, desc: 'Add a remote');
      url = add.option('url', required: true);
      remote.handle('rm', (_) => 0, desc: 'Remove a remote');

      expect(await cli.run(syntax: 'tool'), equals(0));
      expect(ran, equals('git@example.com|[origin]'));
    });

    test('a handler returns the exit code', () async {
      Future<int> run(int result) =>
          (Cli(['go'])..handle('go', (_) => result)).run(syntax: 'tool');

      expect(await run(0), equals(0));
      expect(await run(1), equals(1));
      expect(await run(3), equals(3));
    });

    test('run reports a command line it cannot understand', () async {
      final typo = Cli(['buidl'])..handle('build', (_) => 0, desc: 'Build');
      expect(await typo.run(syntax: 'tool'), equals(Cli.usageExit));

      final unknownFlag = Cli(['build', '--verbse'])
        ..handle('build', (_) => 0, desc: 'Build');
      expect(
        await unknownFlag.run(syntax: 'tool', strict: true),
        equals(Cli.usageExit),
      );

      final missing = Cli(['build']);
      missing
          .handle('build', (_) => 0, desc: 'Build')
          .option('url', required: true);
      expect(await missing.run(syntax: 'tool'), equals(Cli.usageExit));
    });

    test('run answers --help and --version without running anything', () async {
      var ran = false;
      Cli make(List<String> args) {
        final cli = Cli(args);
        cli.handle('build', (_) {
          ran = true;
          return 0;
        }, desc: 'Build');
        return cli;
      }

      expect(await make(['--help']).run(syntax: 'tool'), equals(0));
      expect(await make(['build', '-h']).run(syntax: 'tool'), equals(0));
      expect(
        await make(['--version']).run(syntax: 'tool', version: '1.1.0'),
        equals(0),
      );
      expect(ran, isFalse);
    });

    test('run falls back to body when no command matches', () async {
      var seen = '';
      final cli = Cli(['--out', 'x']);
      final out = cli.option('out', desc: 'Output');
      final code = await cli.run(
        syntax: 'tool',
        body: (sub) {
          seen = out();
          return 0;
        },
      );
      expect(code, equals(0));
      expect(seen, equals('x'));
    });

    test('usage lists commands, defaults, env and allowed values', () {
      final cli = Cli(const <String>[])
        ..flag('verbose', alias: 'v', desc: 'Log every step')
        ..option('out', alias: 'o', def: 'dist', desc: 'Output directory')
        ..option('mode', desc: 'Build mode', allowed: ['debug', 'release'])
        ..option('token', desc: 'API token', env: 'API_TOKEN', required: true);
      cli.handle('build', (_) => 0, desc: 'Build the project');

      final help = cli.usage(syntax: 'tool <command>', desc: 'An example.');
      expect(help, contains('An example.'));
      expect(help, contains('Usage: tool <command>'));
      expect(help, contains('Commands:'));
      expect(help, contains('build'));
      expect(help, contains('Build the project'));
      expect(help, contains('-v, --verbose'));
      expect(help, contains('[default: dist]'));
      expect(help, contains('(debug|release)'));
      expect(help, contains('[env: API_TOKEN]'));
      expect(help, contains('(required)'));
    });
  });

  group('Pool Tests', () {
    test('Pool runs tasks concurrently with typed on events', () async {
      final pool = Pool<int>(size: 2);
      var started = false;
      var completed = false;
      final progressed = <int>[];

      pool.on.start(() => started = true);
      // The item is typed as int, with no cast at the call site.
      pool.on.progress(progressed.add);
      pool.on.done(() => completed = true);

      final results = await pool.run([1, 2, 3, 4], (item) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return item * 10;
      });

      expect(started, isTrue);
      expect(completed, isTrue);
      expect(progressed.length, equals(4));
      expect(results.collect(.list()), equals([10, 20, 30, 40]));
    });

    test('concurrent.run helper executes tasks', () async {
      final results = await concurrent.run(
        ['a', 'b', 'c'],
        (s) async => s.toUpperCase(),
        size: 3,
      );
      expect(results.collect(.list()), equals(['A', 'B', 'C']));
    });

    test(
      'a failing worker propagates its own error, not a null cast',
      () async {
        await expectLater(
          concurrent.run([1, 2, 3], (int i) async {
            if (i == 2) throw StateError('boom');
            return i * 10;
          }),
          throwsA(
            isA<StateError>().having((e) => e.message, 'message', 'boom'),
          ),
        );
      },
    );

    test(
      'registering on.error collects failures and reports them at the end',
      () async {
        final pool = Pool<int>(size: 2);
        final seen = <int>[];
        pool.on.error((error, stack, item) => seen.add(item));

        await expectLater(
          pool.run([1, 2, 3, 4], (i) async {
            if (i.isEven) throw StateError('even $i');
            return i;
          }),
          throwsA(isA<PoolFailure<int, int>>()),
        );
        // Every item was attempted, not just the ones before the first failure.
        expect(seen, equals([2, 4]));
      },
    );
  });

  group('Selector & Page extensions', () {
    const html = '''
      <div class="box active">
        <a href="/track/1.mp3">Track 1</a>
        <a href="https://example.com/2.flac">Track 2</a>
        <img src="album.jpg" />
        <div class="disc_lines">
          01. First Song<br>
          02. Second Song<br/>
          03. Third Song
        </div>
      </div>
    ''';

    test('Markup href, hrefs, src, srcs, lines, has', () {
      final q = html.$();
      expect(q.has('active'), isTrue);
      expect(q.has('missing'), isFalse);

      expect(
        q.find('a').matching(r'[href$=".mp3"]').attr('href'),
        equals('/track/1.mp3'),
      );
      expect(
        q.find('a').matching(r'[href$=".flac"]').attr('href'),
        equals('https://example.com/2.flac'),
      );
      expect(q.find('a').attrs('href').collect(.count()), equals(2));

      expect(q.find('img').attr('src'), equals('album.jpg'));
      expect(q.find('img').attrs('src').collect(.count()), equals(1));

      final lines = q.find('.disc_lines').lines;
      expect(
        lines.collect(.list()),
        equals(['01. First Song', '02. Second Song', '03. Third Song']),
      );

      expect(q.find('a').elements.collect(.count()), equals(2));
      expect(q.find('a').matching(r'[href$=".mp3"]').count, equals(1));
    });

    test('Reply provides Markup via \$ and \$xpath', () {
      final res = Reply(
        url: Uri.parse('https://example.com/sub/index.html'),
        status: 200,
        headers: const {},
        bytes: html.codeUnits,
      );

      expect(
        res.parse(format.html).find('a').attr('href'),
        equals('/track/1.mp3'),
      );
      expect(
        res.parse(format.html).find('img').attr('src'),
        equals('album.jpg'),
      );
      expect(
        res.parse(format.html).xpath('//a').attr('href'),
        equals('/track/1.mp3'),
      );
    });

    test('follow returns the next request rather than queueing one', () {
      final res = Reply.text(
        '<a href="/next">n</a>',
        fetch: Fetch('https://example.com/'.url),
      );

      // No engine, no side effect, no StateError: `next` is a pure function
      // and every piece of it is testable on its own.
      final Fetch next = res.follow('/next', tag: 'detail');
      expect(next.url, Uri.parse('https://example.com/next'));
      expect(next.tag, equals('detail'));
      expect(next.depth, equals(1));
    });
  });

  group('the crawl terminals', () {
    test(
      'a flow that nobody collects fetches nothing, and stats is a record',
      () async {
        final crawl = net.crawl([Fetch('https://example.com/'.url)])
          ..using((fetch) async => Reply.text('ok', fetch: fetch));

        // Built and thrown away: the workers start in the flow's `onListen`.
        crawl.flow;
        expect(crawl.stats.fetched, isZero);

        final Stats stats = await crawl.run();
        expect(stats.fetched, equals(1));
        expect(stats.reason, isNull);
      },
    );
  });

  group('Console namespaces', () {
    test('writer renders a table without printing it', () {
      final table = Table(headers: ['Col 1', 'Col 2'])..add(['Val 1', 'Val 2']);
      expect(table.length, equals(1));
      expect(table.render(), contains('Col 1'));
      expect(table.render(), contains('Val 1'));
    });

    test('Progress tracks its own total', () {
      final bar = Progress(total: 10, message: 'Testing');
      expect(bar.total, equals(10));
      bar.tick(3);
      expect(bar.current, equals(3));
    });

    test('logger exposes every severity', () {
      expect(system.console.logger, isA<ConsoleLogger>());
      expect(() => system.console.logger.info('Info'), returnsNormally);
      expect(() => system.console.logger.ok('Success'), returnsNormally);
      expect(() => system.console.logger.warn('Warn'), returnsNormally);
      expect(() => system.console.logger.error('Error'), returnsNormally);
      expect(() => system.console.logger.step(1, 1, 'Step'), returnsNormally);
      expect(() => system.console.logger.debug('Debug'), returnsNormally);
    });
  });

  group('Crawl entry points', () {
    test('net.crawl configures without running', () {
      final crawl = net.crawl([Fetch('https://example.com'.url)])
        ..concurrent(3);
      expect(crawl, isA<Crawl>());
      expect(crawl.stats.fetched, isZero);
    });

    test('an independent Fetcher carries its own settings', () async {
      final client = Fetcher(base: 'output', retries: 5);
      expect(client.base, equals('output'));
      expect(client.retries, equals(5));
      await client.close();
    });
  });
}
