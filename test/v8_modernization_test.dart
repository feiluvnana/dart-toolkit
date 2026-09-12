import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('v8.0.0 Top-Level I/O Modernization', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('v8_io_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('writeText, readText, writeTextSync, readTextSync', () async {
      final filePath = p.join(tempDir.path, 'sub', 'test.txt');

      // Async write & read
      final entry = await writeText(filePath, 'hello world');
      expect(entry.exists, isTrue);
      expect(entry.name, equals('test.txt'));
      expect(await readText(filePath), equals('hello world'));
      expect(fileExists(filePath), isTrue);

      // Sync write & read
      final syncPath = p.join(tempDir.path, 'sub2', 'sync.txt');
      final syncEntry = writeTextSync(syncPath, 'sync content');
      expect(syncEntry.exists, isTrue);
      expect(readTextSync(syncPath), equals('sync content'));
      expect(fileStat(syncPath), isNotNull);
    });

    test('writeLines, readLines, writeLinesSync, readLinesSync', () async {
      final filePath = p.join(tempDir.path, 'lines.txt');
      await writeLines(filePath, ['line 1', 'line 2', 'line 3']);

      final lines = await readLines(filePath);
      expect(lines, equals(['line 1', 'line 2', 'line 3']));

      final syncPath = p.join(tempDir.path, 'lines_sync.txt');
      writeLinesSync(syncPath, ['a', 'b']);
      expect(readLinesSync(syncPath), equals(['a', 'b']));
    });

    test('writeJson, readJson, writeJsonSync, readJsonSync', () async {
      final filePath = p.join(tempDir.path, 'data.json');
      final data = {'name': 'dart-toolkit', 'version': '8.0.0', 'items': [1, 2, 3]};

      await writeJson(filePath, data);
      final readData = await readJson(filePath) as Map<String, dynamic>;
      expect(readData['name'], equals('dart-toolkit'));
      expect((readData['items'] as List)[1], equals(2));

      final syncPath = p.join(tempDir.path, 'data_sync.json');
      writeJsonSync(syncPath, {'score': 42});
      final syncData = readJsonSync(syncPath) as Map<String, dynamic>;
      expect(syncData['score'], equals(42));
    });

    test('listDir, listDirSync, walkDir, walkDirSync, makeDir, copyPath, removePath', () async {
      final base = p.join(tempDir.path, 'listing');
      makeDirSync(p.join(base, 'a'));
      makeDirSync(p.join(base, 'b'));
      writeTextSync(p.join(base, 'a', 'file1.txt'), 'f1');
      writeTextSync(p.join(base, 'b', 'file2.md'), 'f2');

      final listAsync = await listDir(base);
      expect(listAsync.length, equals(2));

      final listSyncRes = listDirSync(base);
      expect(listSyncRes.length, equals(2));

      final walkAsyncRes = await walkDir(base);
      expect(walkAsyncRes.length, greaterThanOrEqualTo(4));

      final walkSyncRes = walkDirSync(base, match: '*.txt');
      expect(walkSyncRes.length, equals(1));
      expect(walkSyncRes.first.name, equals('file1.txt'));

      // copyPath
      final copied = await copyPath(p.join(base, 'a', 'file1.txt'), p.join(base, 'a', 'file1_copy.txt'));
      expect(copied.exists, isTrue);
      expect(fileExists(copied.path), isTrue);

      // removePath
      final removed = await removePath(copied.path);
      expect(removed, isTrue);
      expect(fileExists(copied.path), isFalse);
    });

    test('withLock and withLockSync', () async {
      final lockFile = p.join(tempDir.path, 'resource.lock');

      var executedSync = false;
      withLockSync(lockFile, () {
        executedSync = true;
      });
      expect(executedSync, isTrue);

      var executedAsync = false;
      await withLock(lockFile, () async {
        await delay(10.ms);
        executedAsync = true;
      });
      expect(executedAsync, isTrue);
    });
  });

  group('v8.0.0 Collections & Stream Extensions', () {
    test('Iterable parallelMap and settle', () async {
      final items = [1, 2, 3, 4, 5];
      final doubled = await items.parallelMap((n) async {
        await delay(5.ms);
        return n * 2;
      }, concurrency: 2);
      expect(doubled, equals([2, 4, 6, 8, 10]));

      final mixed = [1, 2, 3];
      final settled = await mixed.settle((n) async {
        if (n == 2) throw Exception('fail');
        return n * 10;
      }, concurrency: 2);

      expect(settled.length, equals(3));
      expect(settled[0].isDone, isTrue);
      expect(settled[0].value, equals(10));
      expect(settled[1].isBroke, isTrue);
      expect(settled[1].value, isNull);
      expect(settled[2].isDone, isTrue);
      expect(settled[2].value, equals(30));
    });

    test('Stream parallelMap', () async {
      final stream = Stream.fromIterable([10, 20, 30]);
      final results = await stream.parallelMap((n) async {
        await delay(5.ms);
        return n + 1;
      }, concurrency: 2).toList();
      expect(results, equals([11, 21, 31]));
    });

    test('Iterable fluent helpers', () {
      final words = ['apple', 'banana', 'avocado', 'apricot', 'blueberry'];
      expect(words.filter((w) => w.startsWith('a')), equals(['apple', 'avocado', 'apricot']));

      expect(words.sortedBy((w) => w.length), equals(['apple', 'banana', 'avocado', 'apricot', 'blueberry']));
      expect(words.sortedByDescending((w) => w.length).first, equals('blueberry'));

      final duplicates = ['a', 'b', 'a', 'c', 'b'];
      expect(duplicates.distinct(), equals(['a', 'b', 'c']));
      expect(words.distinct((w) => w[0]), equals(['apple', 'banana']));

      expect([1, 2, 3, 4, 5].chunk(2), equals([[1, 2], [3, 4], [5]]));
      expect([1, 2, 3, 4].window(2), equals([[1, 2], [2, 3], [3, 4]]));

      final grouped = words.groupBy((w) => w[0]);
      expect(grouped['a']?.length, equals(3));
      expect(grouped['b']?.length, equals(2));

      final counts = words.countBy((w) => w[0]);
      expect(counts['a'], equals(3));
      expect(counts['b'], equals(2));

      final nullables = ['1', '', '2', '', '3'];
      final filtered = nullables.mapNotNull((s) => s.isEmpty ? null : int.parse(s));
      expect(filtered, equals([1, 2, 3]));
    });
  });

  group('v8.0.0 Modern Concurrency & Rate Limiter', () {
    test('parallelMap and settle top-level functions', () async {
      final res = await parallelMap([1, 2, 3], (n) => n * 3, concurrency: 2);
      expect(res, equals([3, 6, 9]));

      final settled = await settle([1, 2], (n) {
        if (n == 2) throw StateError('err');
        return n;
      });
      expect(settled[0].isDone, isTrue);
      expect(settled[1].isBroke, isTrue);
    });

    test('retry with exponential backoff', () async {
      var attempts = 0;
      final result = await retry(() async {
        attempts++;
        if (attempts < 3) throw SocketException('network transient');
        return 'success';
      }, retries: 3, backoff: 5.ms);

      expect(result, equals('success'));
      expect(attempts, equals(3));
    });

    test('RateLimiter enforces throttle', () async {
      final limiter = RateLimiter(5, per: 100.ms);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 3; i++) {
        await limiter.acquire();
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(200));
    });
  });

  group('v8.0.0 Modern HTTP & Response DX', () {
    late HttpServer server;
    late String baseUrl;

    setUp(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      baseUrl = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        if (req.uri.path == '/json') {
          req.response
            ..headers.contentType = ContentType.json
            ..write('{"status": "ok", "count": 42}')
            ..close();
        } else if (req.uri.path == '/html') {
          req.response
            ..headers.contentType = ContentType.html
            ..write('''
              <!DOCTYPE html>
              <html>
                <head><title>Test Page</title></head>
                <body>
                  <h1 class="title">Welcome</h1>
                  <ul class="items">
                    <li>Item 1</li>
                    <li>Item 2</li>
                  </ul>
                  <a href="/about">About</a>
                </body>
              </html>
            ''')
            ..close();
        } else if (req.uri.path == '/echo') {
          final body = await utf8.decodeStream(req);
          req.response
            ..headers.contentType = ContentType.text
            ..write('ECHO: $body')
            ..close();
        } else {
          req.response
            ..statusCode = HttpStatus.notFound
            ..write('Not found')
            ..close();
        }
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('Top-level get with Response properties and HTML selector shortcuts', () async {
      final res = await get('$baseUrl/html');
      expect(res.statusCode, equals(200));
      expect(res.ok, isTrue);
      expect(res.text, contains('Welcome'));

      // DOM selectors shorthand
      final h1 = res.$('h1.title');
      expect(h1.text, equals('Welcome'));

      final listItems = res.$$('ul.items > li');
      expect(listItems.length, equals(2));
      expect(listItems.map((e) => e.text).toList(), equals(['Item 1', 'Item 2']));
    });

    test('Top-level get and post with JSON and text', () async {
      final res = await get('$baseUrl/json');
      expect(res.ok, isTrue);
      expect(res.json['status'], equals('ok'));
      expect(res.json['count'], equals(42));

      final postRes = await post('$baseUrl/echo', body: 'hello server');
      expect(postRes.ok, isTrue);
      expect(postRes.text, equals('ECHO: hello server'));
    });

    test('Response typedef is fully compatible with Reply', () {
      Response r = Reply(
        url: Uri.parse('http://example.com'),
        status: 200,
        headers: {},
        bytes: utf8.encode('{"a": 1}'),
      );
      expect(r.statusCode, equals(200));
      expect(r.ok, isTrue);
      expect(r.json['a'], equals(1));
    });
  });

  group('v8.0.0 CLI Parser Modernization', () {
    test('CliParser parses flags, options, numbers, lists with defaults', () {
      final parser = CliParser(description: 'Test CLI Tool')
        ..flag('verbose', abbr: 'v', help: 'Verbose output')
        ..flag('dry-run', abbr: 'n', defaultsTo: false)
        ..option('config', abbr: 'c', defaultsTo: 'app.yaml')
        ..number('port', abbr: 'p', defaultsTo: 8080)
        ..list('tags', abbr: 't');

      final parsed = parser.parse(['-v', '--port', '9000', '-t', 'web,api', 'file.txt']);

      expect(parsed.flag('verbose'), isTrue);
      expect(parsed.flag('dry-run'), isFalse);
      expect(parsed.option('config'), equals('app.yaml'));
      expect(parsed.number('port'), equals(9000));
      expect(parsed.list('tags'), equals(['web', 'api']));
      expect(parsed.rest, equals(['file.txt']));

      // Usage text check
      final usage = parser.usage();
      expect(usage, contains('-v, --verbose'));
      expect(usage, contains('-c, --config'));
      expect(usage, contains('default: 8080'));
    });
  });

  group('v8.0.0 Utility Extensions & Helpers', () {
    test('String extensions: toSlug, cleanWhitespace, clip, extractNumber, stripTags', () {
      expect('Hello World! 2026'.toSlug(), equals('hello-world-2026'));
      expect('  hello \t  \n world  '.cleanWhitespace(), equals('hello world'));
      expect('<p>Hello <b>World</b></p>'.stripTags(), equals('Hello World'));
      expect('Very long title here'.clip(9), equals('Very lon…'));
      expect('Very long title here'.clip(9, ellipsis: '...'), equals('Very l...'));
      expect('Price is \$49.99 today'.extractNumber(), equals(49.99));
    });

    test('Size extensions & formatBytes / parseBytes', () {
      expect(1024.bytes.formatted(), equals('1.0 KiB'));
      expect(formatBytes(1048576), equals('1.0 MiB'));
      expect(parseBytes('1.5 MB'), equals(1500000));
      expect(parseBytes('2 GiB'), equals(2 * 1024 * 1024 * 1024));
    });

    test('Time & Duration extensions', () {
      expect(500.ms, equals(const Duration(milliseconds: 500)));
      expect(10.seconds, equals(const Duration(seconds: 10)));
      expect(2.minutes, equals(const Duration(minutes: 2)));
      expect(1.hours, equals(const Duration(hours: 1)));
      expect(3.days, equals(const Duration(days: 3)));

      expect(formatDuration(const Duration(seconds: 65)), equals('01:05'));
      expect(timestamp(), isNotEmpty);
      expect(parseTime('2026-09-12T12:00:00Z'), isNotNull);
    });

    test('Hashing functions: sha256Hash, md5Hash, hmacSha256', () {
      expect(sha256Hash('hello'), equals('2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'));
      expect(md5Hash('hello'), equals('5d41402abc4b2a76b9719d911017c592'));
      expect(hmacSha256('secret', 'message'), isNotEmpty);
    });

    test('Random helpers', () {
      final list = [1, 2, 3, 4, 5];
      expect(randomPick(list), isIn(list));
      expect(randomBetween(10, 20), inInclusiveRange(10, 20));
      expect(randomId(16).length, equals(16));
    });
  });

  group('v8.0.0 Formats Helpers', () {
    test('parseJson and toJsonString', () {
      final json = parseJson('{"name": "test", "num": 10}');
      expect(json['name'], equals('test'));
      expect(toJsonString({'a': 1}), contains('"a": 1'));
    });

    test('parseYaml and toYamlString', () {
      final yaml = parseYaml('name: toolkit\ncount: 5');
      expect(yaml['name'], equals('toolkit'));
      expect(toYamlString({'name': 'toolkit'}), contains('name: toolkit'));
    });

    test('parseCsv and toCsvString', () {
      final csv = parseCsv('a,b,c\n1,2,3\n4,5,6');
      expect(csv.length, equals(2));
      expect(csv[0], equals(['1', '2', '3']));
      expect(toCsvString([['x', 'y'], ['1', '2']]), contains('x,y'));
    });

    test('parseRobots and parseSitemap', () {
      final robots = parseRobots('User-agent: *\nDisallow: /private');
      expect(robots.allowed(Uri.parse('https://example.com/public')), isTrue);
      expect(robots.allowed(Uri.parse('https://example.com/private')), isFalse);

      final sitemap = parseSitemap('''
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://example.com/</loc></url>
        </urlset>
      ''');
      expect(sitemap, contains(Uri.parse('https://example.com/')));
    });
  });

  group('v8.0.0 System Helpers', () {
    test('env and which', () {
      expect(env['PATH'] ?? env['Path'], isNotNull);
      expect(env.get('NON_EXISTENT_KEY_123', 'default_val'), equals('default_val'));

      final dartExe = which('dart');
      expect(dartExe, isNotNull);
    });

    test('run subprocess with ok getter', () async {
      final res = await run('dart', ['--version']);
      expect(res.ok, isTrue);
      expect(res.exitCode, equals(0));
    });
  });

  group('v8.0.0 Discoverable Static Helper Hubs', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('v8_static_hub_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Files & IO static hubs', () async {
      final file = p.join(tempDir.path, 'note.txt');
      await Files.writeText(file, 'static hub content');
      expect(Files.exists(file), isTrue);
      expect(Files.isFile(file), isTrue);
      expect(await Files.readText(file), equals('static hub content'));
      expect(Files.readTextSync(file), equals('static hub content'));

      // Alias IO
      expect(await IO.readText(file), equals('static hub content'));

      final jsonFile = p.join(tempDir.path, 'data.json');
      await Files.writeJson(jsonFile, {'status': 'ok'});
      final data = await Files.readJson(jsonFile) as Map<String, dynamic>;
      expect(data['status'], equals('ok'));

      final list = await Files.list(tempDir.path);
      expect(list.length, equals(2));
    });

    test('Http static hub', () async {
      expect(Http.client, isNotNull);

      // We can also test Http.crawl creation
      final crawler = Http.crawl(['https://example.com']);
      expect(crawler, isNotNull);

      // Verify serveOnce
      final server = await HttpServer.bind('localhost', 0);
      server.listen((req) {
        req.response.write('ok from local');
        req.response.close();
      });

      try {
        final res = await Http.get('http://${server.address.host}:${server.port}');
        expect(res.ok, isTrue);
        expect(res.text, equals('ok from local'));
      } finally {
        await server.close();
      }
    });

    test('System & Sys static hubs', () async {
      final res = await System.run('dart', ['--version']);
      expect(res.ok, isTrue);

      final whichDart = System.which('dart');
      expect(whichDart, isNotNull);

      // Sys alias
      expect(Sys.which('dart'), equals(whichDart));
      expect(System.env, isNotNull);
    });

    test('Env static hub', () {
      Env.set('V8_TEST_KEY', 'v8_secret_val');
      expect(Env.has('V8_TEST_KEY'), isTrue);
      expect(Env.read('V8_TEST_KEY'), equals('v8_secret_val'));
      expect(Env.get('V8_TEST_KEY', 'default'), equals('v8_secret_val'));
      expect(Env.get('MISSING_KEY_999', 'fallback'), equals('fallback'));
      expect(Env.require('V8_TEST_KEY'), equals('v8_secret_val'));

      Env.delete('V8_TEST_KEY');
      expect(Env.has('V8_TEST_KEY'), isFalse);
    });

    test('Concurrent static hub', () async {
      final items = [1, 2, 3, 4];
      final squares = await Concurrent.map(items, (n) async => n * n, concurrency: 2);
      expect(squares, equals([1, 4, 9, 16]));

      final settled = await Concurrent.settle(items, (n) async {
        if (n == 3) throw Exception('bad number 3');
        return n * 10;
      });
      expect(settled.length, equals(4));
      expect(settled[0].isDone, isTrue);
      expect(settled[2].isBroke, isTrue);

      var retryCount = 0;
      final retryRes = await Concurrent.retry(() async {
        retryCount++;
        if (retryCount < 2) throw Exception('fail once');
        return 'success';
      }, retries: 2, backoff: const Duration(milliseconds: 10));
      expect(retryRes, equals('success'));
      expect(retryCount, equals(2));

      await Concurrent.delay(const Duration(milliseconds: 1));
      final limiter = Concurrent.rate(5);
      expect(limiter.count, equals(5));
    });

    test('Formats static hub', () {
      final jsonDoc = Formats.json('{"version": 8}');
      expect(jsonDoc['version'], equals(8));
      expect(Formats.toJson({'hello': 'world'}), contains('"hello": "world"'));

      final html = Formats.html('<html><body><h1 class="title">Header</h1></body></html>');
      expect(html.$('h1').text, equals('Header'));

      final yaml = Formats.yaml('project: dart-toolkit');
      expect(yaml['project'], equals('dart-toolkit'));
      expect(Formats.toYaml({'a': 1}), contains('a: 1'));

      final csv = Formats.csv('id,name\n1,Alice');
      expect(csv.length, equals(1));
      expect(csv[0], equals(['1', 'Alice']));
      expect(Formats.toCsv([{'id': 1, 'name': 'Alice'}]), contains('Alice'));

      final robots = Formats.robots('User-agent: *\nDisallow: /secret');
      expect(robots.allowed(Uri.parse('https://example.com/secret')), isFalse);
      expect(robots.allowed(Uri.parse('https://example.com/open')), isTrue);

      final sitemap = Formats.sitemap('''
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://example.com/page</loc></url>
        </urlset>
      ''');
      expect(sitemap, contains(Uri.parse('https://example.com/page')));
    });

    test('Text static hub', () {
      expect(Text.slug('Hello, World! 2026'), equals('hello-world-2026'));
      expect(Text.clean('  multi   space   text  '), equals('multi space text'));
      expect(Text.clip('very long content string', 9), equals('very lon…'));
      expect(Text.extractNumber(r'Total: $1,234.50 USD'), equals(1234.5));
      expect(Text.stripTags('<p>Clean <b>text</b></p>'), equals('Clean text'));
    });

    test('Time static hub', () {
      expect(Time.format(const Duration(minutes: 5, seconds: 30)), equals('05:30'));
      expect(Time.format(const Duration(hours: 1, minutes: 2, seconds: 3)), equals('01:02:03'));
      expect(Time.stamp(), matches(RegExp(r'^\d{8}_\d{6}$')));
      expect(Time.ago(DateTime.now().subtract(const Duration(minutes: 10))), contains('m ago'));

      final parsed = Time.parse('2026-09-12');
      expect(parsed?.year, equals(2026));
      expect(parsed?.month, equals(9));
      expect(parsed?.day, equals(12));
    });

    test('Hash static hub', () {
      final sha = Hash.sha256('dart-toolkit');
      expect(sha.length, equals(64));

      final md5 = Hash.md5('dart-toolkit');
      expect(md5.length, equals(32));

      final sig = Hash.hmac('secret-key', 'data-payload');
      expect(sig.length, equals(64));
    });

    test('Size static hub', () {
      expect(Size.format(1024), equals('1.0 KiB'));
      expect(Size.format(1048576), equals('1.0 MiB'));
      expect(Size.parse('1.0 MiB'), equals(1048576));
      expect(Size.parse('500 B'), equals(500));
    });

    test('Rand static hub', () {
      final list = [10, 20, 30, 40];
      final picked = Rand.pick(list);
      expect(list, contains(picked));

      final shuffled = Rand.shuffle(list);
      expect(shuffled.length, equals(4));
      expect(shuffled, containsAll(list));

      final between = Rand.between(5, 15);
      expect(between, greaterThanOrEqualTo(5));
      expect(between, lessThan(15));

      final id = Rand.id(16);
      expect(id.length, equals(16));

      final jittered = Rand.jitter(const Duration(seconds: 1));
      expect(jittered, greaterThanOrEqualTo(const Duration(seconds: 1)));
    });
  });
}
