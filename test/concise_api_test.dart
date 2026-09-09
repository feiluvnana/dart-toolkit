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
