import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Console & Terminal Namespaces', () {
    test('namespaced Console.terminal.width and height', () {
      expect(Console.terminal.width, greaterThan(0));
      expect(Console.terminal.height, greaterThan(0));
      expect(util.console.terminal.width, greaterThan(0));
    });

    test('console.writer formats box and table', () {
      final table = util.console.writer.table(
        ['A', 'B'],
        [
          ['1', '2'],
        ],
      );
      expect(table.render(), contains('A'));
      expect(table.render(), contains('1'));

      // Check box method doesn't throw
      util.console.writer.box('Hello World\nLine 2', title: 'Box Title');
      util.console.writer.rule('Test Rule');
    });

    test('console.reader and console.logger are accessible and console.logger.task runs task', () async {
      expect(util.console.reader, isNotNull);
      expect(util.console.logger, isNotNull);
      expect(Console.logger, isNotNull);
      final res = await util.console.logger.task(
        'Running quick task',
        () async => 42,
      );
      expect(res, equals(42));
    });

    test('console.logger methods execute without errors', () {
      expect(() => util.console.logger.info('Test info'), returnsNormally);
      expect(() => util.console.logger.ok('Test ok'), returnsNormally);
      expect(() => util.console.logger.warn('Test warn'), returnsNormally);
      expect(() => util.console.logger.error('Test error'), returnsNormally);
      expect(() => util.console.logger.step(1, 2, 'Test step'), returnsNormally);
      expect(() => util.console.logger.debug('Test debug'), returnsNormally);
      expect(() => util.console.logger.write(''), returnsNormally);
      expect(() => util.console.logger.writeln('Test line'), returnsNormally);
    });
  });

  group('Ansi Utilities', () {
    test('strip removes ANSI sequences', () {
      Ansi.enabled = true;
      final styled = 'Hello'.red().bold();
      expect(Ansi.strip(styled), equals('Hello'));
      expect(Ansi.visibleLength(styled), equals(5));
      expect(styled.stripAnsi, equals('Hello'));
      expect(styled.visibleLength, equals(5));
    });
  });

  group('io Domain & Fs Utilities', () {
    test('io.sanitize removes or replaces illegal characters (1-word)', () {
      const raw = 'Key: "Box" / 20th * Edition? <Special> | Path\\';

      // Default ASCII replacement
      final sanitizedAscii = io.sanitize(raw);
      expect(sanitizedAscii.contains(':'), isFalse);
      expect(sanitizedAscii.contains('"'), isFalse);
      expect(sanitizedAscii.contains('/'), isFalse);
      expect(sanitizedAscii.contains('\\'), isFalse);
      expect(sanitizedAscii.contains('*'), isFalse);
      expect(sanitizedAscii.contains('?'), isFalse);
      expect(sanitizedAscii.contains('<'), isFalse);
      expect(sanitizedAscii.contains('>'), isFalse);
      expect(sanitizedAscii.contains('|'), isFalse);

      // Full-width Japanese/Unicode replacement
      final sanitizedFull = io.sanitize(raw, full: true);
      expect(sanitizedFull, contains('：'));
      expect(sanitizedFull, contains('”'));
      expect(sanitizedFull, contains('／'));
      expect(sanitizedFull, contains('＼'));
      expect(sanitizedFull, contains('＊'));
      expect(sanitizedFull, contains('？'));
      expect(sanitizedFull, contains('＜'));
      expect(sanitizedFull, contains('＞'));
      expect(sanitizedFull, contains('｜'));
    });

    test('io.size and io.parse (1-word)', () {
      expect(io.size(0), equals('0 B'));
      expect(io.size(1024), equals('1.0 KB'));
      expect(io.size(1024 * 1024 * 5), equals('5.0 MB'));
      expect(io.size(1024 * 1024 * 1024 * 2), equals('2.0 GB'));

      expect(io.parse('500 B'), equals(500));
      expect(io.parse('10 KB'), equals(10 * 1024));
      expect(io.parse('2.5 MB'), equals((2.5 * 1024 * 1024).round()));
      expect(io.parse('1 GB'), equals(1024 * 1024 * 1024));
    });

    test('io.time formats mm:ss and hh:mm:ss (1-word)', () {
      expect(io.time(const Duration(seconds: 45)), equals('00:45'));
      expect(io.time(const Duration(minutes: 3, seconds: 12)), equals('03:12'));
      expect(
        io.time(const Duration(hours: 2, minutes: 15, seconds: 30)),
        equals('02:15:30'),
      );
    });

    test(
      'io.write, io.has, io.read, io.copy, io.move atomically (1-word)',
      () async {
        final tempDir = io.temp('keybox_toolkit_test_');
        try {
          final file = File('${tempDir.path}/sub/test.txt');
          await io.write(file, 'Hello Dart Toolkit!');

          expect(io.has(file), isTrue);
          expect(io.read(file.path), equals('Hello Dart Toolkit!'));
          expect(File('${file.path}.part').existsSync(), isFalse);

          // Test copy and move
          final copyFile = File('${tempDir.path}/sub/copy.txt');
          io.copy(file, copyFile);
          expect(io.has(copyFile), isTrue);
          expect(io.read(copyFile.path), equals('Hello Dart Toolkit!'));

          final movedFile = File('${tempDir.path}/sub2/moved.txt');
          io.move(copyFile, movedFile);
          expect(io.has(copyFile), isFalse);
          expect(io.has(movedFile), isTrue);
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test('io path helpers join, base, name, ext, dir (1-word)', () {
      final p = io.join('parent', 'sub', 'file.mp3');
      expect(p.replaceAll('\\', '/'), equals('parent/sub/file.mp3'));
      expect(io.base(p), equals('file.mp3'));
      expect(io.name(p), equals('file'));
      expect(io.ext(p), equals('.mp3'));
      expect(io.dir(p).replaceAll('\\', '/'), equals('parent/sub'));
    });
  });

  group('system Domain', () {
    test('system.which finds dart (1-word)', () {
      final dartExe = system.which('dart');
      expect(dartExe, isNotNull);
      expect(File(dartExe!).existsSync(), isTrue);

      expect(Sys.which('dart'), equals(dartExe));
    });

    test('system.clock starts stopwatch', () {
      final clock = system.clock();
      expect(clock.isRunning, isTrue);
    });

    test('system.run executes command and returns output (1-word)', () async {
      final result = await system.run('dart', ['--version']);
      expect(result.code, equals(0));
      expect(result.ok, isTrue);
    });
  });

  group('concurrent Domain', () {
    test('concurrent.run executes tasks concurrently', () async {
      final items = [1, 2, 3, 4, 5];
      final processed = await concurrent.run(items, (n) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return n * 10;
      }, size: 2);

      expect(processed, containsAll([10, 20, 30, 40, 50]));
    });

    test(
      'concurrent.run strictly preserves input order with varying durations',
      () async {
        final items = [30, 10, 20, 5];
        final results = await concurrent.run(items, (n) async {
          await Future<void>.delayed(Duration(milliseconds: n));
          return 'item-$n';
        }, size: 4);
        expect(results, equals(['item-30', 'item-10', 'item-20', 'item-5']));
      },
    );
  });

  group('system.cli Sub-namespace', () {
    test('system.cli.parse reads flags, options, and lists', () {
      system.cli.parse(['--force', '-p', '8', '--name=test', 'file1', 'file2']);

      expect(system.cli.has('force'), isTrue);
      expect(system.cli.has('p'), isTrue);
      expect(system.cli.get('p', 0), equals(8));
      expect(system.cli.str('name'), equals('test'));
      expect(system.cli.get<String>('name'), equals('test'));
      expect(system.cli.list(), equals(['file1', 'file2']));
    });

    test(
      'system.cli.all collects multi-value options and system.cli.no checks negative flags',
      () {
        system.cli.parse(['--tag', 'a', '--tag', 'b', '--no-compress', '--cache']);
        expect(system.cli.all<String>('tag'), equals(['a', 'b']));
        expect(system.cli.no('compress'), isTrue);
        expect(system.cli.has('compress'), isTrue);
        expect(system.cli.get<bool>('compress', true), isFalse);
        expect(system.cli.get<bool>('cache', false), isTrue);
      },
    );
  });

  group('New Feature Enhancements', () {
    test('io.json, io.lines, io.hash, io.stat (1-word)', () async {
      final tempDir = io.temp('fs_new_test_');
      try {
        final jsonFile = io.join(tempDir.path, 'data.json');
        await io.json(jsonFile, {'hello': 'world', 'count': 42}, true);
        final data = io.json<Map<String, Object?>>(jsonFile);
        expect(data['hello'], equals('world'));
        expect(data['count'], equals(42));

        final linesList = await io.lines(jsonFile).toList();
        expect(linesList.isNotEmpty, isTrue);

        final sha = io.hash(jsonFile);
        final md5Hex = io.hash(jsonFile, 'md5');
        expect(sha.length, equals(64));
        expect(md5Hex.length, equals(32));

        final stat = io.stat(jsonFile);
        expect(stat.size, greaterThan(0));

        // Test direct Map auto-serialization in io.write
        final mapFile = io.join(tempDir.path, 'direct_map.json');
        await io.write(mapFile, {'direct': true, 'num': 99});
        final mapData = io.json<Map<String, Object?>>(mapFile);
        expect(mapData['direct'], isTrue);
        expect(mapData['num'], equals(99));

        // Test Archive methods
        final testArc = io.archive(io.join(tempDir.path, 'sample.7z'));
        expect(testArc.check, isNotNull);
        expect(testArc.zip, isNotNull);
        expect(testArc.wipe, isNotNull);
        expect(Archive.test, isNotNull);
        expect(Archive.pack, isNotNull);
        expect(Archive.clean, isNotNull);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('system platform predicates, process tracking and timeout', () async {
      expect(system.win, equals(Platform.isWindows));
      expect(system.mac, equals(Platform.isMacOS));
      expect(system.nix, equals(Platform.isLinux));

      final res = await system.run('dart', [
        '--version',
      ], timeout: const Duration(seconds: 10));
      expect(res.ok, isTrue);

      // Verify Sys proc and unproc
      expect(() => system.proc, returnsNormally);
      expect(() => system.unproc, returnsNormally);
    });

    test('util.console.logger respects LogLevel filter and writer writeln', () {
      util.console.logger.level = LogLevel.warn;
      expect(() => util.console.logger.debug('should be silent'), returnsNormally);
      expect(() => util.console.logger.info('should be silent'), returnsNormally);
      expect(() => util.console.logger.warn('should output'), returnsNormally);
      util.console.logger.level = LogLevel.debug;

      expect(() => util.console.writer.writeln('test line'), returnsNormally);
    });

    test('QueryResult prev, next, val, data (1-word)', () {
      const fragment = '''
        <div>
          <input id="username" value="feiluvnana" data-user-id="12345" data-role="admin" />
          <span class="first">First</span>
          <span class="second">Second</span>
          <span class="third">Third</span>
        </div>
      ''';
      final q = $(fragment);
      expect(q.$('.second').prev().text, equals('First'));
      expect(q.$('.second').next().text, equals('Third'));
      expect(q.$('#username').val(), equals('feiluvnana'));
      expect(q.$('#username').data('user-id'), equals('12345'));
      final dataMap = q.$('#username').data() as Map<String, String>;
      expect(dataMap['role'], equals('admin'));
    });
  });

  group('http Namespace Tests', () {
    test(
      'HttpResponse provides ok, body, json, DOM querying, and atomic save',
      () async {
        final res = HttpResponse(
          url: Uri.parse('https://example.com/item/1'),
          status: 200,
          headers: {'content-type': 'text/html; charset=utf-8'},
          bytes: utf8.encode('''
          <html>
            <body>
              <h1>Welcome</h1>
              <a href="/sub/page">Link</a>
              <img src="/images/pic.png" />
            </body>
          </html>
        '''),
        );

        expect(res.ok, isTrue);
        expect(res.status, equals(200));
        expect(res.body, contains('Welcome'));
        expect(res.$('h1').text, equals('Welcome'));
        expect(res.link(), equals('https://example.com/sub/page'));
        expect(res.src(), equals('https://example.com/images/pic.png'));
        expect(res.lines, contains('Welcome'));

        final tempDir = Directory.systemTemp.createTempSync('http_test_');
        try {
          final saved = await res.save('${tempDir.path}/page.html');
          expect(saved.existsSync(), isTrue);
          expect(saved.readAsStringSync(), contains('Welcome'));
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test(
      'net.http.get, net.http.post, and net.http.client work against local server',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          if (req.method == 'GET' && req.uri.path == '/hello') {
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'message': 'hello world'}))
              ..close();
          } else if (req.method == 'POST' && req.uri.path == '/echo') {
            final body = await utf8.decodeStream(req);
            req.response
              ..statusCode = 201
              ..headers.contentType = ContentType.text
              ..write('Echo: $body')
              ..close();
          } else {
            req.response
              ..statusCode = 404
              ..close();
          }
        });

        try {
          final getRes = await net.http.get(
            'http://${server.address.host}:${server.port}/hello',
          );
          expect(getRes.ok, isTrue);
          expect(
            (getRes.json as Map<String, Object?>)['message'],
            equals('hello world'),
          );

          final postRes = await net.http.post(
            'http://${server.address.host}:${server.port}/echo',
            body: 'toolkit',
          );
          expect(postRes.status, equals(201));
          expect(postRes.body, equals('Echo: toolkit'));

          final customClient = net.http.client(timeout: const Duration(seconds: 5));
          final clientRes = await customClient.get(
            'http://${server.address.host}:${server.port}/hello',
          );
          expect(clientRes.ok, isTrue);
          await customClient.close();
        } finally {
          await server.close(force: true);
        }
      },
    );
  });

  group('system.env Sub-namespace Tests', () {
    test('system.env reads, casts, and sets variables with 1-word methods', () {
      system.env.clear();
      system.env.set('APP_PORT', '9000');
      system.env.set('APP_DEBUG', 'true');
      system.env.set('APP_RATE', '3.14');
      system.env.set('APP_NAME', 'DartToolkit');

      expect(system.env.has('APP_PORT'), isTrue);
      expect(system.env.get('APP_NAME'), equals('DartToolkit'));
      expect(system.env.int('APP_PORT'), equals(9000));
      expect(system.env.bool('APP_DEBUG'), isTrue);
      expect(system.env.double('APP_RATE'), closeTo(3.14, 0.001));
      expect(system.env.get('NON_EXISTENT', 'default'), equals('default'));

      system.env.delete('APP_NAME');
      expect(system.env.has('APP_NAME'), isFalse);

      final map = system.env.map();
      expect(map['APP_PORT'], equals('9000'));

      system.env.clear();
      expect(system.env.has('APP_PORT'), isFalse);
    });

    test(
      'system.env loads variables from .env file with comments and quotes',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('env_test_');
        try {
          final envFile = File('${tempDir.path}/.env');
          envFile.writeAsStringSync('''
          # This is a comment
          export DB_HOST=localhost
          DB_PORT=5432
          DB_NAME="my_db"
          DB_SSL=false
          API_KEY='secret_123' # inline comment
        ''');

          system.env.clear();
          final loaded = system.env.load(envFile.path);
          expect(loaded, isTrue);

          expect(system.env.get('DB_HOST'), equals('localhost'));
          expect(system.env.int('DB_PORT'), equals(5432));
          expect(system.env.get('DB_NAME'), equals('my_db'));
          expect(system.env.bool('DB_SSL'), isFalse);
          expect(system.env.get('API_KEY'), equals('secret_123'));
        } finally {
          tempDir.deleteSync(recursive: true);
          system.env.clear();
        }
      },
    );
  });

  group('util.git Sub-namespace Tests', () {
    test('util.git inspects branch, hash, and status with 1-word methods', () async {
      final branch = await util.git.branch();
      expect(branch, isNotEmpty);
      expect(branch, equals('master'));

      final hash = await util.git.hash();
      expect(hash, isNotEmpty);
      expect(hash.length, greaterThanOrEqualTo(7));

      final dirty = await util.git.dirty();
      expect(dirty, isA<bool>());

      final status = await util.git.status();
      expect(status, isA<String>());
    });
  });

  group('util.time Sub-namespace Tests', () {
    test('util.time wait, stamp, iso, ago, clock with 1-word methods', () async {
      final sw = util.time.clock();
      await util.time.wait(20);
      sw.stop();
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(10));

      final stamp = util.time.stamp();
      expect(RegExp(r'^\d{8}_\d{6}$').hasMatch(stamp), isTrue);

      final iso = util.time.iso();
      expect(iso, contains('T'));
      expect(iso, endsWith('Z'));

      final past = DateTime.now().subtract(const Duration(minutes: 5));
      expect(util.time.ago(past), equals('5m ago'));
      expect(util.time.ago(DateTime.now()), equals('just now'));

      expect(util.time.now(), isA<DateTime>());
      expect(util.time.epoch(), greaterThan(0));
    });
  });

  group('io.csv Sub-namespace Tests', () {
    test('io.csv parses and formats matrix and maps with 1-word methods', () {
      const input =
          'id,name,role\n1,"Alice, Chief",admin\n2,"Bob ""The Builder""",user';
      final matrix = io.csv.parse(input);

      expect(matrix.length, equals(3));
      expect(matrix[0], equals(['id', 'name', 'role']));
      expect(matrix[1][1], equals('Alice, Chief'));
      expect(matrix[2][1], equals('Bob "The Builder"'));

      final formatted = io.csv.format([
        {'id': 1, 'name': 'Alice'},
        {'id': 2, 'name': 'Bob'},
      ]);
      expect(formatted, contains('id,name'));
      expect(formatted, contains('1,Alice'));
      expect(formatted, contains('2,Bob'));
    });

    test('io.csv reads and writes files atomically', () async {
      final tempDir = Directory.systemTemp.createTempSync('csv_test_');
      try {
        final filePath = '${tempDir.path}/test.csv';
        final data = [
          {'fruit': 'Apple', 'price': '1.50'},
          {'fruit': 'Banana', 'price': '0.75'},
        ];

        final written = await io.csv.write(filePath, data);
        expect(written.existsSync(), isTrue);

        final readMaps = await io.csv.read<Map<String, String>>(filePath);
        expect(readMaps.length, equals(2));
        expect(readMaps[0]['fruit'], equals('Apple'));
        expect(readMaps[0]['price'], equals('1.50'));
        expect(readMaps[1]['fruit'], equals('Banana'));

        final readMatrix =
            await io.csv.read<List<String>>(filePath, header: false);
        expect(readMatrix.length, equals(3)); // header + 2 data rows
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('io.store Sub-namespace Tests', () {
    test(
      'io.store gets, sets, persists, and reloads JSON data with 1-word methods',
      () async {
        io.store.clear();
        io.store.set('theme', 'dark');
        io.store.set('counter', 42);

        expect(io.store.has('theme'), isTrue);
        expect(io.store.str('theme'), equals('dark'));
        expect(io.store.get<String>('theme'), equals('dark'));
        expect(io.store.get<int>('counter'), equals(42));
        expect(io.store.get('missing', 'default'), equals('default'));

        io.store.delete('theme');
        expect(io.store.has('theme'), isFalse);

        final tempDir = Directory.systemTemp.createTempSync('store_test_');
        try {
          final dbFile = '${tempDir.path}/cache.json';
          final db = io.store.open(dbFile);

          db.set('user_id', 'user_101');
          db.set('visits', 5);
          await db.save();

          expect(File(dbFile).existsSync(), isTrue);

          final db2 = io.store.open(dbFile);
          expect(db2.str('user_id'), equals('user_101'));
          expect(db2.get<String>('user_id'), equals('user_101'));
          expect(db2.get<int>('visits'), equals(5));

          db2.clear();
          expect(db2.isEmpty, isTrue);
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );
  });

  group('Hierarchical Java-style Domain Namespaces', () {
    test('io domain provides unified file, csv, store access', () async {
      expect(io, isNotNull);
      expect(io.file, isNotNull);
      expect(io.csv, isNotNull);
      expect(io.store, isNotNull);

      // Path operations via io
      final fullPath = io.join('foo', 'bar', 'test.txt');
      expect(io.base(fullPath), equals('test.txt'));
      expect(io.name(fullPath), equals('test'));
      expect(io.ext(fullPath), equals('.txt'));

      // File I/O via io
      final tempDir = io.temp('io_domain_test_');
      try {
        final filePath = io.join(tempDir.path, 'sample.txt');
        await io.write(filePath, 'Hello Java-style IO');
        expect(io.has(filePath), isTrue);
        expect(io.read(filePath), equals('Hello Java-style IO'));

        // io.csv
        final csvPath = io.join(tempDir.path, 'sample.csv');
        await io.csv.write(csvPath, [
          {'key': 'k1', 'val': 'v1'},
        ]);
        final csvRows = await io.csv.read<Map<String, String>>(csvPath);
        expect(csvRows.length, equals(1));
        expect(csvRows[0]['key'], equals('k1'));

        // io.store
        final storePath = io.join(tempDir.path, 'data.json');
        final s = io.store.open(storePath);
        s.set('alpha', 123);
        await s.save();
        expect(io.has(storePath), isTrue);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('net domain provides unified http, crawl, and selector access', () {
      expect(net, isNotNull);
      expect(net.http, isNotNull);
      expect(net.crawl, isNotNull);

      // CSS query via net.$
      final q = net.$('.title', '<h1 class="title">Domain Test</h1>');
      expect(q.text, equals('Domain Test'));
      expect(q.hasClass('title'), isTrue);
    });

    test('system domain provides unified process, env, and cli access', () {
      expect(system, isNotNull);
      expect(system.env, isNotNull);
      expect(system.cli, isNotNull);
      expect(system.on, isNotNull);

      // Environment
      system.env.set('TEST_DOMAIN_ENV', 'active');
      expect(system.env.get('TEST_DOMAIN_ENV'), equals('active'));

      // CLI
      system.cli.parse(['--mode=release', '-v', 'target.dart']);
      expect(system.cli.has('v'), isTrue);
      expect(system.cli.str('mode'), equals('release'));
      expect(system.cli.get<String>('mode'), equals('release'));

      // Clock
      final sw = system.clock();
      expect(sw.isRunning, isTrue);

      // Which
      expect(system.which('dart'), isNotNull);
    });

    test('concurrent domain provides concurrent.run and pool', () async {
      expect(concurrent, isNotNull);
      final results = await concurrent.run([1, 2, 3], (x) async => x * 10);
      expect(results, equals([10, 20, 30]));

      final pool = concurrent.pool(2);
      expect(pool.concurrency, equals(2));
    });

    test('util domain provides unified time, git, and console access', () async {
      expect(util, isNotNull);
      expect(util.time, isNotNull);
      expect(util.git, isNotNull);
      expect(util.console, isNotNull);

      // time
      final stamp = util.time.stamp();
      expect(stamp, isNotEmpty);
      expect(util.time.iso(), contains('T'));

      // console
      expect(util.console.logger, isNotNull);
      expect(util.console.writer, isNotNull);
      expect(util.console.reader, isNotNull);

      // git
      final branch = await util.git.branch();
      expect(branch, isNotNull);
    });
  });
}
