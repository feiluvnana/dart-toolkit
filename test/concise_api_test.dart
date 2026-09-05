import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Cli Tests', () {
    test('Cli parses flags, aliases, options, and positional args with 1-word methods', () {
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
  });

  group('Pool Tests', () {
    test('Pool runs tasks concurrently with namespaced on events', () async {
      final pool = Pool(2);
      var started = false;
      var completed = false;
      final progressed = <int>[];

      pool.on.start(() => started = true);
      pool.on.progress((item) => progressed.add(item as int));
      pool.on.done(() => completed = true);

      final results = await pool.run<int, int>([1, 2, 3, 4], (item) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return item * 10;
      });

      expect(started, isTrue);
      expect(completed, isTrue);
      expect(progressed.length, equals(4));
      expect(results, equals([10, 20, 30, 40]));
    });

    test('concurrent.run helper executes tasks', () async {
      final results = await concurrent.run<String, String>(
        ['a', 'b', 'c'],
        (s) async => s.toUpperCase(),
        size: 3,
      );
      expect(results, equals(['A', 'B', 'C']));
    });
  });

  group('Selector & Response 1-word extensions', () {
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

    test('QueryResult link, links, src, srcs, lines, hasClass, list', () {
      final q = $(html);
      expect(q.hasClass('active'), isTrue);
      expect(q.hasClass('missing'), isFalse);

      expect(q.link('.mp3'), equals('/track/1.mp3'));
      expect(q.link('.flac'), equals('https://example.com/2.flac'));
      expect(q.links().length, equals(2));

      expect(q.src('.jpg'), equals('album.jpg'));
      expect(q.srcs().length, equals(1));

      final lines = q.find('.disc_lines').lines;
      expect(lines.length, equals(3));
      expect(lines[0], equals('01. First Song'));
      expect(lines[1], equals('02. Second Song'));
      expect(lines[2], equals('03. Third Song'));

      expect(q.find('a').list().length, equals(2));
      expect(q.find('a').filter('[href\$=".mp3"]').length, equals(1));
    });

    test('Response resolves relative URLs with link and src', () {
      final res = Response<void>(
        request: Request<void>.get('https://example.com/sub/index.html'),
        bytes: html.codeUnits,
      );

      expect(res.link('.mp3'), equals('https://example.com/track/1.mp3'));
      expect(res.link('.flac'), equals('https://example.com/2.flac'));
      expect(res.src('.jpg'), equals('https://example.com/sub/album.jpg'));
    });
  });

  group('Engine namespaced on events and 1-word methods', () {
    test('Engine on.start, on.response, on.done, on.item', () async {
      var engineStarted = false;
      var engineDone = false;
      final items = <String>[];

      final downloader = HttpDownloader<String>();
      final engine = Engine<String>(downloader: downloader);
      engine.on.start(() => engineStarted = true);
      engine.on.response((res, eng) {
        eng.emit('Emitted: ${res.request.url.path}');
      });
      engine.on.item((item) => items.add(item));
      engine.on.done((stats) => engineDone = true);

      expect(engine.on, isNotNull);
      final stats = await engine.run([]);
      expect(engineStarted, isTrue);
      expect(engineDone, isTrue);
      expect(stats.completed, equals(0));
    });
  });

  group('Condensed Namespaces', () {
    test('Fs.archive and Sys.listen', () {
      final arc = Fs.archive('test_sample.7z');
      expect(arc.exists, isFalse);
      expect(Archive.which(), isNotNull);
      expect(() => Sys.listen(), returnsNormally);

      // Namespaced io and system
      final arc2 = io.archive('test_sample2.7z');
      expect(arc2.exists, isFalse);
      expect(() => system.listen(), returnsNormally);
    });

    test('console.writer.table and console.bar', () {
      final t = util.console.writer.table(
        ['Col 1', 'Col 2'],
        [
          ['Val 1', 'Val 2'],
        ],
      );
      expect(t.render(), contains('Col 1'));
      expect(t.render(), contains('Val 1'));

      final bar = util.console.bar(10, 'Testing');
      expect(bar.total, equals(10));
    });

    test('console.logger sub-namespace provides logging methods', () {
      expect(util.console.logger, isA<ConsoleLogger>());
      expect(() => util.console.logger.info('Info message'), returnsNormally);
      expect(() => util.console.logger.ok('Success message'), returnsNormally);
      expect(() => util.console.logger.warn('Warn message'), returnsNormally);
      expect(() => util.console.logger.error('Error message'), returnsNormally);
      expect(() => util.console.logger.step(1, 1, 'Step message'), returnsNormally);
      expect(() => util.console.logger.debug('Debug message'), returnsNormally);
    });

    test('crawl accessor creates engine, dl, and parses DOM', () {
      final eng = net.crawl.engine<Object>();
      expect(eng, isNotNull);

      final dl = net.crawl.downloader<Object>(base: 'output');
      expect(dl.base, equals('output'));

      final q = net.crawl.query('<div><span>Toolkit</span></div>');
      expect(q.find('span').text, equals('Toolkit'));
    });
  });
}
