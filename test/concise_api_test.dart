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

      expect(cli.has('force-compress', 'f'), isTrue);
      expect(cli.has('f'), isTrue);
      expect(cli.has('no-compress', 'nc'), isFalse);

      expect(cli.get('concurrency', 4), equals(8));
      expect(cli.get('name', 'default'), equals('Toolkit'));
      expect(cli.get('missing', 42), equals(42));

      expect(cli.list(), equals(['extra1', 'extra2']));
    });

    test('--no-x does not make has(x) true', () {
      final cli = Cli(['--no-force']);
      expect(cli.no('force'), isTrue);
      expect(cli.has('force'), isFalse);
      expect(cli.get<bool>('force', true), isFalse);
    });

    test('an unparsed command line is empty, not the VM arguments', () {
      expect(Cli(const []).raw, isEmpty);
      expect(Cli(const []).list(), isEmpty);
      expect(Cli(const []).has('anything'), isFalse);
    });

    test('short switches cluster, unless a declaration claims the token', () {
      final bundle = Cli(['-abc', 'file.txt']);
      expect(bundle.has('a'), isTrue);
      expect(bundle.has('b'), isTrue);
      expect(bundle.has('c'), isTrue);
      expect(bundle.has('abc'), isFalse);
      expect(bundle.list(), equals(['file.txt']));

      // A cluster member declared with a value ends the cluster and takes one.
      final valued =
          Cli(['-vo', 'dist', 'target'])
            ..flag('v')
            ..option('o');
      expect(valued.has('v'), isTrue);
      expect(valued.get('o', ''), equals('dist'));
      expect(valued.list(), equals(['target']));

      // ...or the rest of the cluster itself.
      final inline =
          Cli(['-vodist'])
            ..flag('v')
            ..option('o');
      expect(inline.get('o', ''), equals('dist'));

      // A declared multi-letter short name is never split.
      final whole = Cli(['-rf'])..flag('rf');
      expect(whole.has('rf'), isTrue);
      expect(whole.has('r'), isFalse);

      // Only all-letter tokens cluster.
      expect(Cli(['-p8']).has('p8'), isTrue);
    });

    test('a declared flag does not swallow the next token', () {
      final cli = Cli(['build', '--verbose', 'main.dart'])..flag('verbose');
      expect(cli.command, equals('build'));
      expect(cli.rest, equals(['main.dart']));
      expect(cli.has('verbose'), isTrue);

      // The same has to hold for declarations made before `parse`.
      system.cli
        ..flag('verbose', alias: 'v')
        ..parse(['build', '--verbose', 'main.dart']);
      expect(system.cli.command, equals('build'));
      expect(system.cli.rest, equals(['main.dart']));
    });

    test(
      'get resolves the command line, then env, then the declared default',
      () {
        final cli =
            Cli(const <String>[])
              ..option('out', def: 'dist')
              ..option('workers', def: 4)
              ..option('rate', def: 1.5)
              ..flag('cache', def: true);
        expect(cli.get('out', ''), equals('dist'));
        expect(cli.get('workers', 0), equals(4));
        expect(cli.get('rate', 0.0), closeTo(1.5, 0.001));
        expect(cli.get('cache', false), isTrue);

        // A default declared as text still converts.
        expect((Cli(const <String>[])..option('n', def: '8')).get('n', 0), 8);

        // The command line outranks the default.
        expect(
          (Cli(['--out', 'build'])..option('out', def: 'dist')).get('out', ''),
          equals('build'),
        );

        system.env.set('OUT_DIR', 'from-env');
        final env = Cli(const <String>[])
          ..option('out', env: 'OUT_DIR', def: 'dist');
        expect(env.get('out', ''), equals('from-env'));
        // ...but the command line still wins over the environment.
        final given = Cli(['--out', 'cli'])..option('out', env: 'OUT_DIR');
        expect(given.get('out', ''), equals('cli'));
        // Reaching a value through env is not the same as it being given.
        expect(env.has('out'), isFalse);
        system.env.clear();
      },
    );

    test('require accepts a default or an env variable as supplied', () {
      final withDef = Cli(const <String>[])
        ..option('out', def: 'dist', required: true);
      expect(() => withDef.require(), returnsNormally);

      final withEnv = Cli(const <String>[])
        ..option('token', env: 'API_TOKEN', required: true);
      expect(() => withEnv.require(), throwsA(isA<ArgumentError>()));
      system.env.set('API_TOKEN', 'secret');
      expect(() => withEnv.require(), returnsNormally);
      expect(withEnv.get('token', ''), equals('secret'));
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

    test('csv splits one value into repeats', () {
      final cli = Cli(['--tag=a, b ,c', '--tag', 'd'])
        ..option('tag', csv: true);
      expect(cli.all<String>('tag'), equals(['a', 'b', 'c', 'd']));

      // Without csv the comma is just part of the value.
      expect(Cli(['--tag=a,b']).all<String>('tag'), equals(['a,b']));
    });

    test('strict names switches no declaration covers', () {
      final cli =
          Cli(['--verbose', '--verbse', '--no-cache', '-f'])
            ..flag('verbose', alias: 'f')
            ..flag('cache');
      expect(cli.unknown(), equals(['verbse']));
      expect(
        () => cli.strict(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('--verbse'),
          ),
        ),
      );

      final clean = Cli(['--verbose'])..flag('verbose');
      expect(clean.unknown(), isEmpty);
      expect(() => clean.strict(), returnsNormally);
    });
  });

  group('Cli Commands', () {
    test(
      'run dispatches, scopes arguments and returns the exit code',
      () async {
        String? seen;
        final cli = Cli(['build', 'main.dart', '--out', 'build', '-r'])
          ..option('out', alias: 'o', def: 'dist', desc: 'Output directory');
        cli
            .handle('build', (sub) {
              seen =
                  '${sub.get('out', '')}|${sub.list()}|${sub.has('release')}';
              return 0;
            }, desc: 'Build the project')
            .flag('release', alias: 'r', desc: 'Optimise');

        expect(await cli.run(syntax: 'tool'), equals(0));
        // The command name is gone from the positionals, and the global option
        // and the command's own flag are both readable.
        expect(seen, equals('build|[main.dart]|true'));
      },
    );

    test('run resolves nested commands under a group', () async {
      var ran = '';
      final cli = Cli(['remote', 'add', 'origin', '--url=git@example.com']);
      final remote = cli.group('remote', desc: 'Manage remotes');
      remote
          .handle('add', (sub) {
            ran = '${sub.get('url', '')}|${sub.list()}';
            return 0;
          }, desc: 'Add a remote')
          .option('url', required: true);
      remote.handle('rm', (_) => 0, desc: 'Remove a remote');

      expect(await cli.run(syntax: 'tool'), equals(0));
      expect(ran, equals('git@example.com|[origin]'));
    });

    test('a handler result becomes the exit code', () async {
      Future<int> run(Object? result) =>
          (Cli(['go'])..handle('go', (_) => result)).run(syntax: 'tool');

      expect(await run(null), equals(0));
      expect(await run(true), equals(0));
      expect(await run(false), equals(1));
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
      final cli = Cli(['--out', 'x'])..option('out', desc: 'Output');
      final code = await cli.run(
        syntax: 'tool',
        body: (sub) {
          seen = sub.get('out', '');
          return null;
        },
      );
      expect(code, equals(0));
      expect(seen, equals('x'));
    });

    test('usage lists commands, defaults, env and allowed values', () {
      final cli =
          Cli(const <String>[])
            ..flag('verbose', alias: 'v', desc: 'Log every step')
            ..option('out', alias: 'o', def: 'dist', desc: 'Output directory')
            ..option('mode', desc: 'Build mode', allowed: ['debug', 'release'])
            ..option(
              'token',
              desc: 'API token',
              env: 'API_TOKEN',
              required: true,
            );
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
      expect(results, equals([10, 20, 30, 40]));
    });

    test('concurrent.run helper executes tasks', () async {
      final results = await concurrent.run(
        ['a', 'b', 'c'],
        (s) async => s.toUpperCase(),
        size: 3,
      );
      expect(results, equals(['A', 'B', 'C']));
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
          throwsA(isA<PoolFailure<int>>()),
        );
        // Every item was attempted, not just the ones before the first failure.
        expect(seen, equals([2, 4]));
      },
    );
  });

  group('Selector & Response extensions', () {
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

    test('QueryResult href, hrefs, src, srcs, lines, has', () {
      final q = html.$;
      expect(q.has('active'), isTrue);
      expect(q.has('missing'), isFalse);

      expect(
        q.find('a').matching(r'[href$=".mp3"]').href,
        equals('/track/1.mp3'),
      );
      expect(
        q.find('a').matching(r'[href$=".flac"]').href,
        equals('https://example.com/2.flac'),
      );
      expect(q.find('a').hrefs.length, equals(2));

      expect(q.find('img').src, equals('album.jpg'));
      expect(q.find('img').srcs.length, equals(1));

      final lines = q.find('.disc_lines').lines;
      expect(
        lines,
        equals(['01. First Song', '02. Second Song', '03. Third Song']),
      );

      expect(q.find('a').toList().length, equals(2));
      expect(q.find('a').matching(r'[href$=".mp3"]').length, equals(1));
    });

    test('Response provides QueryResult via \$ and \$xpath', () {
      final res = Response<void>(
        request: Request<void>(Uri.parse('https://example.com/sub/index.html')),
        bytes: html.codeUnits,
      );

      expect(res.$('a').href, equals('/track/1.mp3'));
      expect(res.$('img').src, equals('album.jpg'));
      expect(res.$xpath('//a').href, equals('/track/1.mp3'));
    });

    test('emit without an engine explains itself', () {
      final res = Response<String>(
        request: Request<String>('https://example.com'.url),
      );
      expect(
        () => res.emit('x'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no engine attached'),
          ),
        ),
      );
    });
  });

  group('Engine events and one-word methods', () {
    test('Engine on.start, on.item, on.done', () async {
      var started = false;
      var finished = false;
      final items = <String>[];

      final engine = Engine<String>(
        downloader: HttpDownloader<String>(),
        process: (res) => res.emit('Emitted: ${res.url.path}'),
      );
      engine.on.start(() => started = true);
      engine.on.item(items.add);
      engine.on.done((stats) => finished = true);

      final stats = await engine.run();
      expect(started, isTrue);
      expect(finished, isTrue);
      expect(stats.completed, equals(0));
      expect(items, isEmpty);
    });
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
    test('net.crawl builds a configured engine without running it', () {
      final engine =
          net.crawl<String>('https://example.com').concurrent(3).engine();
      expect(engine.downloader.concurrency, equals(3));
      expect(engine.running, isFalse);
    });

    test('an independent HttpClient carries its own settings', () async {
      final client = HttpClient(base: 'output', retries: 5);
      expect(client.base, equals('output'));
      expect(client.retries, equals(5));
      await client.close();
    });
  });
}
