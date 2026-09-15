import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('v9.1 Enhancements and Bug Fixes', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('v91_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Environment.parse with escaped quotes and escape sequences', () {
      const content = '''
      # Comments should be ignored
      PLAIN=hello world
      QUOTED="hello \\"world\\""
      SINGLE_QUOTED='single \\'quoted\\''
      NEWLINES="line1\\nline2\\ttabbed"
      TRAILING=value # with comment
      ''';

      final parsed = env.parse(content);
      expect(parsed['PLAIN'], equals('hello world'));
      expect(parsed['QUOTED'], equals('hello "world"'));
      expect(parsed['SINGLE_QUOTED'], equals("single 'quoted'"));
      expect(parsed['NEWLINES'], equals('line1\nline2\ttabbed'));
      expect(parsed['TRAILING'], equals('value'));
    });

    test(
      'FileSystemEntry.path returns Path with extension type operations',
      () {
        final filePath = p.join(tempDir.path, 'note.txt');
        Path(filePath).sync.writeText('content');

        final entry = Path(filePath).stat!;
        expect(entry.path, isA<Path>());
        expect(entry.path, isA<String>());
        expect(entry.path.ext, equals('.txt'));
        expect(entry.path.name, equals('note.txt'));
        expect(entry.path.sync.readText(), equals('content'));
      },
    );

    test('SyncPath provides full symmetric inspection properties', () {
      final filePath = p.join(tempDir.path, 'file.txt');
      final dirPath = p.join(tempDir.path, 'sub');
      Path(filePath).sync.writeText('abc');
      Path(dirPath).sync.makeDir();

      final syncFile = Path(filePath).sync;
      expect(syncFile.exists, isTrue);
      expect(syncFile.isFile, isTrue);
      expect(syncFile.isDir, isFalse);
      expect(syncFile.size, equals(3));
      expect(syncFile.stat, isNotNull);

      final syncDir = Path(dirPath).sync;
      expect(syncDir.exists, isTrue);
      expect(syncDir.isFile, isFalse);
      expect(syncDir.isDir, isTrue);
    });

    test('Path.writeCsv accepts in-memory Iterable/List of row maps', () async {
      final csvPath = p.join(tempDir.path, 'output.csv');
      final rows = [
        {'id': '1', 'name': 'Alice'},
        {'id': '2', 'name': 'Bob'},
      ];

      await Path(csvPath).writeCsv(rows);
      expect(Path(csvPath).exists, isTrue);

      final readRecords = Path(csvPath).sync.csvRecords().toList();
      expect(readRecords.length, equals(2));
      expect(readRecords[0]['name'], equals('Alice'));
      expect(readRecords[1]['name'], equals('Bob'));
    });

    test('Json document boolean, integer, decimal, and isNotEmpty', () {
      final json =
          '{"active": true, "count": "42", "pi": "3.1415", "emptyList": []}'
              .parse(.json);
      expect(json.isNotEmpty, isTrue);
      expect(json.at('emptyList').isEmpty, isTrue);
      expect(json.at('emptyList').isNotEmpty, isFalse);

      expect(json.boolean('active'), isTrue);
      expect(json.flag('active'), isTrue);

      expect(json.integer('count'), equals(42));
      expect(json.decimal('pi'), closeTo(3.1415, 0.0001));
    });

    test('ArchiveEntry folder and isDir/isFile/path aliases', () {
      const dirEntry = ArchiveEntry('docs/', 0, folder: true);
      expect(dirEntry.folder, isTrue);
      expect(dirEntry.isDir, isTrue);
      expect(dirEntry.isFile, isFalse);
      expect(dirEntry.path, equals('docs/'));

      const fileEntry = ArchiveEntry('docs/readme.txt', 100, folder: false);
      expect(fileEntry.folder, isFalse);
      expect(fileEntry.isDir, isFalse);
      expect(fileEntry.isFile, isTrue);
      expect(fileEntry.path, equals('docs/readme.txt'));
    });

    test('Fetch and Response.follow allow Map as meta', () {
      final fetch = Fetch(
        Uri.parse('https://example.com'),
        meta: {'userId': 123, 'role': 'admin'},
      );
      expect(fetch.meta['userId'], equals(123));
      expect(fetch.meta['role'], equals('admin'));

      final res = Response.text('<h1>hi</h1>', fetch: fetch);
      final followed = res.follow('/sub', meta: {'page': 2});
      expect(followed.meta['page'], equals(2));
      expect(followed.url.toString(), equals('https://example.com/sub'));
    });

    test('Response.form direct form selector extraction', () {
      const html = '''
      <html><body>
        <form id="login" action="/auth" method="POST">
          <input type="text" name="user" value="ada">
        </form>
      </body></html>
      ''';
      final res = Response.text(
        html,
        fetch: Fetch(Uri.parse('https://example.com/page')),
      );

      final form = res.form('#login');
      expect(form, isNotNull);
      expect(form!.action, equals(Uri.parse('https://example.com/auth')));
      expect(form.fields['user'], equals('ada'));

      final fetch = form.fill({'user': 'grace'}).fetch();
      expect(fetch.url, equals(Uri.parse('https://example.com/auth')));
      expect(fetch.method, equals(HttpMethod.post));
    });

    test('Console.table renders correctly', () {
      final buf = StringBuffer();
      final writer = ConsoleWriter(out: buf, tty: false);
      writer.table(
        headers: ['Item', 'Qty'],
        rows: [
          ['Apples', 5],
          ['Oranges', 10],
        ],
      );

      final output = buf.toString();
      expect(output, contains('Item'));
      expect(output, contains('Qty'));
      expect(output, contains('Apples'));
      expect(output, contains('Oranges'));
    });

    test('Spinner.run executes action and returns result', () async {
      final buf = StringBuffer();
      final writer = ConsoleWriter(out: buf, tty: false);

      final result = await Spinner.run(
        'Processing...',
        () async => 42,
        writer: writer,
      );
      expect(result, equals(42));
      expect(buf.toString(), contains('✔'));
    });

    test(
      'CliParser with custom onExit does not terminate process on autoHelp',
      () {
        int? exitCode;
        final parser = CliParser(onExit: (code) => exitCode = code);

        parser.parse(['--help'], autoHelp: true);
        expect(exitCode, equals(0));
      },
    );

    test(
      'ServerRequest and ServerResponse typedef aliases and serve onError',
      () async {
        Object? reportedError;
        final server = await serve(0, (ServerRequest req) {
          if (req.path == '/fail') throw StateError('simulated error');
          return const ServerResponse.text('hello');
        }, onError: (err, st) => reportedError = err);
        addTearDown(server.close);

        final client = Fetcher();
        addTearDown(client.close);

        final okRes = await client.get(
          Uri.parse('http://localhost:${server.port}/ok'),
        );
        expect(okRes.statusCode, equals(200));
        expect(okRes.text, equals('hello'));

        final errRes = await client.get(
          Uri.parse('http://localhost:${server.port}/fail'),
        );
        expect(errRes.statusCode, equals(500));
        expect(reportedError, isA<StateError>());
      },
    );

    test('Crawler next callback supports async FutureOr', () async {
      final visited = <String>[];
      final crawler = crawl(
        ['https://example.com/start'.url],
        next: (Response res) async {
          await delay(10.ms);
          if (res.url.path == '/start') {
            return [res.follow('/next')];
          }
          return [];
        },
        send: (fetch) async {
          visited.add(fetch.url.path);
          return Response.text('ok', fetch: fetch);
        },
      );

      await crawler.run();
      expect(visited, equals(['/start', '/next']));
    });

    test('StreamExtensions.parallelMap bounds concurrency strictly', () async {
      var currentActive = 0;
      var maxActive = 0;

      final results = await Stream.fromIterable([1, 2, 3, 4, 5]).parallelMap((
        n,
      ) async {
        currentActive++;
        if (currentActive > maxActive) maxActive = currentActive;
        await delay(20.ms);
        currentActive--;
        return n * 10;
      }, concurrency: 2).toList();

      expect(results, equals([10, 20, 30, 40, 50]));
      expect(maxActive, lessThanOrEqualTo(2));
    });

    test('Stream.parallelMap with concurrency 1 never overlaps', () async {
      var currentActive = 0;
      var maxActive = 0;
      await Stream.fromIterable([1, 2, 3]).parallelMap((n) async {
        currentActive++;
        if (currentActive > maxActive) maxActive = currentActive;
        await delay(15.ms);
        currentActive--;
        return n;
      }, concurrency: 1).drain<void>();
      expect(maxActive, equals(1));
    });

    test('streamed Response does not silently yield empty bytes', () async {
      final res = Response.stream(
        Stream.fromIterable([
          [1, 2],
          [3],
        ]),
        url: Uri.parse('https://example.com/file'),
      );
      expect(res.isStreamed, isTrue);
      expect(() => res.bytes, throwsStateError);
      expect(() => res.body, throwsStateError);
      expect(await res.readBytes(), equals([1, 2, 3]));
      expect(res.isStreamed, isFalse);
      expect(res.bytes, equals([1, 2, 3]));
    });

    test('Response.save returns a Path', () async {
      final dest = p.join(tempDir.path, 'page.html');
      final saved = await Response.text('<p>hi</p>').save(dest);
      expect(saved, isA<Path>());
      expect(saved.sync.readText(), contains('hi'));
    });

    test('empty lock file is treated as stale, not permanent', () async {
      final lockPath = p.join(tempDir.path, 'app.lock');
      File(lockPath).writeAsStringSync('');
      final result = await Path(lockPath).lock(() async => 7);
      expect(result, equals(7));
      expect(File(lockPath).existsSync(), isFalse);
    });

    test('Path.dirSize and isDirEmpty are methods', () async {
      final dir = Path(tempDir.path);
      expect(await dir.isDirEmpty(), isTrue);
      await (dir / 'a.txt').writeText('abcd');
      expect(await dir.isDirEmpty(), isFalse);
      expect(await dir.dirSize(), equals(4));
      expect(dir.sync.dirSize(), equals(4));
    });

    test('retry defaults to three extra attempts', () async {
      var calls = 0;
      await expectLater(
        retry(() async {
          calls++;
          throw StateError('nope');
        }, backoff: const Duration(milliseconds: 1)),
        throwsStateError,
      );
      expect(calls, equals(4));
    });
  });

  group('v9.2 hardening', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('v92_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('deleting a link to a directory does not reach the target', () async {
      final target = Path(p.join(tempDir.path, 'target'));
      await target.makeDir();
      await (target / 'keep.txt').writeText('precious');
      final link = Path(p.join(tempDir.path, 'link'));
      await link.linkTo(target);

      expect(await link.delete(), isTrue);
      expect(link.exists, isFalse);
      expect((target / 'keep.txt').exists, isTrue, reason: 'target survives');
    });

    test('a dangling link can still be deleted', () async {
      final link = Path(p.join(tempDir.path, 'dangling'));
      await link.linkTo(p.join(tempDir.path, 'nothing-here'));
      expect(await link.delete(), isTrue);
      expect(link.isLink, isFalse);
    });

    test('concurrency survives a robots lookup on a single seed', () async {
      var active = 0;
      var peak = 0;
      final crawler = crawl(
        ['https://c.test/'.url],
        concurrency: 4,
        robots: .obey('Bot/1.0'),
        next: (Response res) => res.url.path == '/'
            ? [for (var i = 0; i < 4; i++) res.follow('/page$i')]
            : const <Fetch>[],
        send: (fetch) async {
          if (fetch.url.path == '/robots.txt') {
            return Response.text('User-agent: *\nAllow: /', fetch: fetch);
          }
          active++;
          peak = active > peak ? active : peak;
          await delay(60.ms);
          active--;
          return Response.text('<p>ok</p>', fetch: fetch);
        },
      );

      final stats = await crawler.run();
      expect(stats.fetched, equals(5));
      expect(peak, greaterThan(1), reason: 'more than one worker ran');
    });

    test('env keeps an escaped backslash out of the escape that follows', () {
      final parsed = env.parse(
        r'WIN="C:\\temp"'
        '\n'
        r'LIT="a\\nb"',
      );
      expect(parsed['WIN'], equals(r'C:\temp'));
      expect(parsed['LIT'], equals(r'a\nb'));
    });

    test('Json reads out of range as null rather than throwing', () {
      final doc = '[1,2]'.parse(.json);
      expect(doc[99], isNull);
      expect(doc[-1], isNull);
      expect(doc[0], equals(1));
      expect(
        '{"a":1,"b":"x"}'.parse(.json).toMap<String>(),
        equals({'b': 'x'}),
      );
      expect('[1,"x",2]'.parse(.json).toList<int>(), equals([1, 2]));
    });

    test('a sitemap round-trips a url with a query string', () {
      final url = 'https://e.test/search?q=a&b=1'.url;
      final xml = const SitemapFormat().format([url]);
      expect(xml, contains('q=a&amp;b=1'));
      expect(xml.parse(.sitemap), equals([url]));
      expect(const SitemapFormat().nested('<SITEMAPINDEX>'), isTrue);
    });

    test('a form submits one hop deeper than the page it came from', () {
      final res = Response.text(
        '<form id="f" action="/next" method="POST"></form>',
        fetch: Fetch('https://e.test/a'.url, depth: 2),
      );
      expect(res.form('#f')!.fetch().depth, equals(3));
      expect(res.form('#f')!.fetch(depth: 0).depth, equals(0));
    });

    test('a missing file hashes as the empty input', () async {
      final absent = Path(p.join(tempDir.path, 'nope.bin'));
      const emptySha =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
      expect(await absent.hash(), equals(emptySha));
      expect(absent.sync.hash(), equals(emptySha));
    });

    test('resume entries without a url are refused', () {
      expect(() => Fetch.fromJson(const {'url': ''}), throwsFormatException);
      expect(() => Fetch.fromJson(const {}), throwsFormatException);
    });

    test('expanded reads names loadEnv put in the environment', () {
      env['DT_EXPAND_ROOT'] = p.join(tempDir.path, 'root');
      addTearDown(() => env.remove('DT_EXPAND_ROOT'));
      expect(
        Path(r'$DT_EXPAND_ROOT/out').expanded,
        equals(p.join(tempDir.path, 'root', 'out')),
      );
    });

    test('a watcher reports what its callback throws', () async {
      final dir = Path(tempDir.path);
      final errors = <Object>[];
      final stop = dir.watch(
        (_) => throw StateError('handler blew up'),
        settle: Duration.zero,
        onError: (error, _) => errors.add(error),
      );
      addTearDown(stop);
      await delay(120.ms);
      await (dir / 'poke.txt').writeText('x');
      await delay(400.ms);
      expect(errors, isNotEmpty);
      expect(errors.first, isA<StateError>());
    });

    test('which finds an executable inside a directory it is given', () {
      final bin = Path(p.join(tempDir.path, 'bin'));
      bin.sync.makeDir();
      (bin / 'mytool').sync.writeText('#!/bin/sh\n');
      expect(which('mytool', paths: [bin]), equals(p.join(bin, 'mytool')));
    });
  });
}
