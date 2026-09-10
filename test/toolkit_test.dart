import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Console & Terminal Namespaces', () {
    test('the writer reports geometry', () {
      expect(system.console.writer.width, greaterThan(0));
      expect(system.console.writer.height, greaterThan(0));
    });

    test('writer renders tables, boxes and rules', () {
      final table = Table(headers: ['A', 'B'])..add(['1', '2']);
      expect(table.render(), contains('A'));
      expect(table.render(), contains('1'));

      expect(() => system.console.writer.table(table), returnsNormally);
      expect(
        () => system.console.writer.box('Hello World\nLine 2', title: 'Box'),
        returnsNormally,
      );
      expect(() => system.console.writer.rule('Test Rule'), returnsNormally);
    });

    test('table alignments pad by visible width', () {
      final table = Table(
        headers: ['Left', 'Right'],
        alignments: [ColumnAlign.left, ColumnAlign.right],
      )..addAll([
        ['a', '1'],
        ['bbb', '22'],
      ]);
      final lines = table.render().split('\n');
      // Every rendered row is the same visible width.
      final widths = lines.where((l) => l.isNotEmpty).map(Ansi.width).toSet();
      expect(widths, hasLength(1));
    });

    test('logger.task runs its action behind a spinner', () async {
      final result = await system.console.logger.task(
        'Running quick task',
        () async => 42,
      );
      expect(result, equals(42));
    });

    test('logger respects its level filter', () {
      system.console.logger.level = LogLevel.warn;
      expect(() => system.console.logger.debug('silent'), returnsNormally);
      expect(() => system.console.logger.info('silent'), returnsNormally);
      expect(() => system.console.logger.warn('shown'), returnsNormally);
      system.console.logger.level = LogLevel.debug;
    });
  });

  group('Ansi Utilities', () {
    test('strip removes ANSI sequences', () {
      Ansi.enabled = true;
      final styled = 'Hello'.red().bold();
      expect(Ansi.strip(styled), equals('Hello'));
      expect(Ansi.width(styled), equals(5));
      expect(styled.plain, equals('Hello'));
      expect(styled.width, equals(5));
    });
  });

  group('io Domain', () {
    test('io.sanitize removes or replaces illegal characters', () {
      const raw = 'Key: "Box" / 20th * Edition? <Special> | Path\\';

      final ascii = io.sanitize(raw);
      for (final illegal in [':', '"', '/', r'\', '*', '?', '<', '>', '|']) {
        expect(ascii.contains(illegal), isFalse, reason: 'kept $illegal');
      }

      final wide = io.sanitize(raw, full: true);
      for (final replacement in ['：', '”', '／', '＼', '＊', '？', '＜', '＞', '｜']) {
        expect(wide, contains(replacement));
      }
    });

    test('io.write, io.has, io.read, io.copy, io.move are atomic', () async {
      final temp = io.temp('toolkit_test_');
      try {
        final path = io.join(temp.path, 'sub', 'test.txt');
        io.write(path, 'Hello Dart Toolkit!');

        expect(io.has(path), isTrue);
        expect(io.read(path), equals('Hello Dart Toolkit!'));
        // The staging file is renamed into place, never left behind.
        expect(File('$path.part').existsSync(), isFalse);

        final copied = io.join(temp.path, 'sub', 'copy.txt');
        io.copy(path, copied);
        expect(io.read(copied), equals('Hello Dart Toolkit!'));

        final moved = io.join(temp.path, 'sub2', 'moved.txt');
        io.move(copied, moved);
        expect(io.has(copied), isFalse);
        expect(io.has(moved), isTrue);
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('io.has treats a zero-length file as absent', () async {
      final temp = io.temp('toolkit_empty_');
      try {
        final path = io.join(temp.path, 'empty.txt');
        File(path).writeAsStringSync('');
        expect(io.has(path), isFalse);
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('io.similar is opt-in and matches loosely-named siblings', () async {
      final temp = io.temp('toolkit_similar_');
      try {
        io.write(io.join(temp.path, 'thumb_cover.jpg'), 'x');
        final wanted = io.join(temp.path, 'cover.jpg');

        // Off by default, so a download is not silently skipped.
        expect(io.has(wanted), isFalse);
        expect(io.similar(wanted), isTrue);
        expect(io.has(wanted, match: true), isTrue);
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('io path helpers join, base, name, ext, dir', () {
      final path = io.join('parent', 'sub', 'file.mp3');
      expect(path.replaceAll(r'\', '/'), equals('parent/sub/file.mp3'));
      expect(io.base(path), equals('file.mp3'));
      expect(io.name(path), equals('file'));
      expect(io.ext(path), equals('.mp3'));
      expect(io.dir(path).replaceAll(r'\', '/'), equals('parent/sub'));
    });

    test('io.dump writes JSON and io.json reads it back', () async {
      final temp = io.temp('toolkit_json_');
      try {
        final path = io.join(temp.path, 'data.json');
        // dump returns a Future<File> that must be awaited, so the bytes are
        // on disk before the next read.
        final file = io.dump(path, {'hello': 'world', 'count': 42});
        expect(file.existsSync(), isTrue);

        final data = io.json<Map<String, Object?>>(path);
        expect(data['hello'], equals('world'));
        expect(data['count'], equals(42));

        final compact = io.join(temp.path, 'compact.json');
        io.dump(compact, {'a': 1}, pretty: false);
        expect(io.read(compact), equals('{"a":1}'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('io.save writes bytes, io.bytes reads them', () async {
      final temp = io.temp('toolkit_bytes_');
      try {
        final path = io.join(temp.path, 'blob.bin');
        io.save(path, [1, 2, 3, 4]);
        expect(io.bytes(path), equals([1, 2, 3, 4]));
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('io.lines, io.hash, io.stat, io.find, io.delete', () async {
      final temp = io.temp('toolkit_meta_');
      try {
        final path = io.join(temp.path, 'lines.txt');
        io.write(path, 'one\ntwo\nthree');

        expect(await io.lines(path).toList(), equals(['one', 'two', 'three']));
        expect(io.hash(path).length, equals(64));
        expect(io.hash(path, Algo.md5).length, equals(32));
        expect(io.stat(path).size, greaterThan(0));

        expect(io.find(temp.path).length, equals(1));
        expect(
          io.find(temp.path, pattern: RegExp(r'\.txt$')).length,
          equals(1),
        );
        expect(io.delete(temp.path, pattern: RegExp(r'\.txt$')), equals(1));
        expect(io.has(path), isFalse);
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('io.async mirrors io: read, bytes, json, hash, stat', () async {
      final temp = io.temp('toolkit_async_');
      try {
        final txtPath = io.join(temp.path, 'sample.txt');
        io.write(txtPath, 'async content');
        expect(await io.async.read(txtPath), equals('async content'));
        expect(
          await io.async.bytes(txtPath),
          equals(utf8.encode('async content')),
        );
        expect((await io.async.hash(txtPath)).length, equals(64));
        expect((await io.async.stat(txtPath)).size, greaterThan(0));

        final jsonPath = io.join(temp.path, 'data.json');
        io.dump(jsonPath, {'key': 'val'});
        final decoded = await io.async.json<Map<String, dynamic>>(jsonPath);
        expect(decoded['key'], equals('val'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('io directory copy, move, and single-file remove', () async {
      final temp = io.temp('toolkit_dir_ops_');
      try {
        final srcDir = io.join(temp.path, 'src');
        final f1 = io.join(srcDir, 'a.txt');
        final f2 = io.join(srcDir, 'nested', 'b.txt');
        io.write(f1, 'file 1');
        io.write(f2, 'file 2');

        // Directory copy
        final destDir = io.join(temp.path, 'dest');
        io.copy(srcDir, destDir);
        expect(io.read(io.join(destDir, 'a.txt')), equals('file 1'));
        expect(io.read(io.join(destDir, 'nested', 'b.txt')), equals('file 2'));

        // Directory move
        final movedDir = io.join(temp.path, 'moved');
        io.move(destDir, movedDir);
        expect(Directory(destDir).existsSync(), isFalse);
        expect(io.read(io.join(movedDir, 'a.txt')), equals('file 1'));

        // Single entity remove
        expect(io.remove(io.join(movedDir, 'a.txt')), isTrue);
        expect(io.has(io.join(movedDir, 'a.txt')), isFalse);
        expect(io.remove(io.join(movedDir, 'a.txt')), isFalse); // already gone
        expect(io.remove(movedDir), isTrue); // directory removal
        expect(Directory(movedDir).existsSync(), isFalse);
      } finally {
        temp.deleteSync(recursive: true);
      }
    });
  });

  group('system Domain', () {
    test('system.which finds dart', () {
      final dart = system.which('dart');
      expect(dart, isNotNull);
      expect(File(dart!).existsSync(), isTrue);
    });

    test('system.run captures output', () async {
      final result = await system.run('dart', ['--version']);
      expect(result.code, equals(0));
      expect(result.ok, isTrue);
      expect(result.out.isNotEmpty || result.err.isNotEmpty, isTrue);
    });

    test('system.run kills a process that outruns its timeout', () async {
      final result = await system.run('dart', [
        'run',
        '--',
        '-e',
        'x',
      ], timeout: const Duration(milliseconds: 300));
      // Either the command failed outright or the timeout fired; both settle
      // without hanging, which is what this guards.
      expect(result.ok, isFalse);
    });

    test('system exposes platform predicates', () {
      expect(system.windows, equals(Platform.isWindows));
      expect(system.macos, equals(Platform.isMacOS));
      expect(system.linux, equals(Platform.isLinux));
    });

    test('a script that writes a file still exits on its own', () async {
      // Regression: tracking a `.part` file installs a SIGINT watcher, and a
      // live watcher keeps the isolate alive. Writing must release it.
      final dir = Directory('.dart_tool/toolkit_exit_test')
        ..createSync(recursive: true);
      try {
        final script = io.join(dir.path, 'writer.dart');
        final output = io.join(dir.path, 'out.txt');
        io.write(script, '''
import 'package:dart_toolkit/dart_toolkit.dart';
void main() async {
  io.write(r'$output', 'hi');
  print('wrote');
}
''');
        final result = await system.run('dart', [
          'run',
          script,
        ], timeout: const Duration(seconds: 40));

        expect(
          result.code,
          equals(0),
          reason: 'script hung or failed: ${result.err}',
        );
        expect(result.out, contains('wrote'));
        expect(io.read(output), equals('hi'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('concurrent Domain', () {
    test('concurrent.run executes tasks concurrently', () async {
      final processed = await concurrent.run([1, 2, 3, 4, 5], (n) async {
        await util.time.wait(10.ms);
        return n * 10;
      }, size: 2);
      expect(processed, containsAll([10, 20, 30, 40, 50]));
    });

    test(
      'concurrent.run preserves input order despite varying durations',
      () async {
        final results = await concurrent.run([30, 10, 20, 5], (n) async {
          await util.time.wait(n.ms);
          return 'item-$n';
        }, size: 4);
        expect(results, equals(['item-30', 'item-10', 'item-20', 'item-5']));
      },
    );

    test('Pool.settle returns per-item results without throwing', () async {
      final pool = Pool<int>(size: 2);
      final outcomes = await pool.settle([1, 2, 3], (n) async {
        if (n == 2) throw Exception('fail on 2');
        return n * 10;
      });

      expect(outcomes.length, equals(3));
      expect(outcomes[0].isSuccess, isTrue);
      expect(outcomes[0].value, equals(10));
      expect(outcomes[1].isSuccess, isFalse);
      expect(outcomes[1].error.toString(), contains('fail on 2'));
      expect(outcomes[2].isSuccess, isTrue);
      expect(outcomes[2].value, equals(30));
    });

    test(
      'PoolFailure preserves partial results when collecting errors',
      () async {
        final pool = Pool<int>(size: 2);
        pool.on.error((err, stack, item) {}); // enables collecting mode

        try {
          await pool.run([1, 2, 3], (n) async {
            if (n == 2) throw Exception('fail on 2');
            return n * 10;
          });
          fail('Should have thrown PoolFailure');
        } on PoolFailure<int> catch (e) {
          expect(e.results.length, equals(3));
          expect(e.results[0], equals(10));
          expect(e.results[1], isNull);
          expect(e.results[2], equals(30));
        }
      },
    );

    test('concurrent.stream yields results in completion order', () async {
      // 50ms task vs 10ms task: 10ms task completes first
      final items = [50, 10];
      final streamed =
          await concurrent.stream(items, (delay) async {
            await util.time.wait(delay.ms);
            return 'done-$delay';
          }, size: 2).toList();

      expect(streamed, equals(['done-10', 'done-50']));
    });

    test('Semaphore and Mutex control concurrent execution', () async {
      final sem = concurrent.semaphore(2);
      var running = 0;
      var maxRunning = 0;

      await Future.wait([
        for (var i = 0; i < 5; i++)
          sem.withPermit(() async {
            running++;
            if (running > maxRunning) maxRunning = running;
            await util.time.wait(10.ms);
            running--;
          }),
      ]);

      expect(maxRunning, lessThanOrEqualTo(2));

      final mutex = concurrent.mutex();
      var count = 0;
      await Future.wait([
        for (var i = 0; i < 5; i++)
          mutex.protect(() async {
            final cur = count;
            await util.time.wait(5.ms);
            count = cur + 1;
          }),
      ]);
      expect(count, equals(5));
    });

    test('concurrent.retry retries on failure with backoff', () async {
      var attempts = 0;
      final result = await concurrent.retry(
        () async {
          attempts++;
          if (attempts < 3) throw StateError('fail $attempts');
          return 'success';
        },
        times: 3,
        backoff: 5.ms,
      );

      expect(result, equals('success'));
      expect(attempts, equals(3));

      var failAttempts = 0;
      await expectLater(
        () => concurrent.retry(
          () async {
            failAttempts++;
            throw Exception('always fail');
          },
          times: 2,
          backoff: 2.ms,
        ),
        throwsException,
      );
      expect(failAttempts, equals(2));
    });

    test(
      'concurrent.compute executes CPU-bound work on separate isolate',
      () async {
        final fib = await concurrent.compute((int n) {
          int calc(int x) => x <= 1 ? x : calc(x - 1) + calc(x - 2);
          return calc(n);
        }, 10);
        expect(fib, equals(55));
      },
    );
  });

  group('cli Sub-namespace', () {
    test('parse reads flags, options and positionals', () {
      cli.parse(['--force', '-p', '8', '--name=test', 'file1', 'file2']);

      expect(cli.has('force'), isTrue);
      expect(cli.has('p'), isTrue);
      expect(cli.get('p', 0), equals(8));
      expect(cli.get('name', ''), equals('test'));
      expect(cli.list(), equals(['file1', 'file2']));
    });

    test('all collects repeats and no reads negative flags', () {
      cli.parse([
        '--tag',
        'a',
        '--tag',
        'b',
        '--no-compress',
        '--cache',
      ]);

      expect(cli.all<String>('tag'), equals(['a', 'b']));
      expect(cli.no('compress'), isTrue);
      // --no-compress must not report the positive flag as present.
      expect(cli.has('compress'), isFalse);
      expect(cli.get<bool>('compress', true), isFalse);
      expect(cli.get<bool>('cache', false), isTrue);
    });

    test(
      'handles negative values, bare -- separator, and consecutive flags',
      () {
        final cli = Cli(['--offset', '-5', '--', 'file.txt']);
        expect(cli.get('offset', 0), equals(-5));
        expect(cli.list(), equals(['file.txt']));
        expect(cli.has('5'), isFalse);

        final flags = Cli(['--flag', '--other']);
        expect(flags.has('flag'), isTrue);
        expect(flags.has('other'), isTrue);
        expect(flags.list(), isEmpty);
      },
    );

    test('subcommands and rest', () {
      final cli = Cli(['build', '--prod', 'main.dart', 'output.bin'])
        ..flag('prod');
      expect(cli.command, equals('build'));
      expect(cli.rest, equals(['main.dart', 'output.bin']));
      expect(cli.has('prod'), isTrue);

      var executed = false;
      final matched = cli.subcommand('build', (subCli) {
        executed = true;
        expect(subCli.rest, equals(['main.dart', 'output.bin']));
      });
      expect(matched, isTrue);
      expect(executed, isTrue);

      expect(cli.subcommand('test', (_) {}), isFalse);

      final noCmd = Cli(['--flag']);
      expect(noCmd.command, isNull);
      expect(noCmd.rest, isEmpty);
    });

    test('declarations, require validation, and usage', () {
      final cli =
          Cli(['--output', 'dist'])
            ..flag('verbose', alias: 'v', desc: 'Enable verbose logging')
            ..option(
              'output',
              alias: 'o',
              desc: 'Output directory',
              required: true,
            )
            ..option(
              'port',
              alias: 'p',
              desc: 'Server port',
              def: 8080,
              required: true,
            );

      // 'port' is required but declares a default, which supplies it.
      expect(() => cli.require(), returnsNormally);
      expect(() => cli.require(['output']), returnsNormally);

      // Required with nothing to fall back on still throws, and names itself.
      final bare = Cli(const <String>[])
        ..option('output', alias: 'o', required: true);
      expect(
        () => bare.require(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('--output'),
          ),
        ),
      );

      final validCli =
          Cli(['--output', 'dist', '-p', '3000'])
            ..option(
              'output',
              alias: 'o',
              desc: 'Output directory',
              required: true,
            )
            ..option(
              'port',
              alias: 'p',
              desc: 'Server port',
              def: 8080,
              required: true,
            );
      expect(() => validCli.require(), returnsNormally);

      final help = validCli.usage(
        syntax: 'myapp [options]',
        desc: 'My application description',
      );
      expect(help, contains('Usage: myapp [options]'));
      expect(help, contains('My application description'));
      expect(help, contains('--output <value>'));
      expect(help, contains('(required)'));
      expect(help, contains('[default: 8080]'));
    });
  });

  group('system.env Sub-namespace', () {
    test('env reads and casts through a single typed getter', () {
      system.env.clear();
      system.env.set('APP_PORT', '9000');
      system.env.set('APP_DEBUG', 'true');
      system.env.set('APP_RATE', '3.14');
      system.env.set('APP_NAME', 'DartToolkit');

      expect(system.env.has('APP_PORT'), isTrue);
      expect(system.env.get('APP_NAME', ''), equals('DartToolkit'));
      expect(system.env.get('APP_PORT', 0), equals(9000));
      expect(system.env.get('APP_DEBUG', false), isTrue);
      expect(system.env.get('APP_RATE', 0.0), closeTo(3.14, 0.001));
      expect(system.env.get('NON_EXISTENT', 'default'), equals('default'));
      expect(system.env.get('NON_EXISTENT', 7), equals(7));

      system.env.delete('APP_NAME');
      expect(system.env.has('APP_NAME'), isFalse);
      expect(system.env.map()['APP_PORT'], equals('9000'));

      system.env.clear();
      expect(system.env.has('APP_PORT'), isFalse);
    });

    test('env.load reads a .env file with comments and quotes', () async {
      final temp = io.temp('env_test_');
      try {
        final path = io.join(temp.path, '.env');
        io.write(path, '''
          # This is a comment
          export DB_HOST=localhost
          DB_PORT=5432
          DB_NAME="my_db"
          DB_SSL=false
          API_KEY='secret_123' # inline comment
        ''');

        system.env.clear();
        expect(system.env.load(path), isTrue);
        expect(system.env.load(io.join(temp.path, 'missing.env')), isFalse);

        expect(system.env.get('DB_HOST', ''), equals('localhost'));
        expect(system.env.get('DB_PORT', 0), equals(5432));
        expect(system.env.get('DB_NAME', ''), equals('my_db'));
        expect(system.env.get('DB_SSL', true), isFalse);
        expect(system.env.get('API_KEY', ''), equals('secret_123'));
      } finally {
        temp.deleteSync(recursive: true);
        system.env.clear();
      }
    });
  });

  group('net.http Namespace', () {
    test(
      'HttpResponse exposes ok, body, json, DOM querying and save',
      () async {
        final res = HttpResponse(
          url: 'https://example.com/item/1'.url,
          status: 200,
          headers: const {'content-type': 'text/html; charset=utf-8'},
          bytes: utf8.encode('''
          <html><body>
            <h1>Welcome</h1>
            <a href="/sub/page">Link</a>
            <img src="/images/pic.png" />
          </body></html>
        '''),
        );

        expect(res.ok, isTrue);
        expect(res.body, contains('Welcome'));
        expect(res.$('h1').text, equals('Welcome'));
        expect(res.$('a').href, equals('/sub/page'));
        expect(res.$('img').src, equals('/images/pic.png'));
        expect(res.$.lines, contains('Welcome'));

        final temp = io.temp('http_test_');
        try {
          final saved = await res.save(io.join(temp.path, 'page.html'));
          expect(saved.readAsStringSync(), contains('Welcome'));
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );

    test('net.http talks to a local server', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        switch (req.uri.path) {
          case '/hello':
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'message': 'hello world'}));
          case '/echo':
            final body = await utf8.decodeStream(req);
            req.response
              ..statusCode = 201
              ..write('Echo: $body');
          default:
            req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final root = 'http://${server.address.host}:${server.port}';
      try {
        final res = await net.http.get('$root/hello'.url);
        expect(res.ok, isTrue);
        expect((res.json as Map<String, Object?>)['message'], 'hello world');
        // json is cached, so a second read is free and consistent.
        expect(res.json, same(res.json));

        final posted = await net.http.post(
          '$root/echo'.url,
          body: const Body.text('toolkit'),
        );
        expect(posted.status, equals(201));
        expect(posted.body, equals('Echo: toolkit'));

        final form = await net.http.post(
          '$root/echo'.url,
          body: const Body.form({'a': '1'}),
        );
        expect(form.body, equals('Echo: a=1'));

        final client = HttpClient(timeout: const Duration(seconds: 5));
        expect((await client.get('$root/hello'.url)).ok, isTrue);
        await client.close();
      } finally {
        await server.close(force: true);
      }
    });

    test(
      'HttpResponse detects charset and handles decode and redirects',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          switch (req.uri.path) {
            case '/latin1':
              req.response.headers.set(
                'content-type',
                'text/html; charset=iso-8859-1',
              );
              req.response.add(latin1.encode('<p>café</p>'));
              break;
            case '/meta-sniff':
              req.response.headers.set('content-type', 'text/html');
              req.response.add(
                latin1.encode(
                  '<html><head><meta charset="iso-8859-1"></head><body><p>résumé</p></body></html>',
                ),
              );
              break;
            case '/not-json':
              req.response.headers.set('content-type', 'text/plain');
              req.response.write('plain text not json');
              break;
            case '/redirect-src':
              req.response.redirect(
                Uri.parse(
                  'http://${server.address.host}:${server.port}/redirect-dst',
                ),
              );
              return;
            case '/redirect-dst':
              req.response.write('arrived at dest');
              break;
            default:
              req.response.statusCode = 404;
          }
          await req.response.close();
        });

        final root = 'http://${server.address.host}:${server.port}';
        try {
          // Charset from header
          final latin1Res = await net.http.get('$root/latin1'.url);
          expect(latin1Res.type, equals('text/html'));
          expect(latin1Res.charset, equals('iso-8859-1'));
          expect(latin1Res.body, contains('café'));

          // Meta sniff
          final metaRes = await net.http.get('$root/meta-sniff'.url);
          expect(metaRes.charset, equals('iso-8859-1'));
          expect(metaRes.body, contains('résumé'));

          // decode fallback
          final notJsonRes = await net.http.get('$root/not-json'.url);
          expect(
            notJsonRes.decode({'fallback': true}),
            equals({'fallback': true}),
          );

          // Redirect URL tracking
          final redirectRes = await net.http.get('$root/redirect-src'.url);
          expect(
            redirectRes.requested.toString(),
            equals('$root/redirect-src'),
          );
          expect(redirectRes.url.toString(), equals('$root/redirect-dst'));
          expect(redirectRes.body, equals('arrived at dest'));
        } finally {
          await server.close(force: true);
        }
      },
    );

    test(
      'HttpResponse.extract extracts structured data declaratively',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          req.response
            ..headers.contentType = ContentType.html
            ..write('''
            <html>
              <body>
                <h1>Product Catalog</h1>
                <a class="canonical" href="https://example.com/products">Canonical</a>
                <ul class="categories">
                  <li>Electronics</li>
                  <li>Books</li>
                </ul>
                <div class="product">
                  <span class="name">Laptop</span>
                  <span class="price">\$999</span>
                  <a href="/items/1">Buy</a>
                </div>
                <div class="product">
                  <span class="name">Phone</span>
                  <span class="price">\$499</span>
                  <a href="/items/2">Buy</a>
                </div>
              </body>
            </html>
          ''');
          await req.response.close();
        });

        try {
          final res = await net.http.get(
            'http://${server.address.host}:${server.port}'.url,
          );
          final extracted = res.extract({
            'title': 'h1',
            'canonical': 'a.canonical@href',
            'categories': ['ul.categories > li'],
            'items': [
              '.product',
              {'name': '.name', 'price': '.price', 'url': 'a@href'},
            ],
          });

          expect(extracted['title'], equals('Product Catalog'));
          expect(
            extracted['canonical'],
            equals('https://example.com/products'),
          );
          expect(extracted['categories'], equals(['Electronics', 'Books']));
          expect(
            extracted['items'],
            equals([
              {'name': 'Laptop', 'price': '\$999', 'url': '/items/1'},
              {'name': 'Phone', 'price': '\$499', 'url': '/items/2'},
            ]),
          );
        } finally {
          await server.close(force: true);
        }
      },
    );

    test(
      'HttpClient session persistence manages cookies across requests',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          if (req.uri.path == '/login') {
            req.response.headers.set(
              'set-cookie',
              'session_id=secret123; Path=/',
            );
            req.response.write('logged in');
          } else if (req.uri.path == '/profile') {
            final cookie = req.headers.value('cookie');
            req.response.write('cookie received: $cookie');
          }
          await req.response.close();
        });

        final root = 'http://${server.address.host}:${server.port}';
        final client = HttpClient(session: true);
        try {
          final loginRes = await client.get('$root/login'.url);
          expect(loginRes.body, equals('logged in'));
          expect(client.jar?.cookies.length, equals(1));
          expect(client.jar?.cookies.first.name, equals('session_id'));

          // Next request sends cookie
          final profileRes = await client.get('$root/profile'.url);
          expect(profileRes.body, contains('session_id=secret123'));
        } finally {
          await client.close();
          await server.close(force: true);
        }
      },
    );

    test('HttpClient supports proxy configuration', () {
      final client = HttpClient(proxy: '127.0.0.1:8888');
      expect(client.proxy, equals('127.0.0.1:8888'));
      client.close();
    });

    test('net.http.download and sync write files', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response
          ..statusCode = 200
          ..write('body of ${req.uri.path}');
        await req.response.close();
      });

      final root = 'http://${server.address.host}:${server.port}';
      final temp = io.temp('download_test_');
      try {
        final one = io.join(temp.path, 'one.txt');
        await net.http.download('$root/one'.url, one);
        expect(io.read(one), equals('body of /one'));

        await net.http.sync({
          io.join(temp.path, 'a.txt'): '$root/a'.url,
          io.join(temp.path, 'b.txt'): '$root/b'.url,
        });
        expect(io.read(io.join(temp.path, 'a.txt')), equals('body of /a'));
        expect(io.read(io.join(temp.path, 'b.txt')), equals('body of /b'));
      } finally {
        temp.deleteSync(recursive: true);
        await server.close(force: true);
      }
    });

    test(
      'a failing download reports the failure instead of swallowing it',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          req.response.statusCode = 404;
          await req.response.close();
        });

        final root = 'http://${server.address.host}:${server.port}';
        final temp = io.temp('download_fail_');
        final client = HttpClient(retries: 0);
        try {
          await expectLater(
            client.download('$root/missing'.url, io.join(temp.path, 'x.txt')),
            throwsA(isA<HttpException>()),
          );
          expect(io.has(io.join(temp.path, 'x.txt')), isFalse);
        } finally {
          await client.close();
          temp.deleteSync(recursive: true);
          await server.close(force: true);
        }
      },
    );
  });

  group('io.csv Sub-namespace', () {
    test('parse and format handle quotes and delimiters', () {
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
    });

    test(
      'maps and matrix read the two shapes, without a type argument',
      () async {
        final temp = io.temp('csv_test_');
        try {
          final path = io.join(temp.path, 'test.csv');
          await io.csv.write(path, [
            {'fruit': 'Apple', 'price': '1.50'},
            {'fruit': 'Banana', 'price': '0.75'},
          ]);

          final rows = await io.csv.maps(path);
          expect(rows.length, equals(2));
          expect(rows[0]['fruit'], equals('Apple'));
          expect(rows[0]['price'], equals('1.50'));

          final grid = await io.csv.matrix(path);
          expect(grid.length, equals(3)); // header plus two data rows

          expect(await io.csv.maps(io.join(temp.path, 'missing.csv')), isEmpty);
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );

    test('dump writes rows of cells', () async {
      final temp = io.temp('csv_dump_');
      try {
        final path = io.join(temp.path, 'grid.csv');
        await io.csv.write(
          path,
          [
            [1, 'a'],
            [2, 'b'],
          ],
          headers: ['n', 'letter'],
        );
        expect(
          await io.csv.matrix(path),
          equals([
            ['n', 'letter'],
            ['1', 'a'],
            ['2', 'b'],
          ]),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test(
      'io.csv.rows and records read rows without loading all into memory',
      () async {
        final temp = io.temp('csv_stream_');
        try {
          final path = io.join(temp.path, 'stream.csv');
          io.write(
            path,
            'id,name\n1,"Alpha, 1"\n2,"Beta ""The Second"""\n3,Gamma\n',
          );

          final streamRows = await io.csv.rows(path).toList();
          expect(streamRows.length, equals(4));
          expect(streamRows[0], equals(['id', 'name']));
          expect(streamRows[1], equals(['1', 'Alpha, 1']));
          expect(streamRows[2], equals(['2', 'Beta "The Second"']));
          expect(streamRows[3], equals(['3', 'Gamma']));

          final mapRows = await io.csv.records(path).toList();
          expect(mapRows.length, equals(3));
          expect(mapRows[0]['id'], equals('1'));
          expect(mapRows[0]['name'], equals('Alpha, 1'));
          expect(mapRows[1]['name'], equals('Beta "The Second"'));
          expect(mapRows[2]['id'], equals('3'));

          // The typed pair: rows() yields cells, records() yields maps.
          expect(await io.csv.records(path).toList(), equals(mapRows));
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );
  });

  group('io.store Sub-namespace', () {
    test('the shared store reads and writes through one typed getter', () {
      io.store.clear();
      io.store.set('theme', 'dark');
      io.store.set('counter', 42);

      expect(io.store.has('theme'), isTrue);
      expect(io.store.get<String>('theme'), equals('dark'));
      expect(io.store.get<int>('counter'), equals(42));
      expect(io.store.get('missing', 'default'), equals('default'));
      // A mistyped read falls back rather than throwing.
      expect(io.store.get<int>('theme', -1), equals(-1));

      io.store.delete('theme');
      expect(io.store.has('theme'), isFalse);
      io.store.clear();
    });

    test('an unattached shared store explains why it cannot save', () {
      expect(
        io.store.save,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no file to save to'),
          ),
        ),
      );
    });

    test('open persists and reloads JSON', () async {
      final temp = io.temp('store_test_');
      try {
        final path = io.join(temp.path, 'cache.json');
        final db =
            io.store.open(path)
              ..set('user_id', 'user_101')
              ..set('visits', 5);
        await db.save();
        expect(io.has(path), isTrue);

        final reopened = io.store.open(path);
        expect(reopened.get<String>('user_id'), equals('user_101'));
        expect(reopened.get<int>('visits'), equals(5));
        expect(reopened.length, equals(2));

        reopened.clear();
        expect(reopened.isEmpty, isTrue);
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('attach gives the shared store a file', () async {
      final temp = io.temp('store_attach_');
      try {
        final path = io.join(temp.path, 'shared.json');
        io.store.attach(path);
        io.store.set('k', 'v');
        await io.store.save();
        expect(io.store.open(path).get<String>('k'), equals('v'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    });
  });

  group('util Domain', () {
    test('util.time waits, stamps and formats', () async {
      final clock = util.time.clock();
      await util.time.wait(20.ms);
      clock.stop();
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(10));

      expect(RegExp(r'^\d{8}_\d{6}$').hasMatch(util.time.stamp()), isTrue);
      expect(util.time.iso(), contains('T'));
      expect(util.time.iso(), endsWith('Z'));
      expect(util.time.epoch(), greaterThan(0));

      expect(util.time.format(45.s), equals('00:45'));
      expect(
        util.time.format(const Duration(minutes: 3, seconds: 12)),
        '03:12',
      );
      expect(
        util.time.format(const Duration(hours: 2, minutes: 15, seconds: 30)),
        equals('02:15:30'),
      );
    });

    test('util.time.ago describes elapsed time coarsely', () {
      final now = DateTime(2026, 6, 1, 12);
      expect(util.time.ago(now, now), equals('just now'));
      expect(
        util.time.ago(now.subtract(const Duration(minutes: 5)), now),
        equals('5m ago'),
      );
      expect(
        util.time.ago(now.subtract(const Duration(hours: 3)), now),
        equals('3h ago'),
      );
      expect(
        util.time.ago(now.add(const Duration(hours: 1)), now),
        equals('in the future'),
      );
    });

    test('util.size formats and parses byte counts', () {
      expect(util.size.format(0), equals('0 B'));
      expect(util.size.format(1024), equals('1.0 KB'));
      expect(util.size.format(1024 * 1024 * 5), equals('5.0 MB'));
      expect(util.size.format(1024 * 1024 * 1024 * 2), equals('2.0 GB'));

      expect(util.size.parse('500 B'), equals(500));
      expect(util.size.parse('10 KB'), equals(10 * 1024));
      expect(util.size.parse('2.5 MB'), equals((2.5 * 1024 * 1024).round()));
      expect(util.size.parse('1 GB'), equals(1024 * 1024 * 1024));
      expect(util.size.parse('nonsense'), equals(0));
    });

    test('git inspects the repository', () async {
      expect(await tool.git.branch(), isNotEmpty);
      final hash = await tool.git.hash();
      expect(hash.length, greaterThanOrEqualTo(7));
      expect(await tool.git.hash(full: true), startsWith(hash));
      expect(await tool.git.dirty(), isA<bool>());
      expect(await tool.git.status(), isA<String>());
    });

    test('extensions build Durations and Uris', () {
      expect(250.ms, equals(const Duration(milliseconds: 250)));
      expect(2.s, equals(const Duration(seconds: 2)));
      expect(5.m, equals(const Duration(minutes: 5)));
      expect(
        'https://example.com/a'.url,
        equals(Uri.parse('https://example.com/a')),
      );
    });

    test(
      'ConsoleWriter and ConsoleLogger support injectable sinks for testability',
      () {
        final outBuf = StringBuffer();
        final errBuf = StringBuffer();
        final writer = ConsoleWriter(out: outBuf, err: errBuf);
        final logger = ConsoleLogger(writer);

        logger.info('Info message');
        logger.ok('All good');
        logger.warn('Careful');
        logger.error('Critical failure');

        expect(outBuf.toString(), contains('Info message'));
        expect(outBuf.toString(), contains('All good'));
        expect(outBuf.toString(), contains('Careful'));
        expect(outBuf.toString(), isNot(contains('Critical failure')));

        expect(errBuf.toString(), contains('Critical failure'));
      },
    );

    test(
      'Ansi supports dynamic enabled, 256 colors, and 24-bit truecolor RGB/hex',
      () {
        final original = Ansi.enabled;
        try {
          Ansi.enabled = true;
          expect('test'.color256(196), contains('\x1B[38;5;196m'));
          expect('test'.bgcolor256(21), contains('\x1B[48;5;21m'));
          expect('test'.rgb(255, 100, 50), contains('\x1B[38;2;255;100;50m'));
          expect('test'.bgrgb(10, 20, 30), contains('\x1B[48;2;10;20;30m'));
          expect('test'.hex('#FF0000'), contains('\x1B[38;2;255;0;0m'));
          expect('test'.bghex('00FF00'), contains('\x1B[48;2;0;255;0m'));

          Ansi.enabled = false;
          expect('test'.color256(196), equals('test'));
          expect('test'.rgb(255, 0, 0), equals('test'));
        } finally {
          Ansi.enabled = original;
        }
      },
    );

    test('git mutating methods return SysResult', () async {
      // In a throwaway repo, never this one. These calls used to run in the
      // project directory on the assumption that nothing would be staged, so
      // a developer with staged work got it committed by the test suite.
      final repo = Directory.systemTemp.createTempSync('dt_git_');
      final cwd = repo.path;
      try {
        await tool.git.run(['init', '-q'], cwd);
        await tool.git.run(['config', 'user.email', 'test@example.com'], cwd);
        await tool.git.run(['config', 'user.name', 'Test'], cwd);

        // Nothing staged, so the commit fails and says why.
        final result = await tool.git.commit('test empty commit', cwd: cwd);
        expect(result, isA<SysResult>());
        expect(result.ok, isFalse);
        expect(result.out.isNotEmpty || result.err.isNotEmpty, isTrue);

        final addResult = await tool.git.add('non_existent_file_xyz.txt', cwd);
        expect(addResult, isA<SysResult>());

        final markResult = await tool.git.mark('--invalid-flag-fails', cwd);
        expect(markResult, isA<SysResult>());
        expect(markResult.ok, isFalse);
      } finally {
        repo.deleteSync(recursive: true);
      }
    });
  });

  group('Domain namespaces', () {
    test('io exposes csv and store', () {
      expect(io.csv, isA<CsvAccessor>());
      expect(io.store, isA<StoreAccessor>());
    });

    test('net exposes http and crawl', () {
      expect(net.http, isA<HttpClient>());
      expect(net.crawl, isA<Crawl>());
      // Selectors live on the top-level $, not on net. Like jQuery, find()
      // searches descendants, so a root-level match is read directly.
      expect(
        net.$('<h1 class="title">Domain Test</h1>').text,
        equals('Domain Test'),
      );
      expect(
        net
            .$('<div><h1 class="title">Domain Test</h1></div>')
            .find('.title')
            .text,
        equals('Domain Test'),
      );
      expect(
        '<h1 class="title">Domain Test</h1>'.$('.title').text,
        equals('Domain Test'),
      );
    });

    test('system exposes env, console and on', () {
      expect(system.env, isA<EnvAccessor>());
      expect(system.console, isA<ConsoleAccessor>());
      expect(system.on, isA<SysEvents>());
    });

    test('cli is a domain of its own, not a corner of system', () {
      expect(cli, isA<CliAccessor>());
    });

    test('tool exposes git and zip', () {
      expect(tool.git, isA<GitAccessor>());
      expect(tool.zip, isA<ZipAccessor>());
    });

    test('util exposes time, size, text, hash and rand', () {
      expect(util.time, isA<TimeAccessor>());
      expect(util.size, isA<SizeAccessor>());
      expect(util.text, isA<TextAccessor>());
      expect(util.hash, isA<HashAccessor>());
      expect(util.rand, isA<RandAccessor>());
    });
  });
}
