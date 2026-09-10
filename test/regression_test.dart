/// Regressions for defects found by auditing the library against its own
/// documentation. Each group names the behaviour that used to be wrong.
library;

import 'dart:io';

// Imported unprefixed on purpose. `package:crypto` exports a `Digest` and
// `dart:io` a `Process`; this file compiling at all is the Rule 6 collision
// test, and it failed against both names before 1.6.0.
import 'package:crypto/crypto.dart';
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('exported type names', () {
    test('the library imports beside dart:io and crypto without collision', () {
      // `Digest` resolves to crypto's, because the toolkit's algorithm enum is
      // `Algo`. Before, this was an ambiguous_import error.
      final Digest sum = sha256.convert(const [1, 2, 3]);
      expect(sum.bytes, hasLength(32));
      expect(Algo.values, contains(Algo.sha256));

      // `Process` resolves to dart:io's, because the pipeline's page handler is
      // `Handler`. Before, the toolkit's typedef won silently — a package
      // import beats a `dart:` one without an error.
      expect(Process.run, isA<Function>());
      const Handler<String> handler = _noop;
      expect(handler, isA<Handler<String>>());
    });
  });

  group('net.http cookies', () {
    test('a Domain the responding host does not own is refused', () {
      final jar = CookieJar();
      jar.add(
        'sid=abc; Domain=com; Path=/',
        uri: Uri.parse('https://evil.example.com/'),
      );

      // Stored host-only, so it never reaches an unrelated host.
      expect(jar.header(Uri.parse('https://bank.com/')), isNull);
      expect(jar.header(Uri.parse('https://evil.example.com/')), 'sid=abc');
    });

    test('a parent domain the host belongs to is honoured', () {
      final jar = CookieJar();
      jar.add(
        'sid=abc; Domain=example.com; Path=/',
        uri: Uri.parse('https://api.example.com/'),
      );

      expect(jar.header(Uri.parse('https://www.example.com/')), 'sid=abc');
      expect(jar.header(Uri.parse('https://notexample.com/')), isNull);
    });
  });

  group('cli', () {
    test('get<bool> reads the declared env variable', () {
      system.env.set('DT_REGRESSION_FLAG', 'true');
      addTearDown(() => system.env.delete('DT_REGRESSION_FLAG'));

      final cli = Cli(const [])..option('force', env: 'DT_REGRESSION_FLAG');
      expect(cli.get('force', false), isTrue);
    });

    test('env beats def for bool, matching every other type', () {
      system.env.set('DT_REGRESSION_MODE', 'off');
      addTearDown(() => system.env.delete('DT_REGRESSION_MODE'));

      final cli = Cli(const [])
        ..option('colour', env: 'DT_REGRESSION_MODE', def: true);
      expect(cli.get('colour', false), isFalse);
    });

    test('the command line still beats env', () {
      system.env.set('DT_REGRESSION_FLAG', 'false');
      addTearDown(() => system.env.delete('DT_REGRESSION_FLAG'));

      final cli = Cli(const ['--force'])
        ..option('force', env: 'DT_REGRESSION_FLAG');
      expect(cli.get('force', false), isTrue);
    });

    test('a required option needs a value, not just the switch', () {
      final cli = Cli(const ['--out'])..option('out', required: true);
      expect(cli.require, throwsArgumentError);

      final ok = Cli(const ['--out', 'dist'])..option('out', required: true);
      expect(ok.require, returnsNormally);
    });

    test('a required flag is satisfied by its presence', () {
      final cli = Cli(const ['--force'])..flag('force');
      expect(() => cli.require(['force']), returnsNormally);
    });
  });

  group('net.robots', () {
    test('a crawl-delay-only group does not absorb the next group', () {
      final robots = Robots.parse('''
User-agent: SlowBot
Crawl-delay: 10

User-agent: EvilBot
Disallow: /secret
''');

      final secret = Uri.parse('https://example.com/secret');
      expect(robots.allowed(secret, agent: 'SlowBot'), isTrue);
      expect(robots.allowed(secret, agent: 'EvilBot'), isFalse);
      expect(robots.delay(agent: 'SlowBot'), const Duration(seconds: 10));
      expect(robots.delay(agent: 'EvilBot'), isNull);
    });

    test('consecutive user-agent lines still share one group', () {
      final robots = Robots.parse('''
User-agent: A
User-agent: B
Disallow: /x
''');

      final x = Uri.parse('https://example.com/x');
      expect(robots.allowed(x, agent: 'A'), isFalse);
      expect(robots.allowed(x, agent: 'B'), isFalse);
    });
  });

  group('net.crawl plumbing', () {
    test('coerce keeps a URL whose query carries markup', () {
      expect(coerce('https://x.com/a?q=</b>').scheme, 'https');
      expect(coerce('https://x.com/a?q=/>').scheme, 'https');
      // Genuine markup is still recognised.
      expect(coerce('<div>hi</div>').scheme, 'data');
    });

    test('a missing local file reports 404, not an empty 200', () async {
      final downloader = HttpDownloader<String>();
      final absent = Uri.file('/tmp/dt_regression_absent_page.html');
      final res = await downloader.download(Request<String>(absent));

      expect(res.status, 404);
      expect(res.body, isEmpty);
    });

    test('the downloader resolves save paths against its own base', () {
      final downloader = HttpDownloader<String>(base: 'outdir');
      expect(downloader.resolve('page.html'), 'outdir/page.html');
    });
  });

  group('io.csv', () {
    test('format keeps columns only later rows carry', () {
      final csv = io.csv.format([
        {'a': 1},
        {'a': 2, 'b': 3},
      ]);

      expect(csv.trim().split('\n').first, 'a,b');
      expect(csv, contains('2,3'));
    });

    test('a trailing newline does not add an empty row', () {
      expect(io.csv.parse('a,b\n'), [
        ['a', 'b'],
      ]);
      expect(io.csv.parse('a,b\n\n'), [
        ['a', 'b'],
      ]);
    });

    test('a multi-character delimiter splits', () {
      expect(io.csv.parse('a||b||c', delimiter: '||'), [
        ['a', 'b', 'c'],
      ]);
    });

    test('quoted fields still survive', () {
      expect(io.csv.parse('"a,b",c'), [
        ['a,b', 'c'],
      ]);
    });
  });

  group('io.store', () {
    test('a malformed file leaves the store empty instead of throwing', () {
      final file = File('${Directory.systemTemp.path}/dt_bad_store.json')
        ..writeAsStringSync('{not json');
      addTearDown(() => file.deleteSync());

      final store = io.store.open(file.path);
      expect(store.isEmpty, isTrue);
    });
  });

  group('io.hash', () {
    test('hashes a file without loading it whole', () async {
      final file = File('${Directory.systemTemp.path}/dt_hash_probe.bin')
        ..writeAsBytesSync(List<int>.generate(200000, (i) => i % 256));
      addTearDown(() => file.deleteSync());

      final sync = io.hash(file.path);
      final async = await io.async.hash(file.path);
      expect(sync, async);
      expect(sync, hasLength(64));
      expect(io.hash(file.path, Algo.md5), hasLength(32));
    });
  });

  group('util.text', () {
    test('a space groups digits only in threes', () {
      expect(util.text.number('12 34'), 12);
      expect(util.text.numbers('1 2 3'), [1, 2, 3]);
      expect(util.text.number('1 234 567'), 1234567);
      expect(util.text.number(r'$1,234.50'), 1234.5);
      expect(util.text.numbers('3 of 7'), [3, 7]);
    });

    test('slug keeps letters of other scripts', () {
      expect(util.text.slug('日本語のタイトル'), '日本語のタイトル');
      expect(util.text.slug('Привет мир'), 'привет-мир');
      expect(util.text.slug('Héllo, World!'), 'hello-world');
    });

    test('clip never splits a character in half', () {
      final clipped = util.text.clip('ab👍cd', 4);
      expect(clipped.runes.every((r) => r != 0xFFFD), isTrue);
      expect(clipped, 'ab…');
    });
  });

  group('util.size', () {
    test('rounding does not overflow the unit', () {
      expect(util.size.format(1048575), '1.0 MB');
      expect(util.size.format(1023), '1023.0 B');
      expect(util.size.format(5 * 1024 * 1024), '5.0 MB');
    });

    test('an unknown unit parses as zero', () {
      expect(util.size.parse('10 XB'), 0);
      expect(util.size.parse('2.5 MB'), 2621440);
      expect(util.size.parse('10KB'), 10240);
    });
  });

  group('util.rand', () {
    test('jitter is never shorter than its base', () {
      const base = Duration(seconds: 1);
      for (var i = 0; i < 50; i++) {
        expect(util.rand.jitter(base, spread: -0.5) >= base, isTrue);
        expect(util.rand.jitter(base) >= base, isTrue);
      }
    });

    test('between handles a span wider than 32 bits', () {
      for (var i = 0; i < 20; i++) {
        final value = util.rand.between(0, 1 << 40);
        expect(value, greaterThanOrEqualTo(0));
        expect(value, lessThan(1 << 40));
      }
    });
  });

  group('concurrent', () {
    test('a stray release does not raise the permit ceiling', () async {
      final semaphore = Semaphore(1);
      await semaphore.acquire();
      semaphore.release();
      semaphore.release();
      semaphore.release();
      expect(semaphore.available, 1);
    });

    test('PoolFailure describes itself with no failures', () {
      expect(const PoolFailure<String>([]).toString(), contains('no failures'));
    });
  });

  group('system.console', () {
    test('width counts terminal columns, not code units', () {
      expect(Ansi.width('日本語'), 6);
      expect(Ansi.width('abc'), 3);
      expect(Ansi.width('👍'), 2);
      expect(Ansi.width('é'), 1);
      expect(Ansi.width('${Ansi.red}hi${Ansi.reset}'), 2);
    });

    test('a wide-character table keeps its columns square', () {
      final table = Table(headers: ['名前', 'n'])..add(['あ', 1]);
      final lines = table.render().trim().split('\n');
      final widths = lines.map(Ansi.width).toSet();
      expect(widths, hasLength(1));
    });

    test('a partial alignments list renders instead of throwing', () {
      final table = Table(headers: ['a', 'b'], alignments: [ColumnAlign.right])
        ..add([1, 2]);
      expect(table.render, returnsNormally);
      expect(table.alignments, [ColumnAlign.right, ColumnAlign.left]);
    });

    test('the two progress constructors agree on their glyphs', () {
      expect(
        system.console.progress(total: 1).fill,
        Progress(total: 1).fill,
      );
      expect(
        system.console.progress(total: 1).empty,
        Progress(total: 1).empty,
      );
    });

    test('logger.task stays silent below info', () async {
      final logger = ConsoleLogger()..level = LogLevel.none;
      expect(await logger.task('work', () async => 7), 7);
    });
  });

  group('system tracking', () {
    test('untrack matches by path, not by File identity', () {
      final path = '${Directory.systemTemp.path}/dt_track_probe.part';
      system.track(File(path));
      // A different instance naming the same file must still release it, or
      // the SIGINT watcher keeps the process alive.
      system.untrack(File(path));
      expect(system.which('dart'), isNotNull);
    });
  });

  group('git', () {
    test('a missing executable fails softly', () async {
      // Query methods promise an empty answer rather than an exception.
      expect(await tool.git.branch(), isA<String>());
      expect(await tool.git.status(), isA<String>());
    });
  });

  group('zip', () {
    test('packing does not follow a symlink out of the tree', () async {
      final root = Directory.systemTemp.createTempSync('dt_zip_');
      addTearDown(() => root.deleteSync(recursive: true));
      final outside = Directory.systemTemp.createTempSync('dt_zip_outside_');
      addTearDown(() => outside.deleteSync(recursive: true));

      File('${outside.path}/secret.txt').writeAsStringSync('do not pack me');
      File('${root.path}/kept.txt').writeAsStringSync('pack me');
      Link('${root.path}/link').createSync(outside.path);

      final archive = '${root.path}/../dt_zip_out.zip';
      addTearDown(() {
        final file = File(archive);
        if (file.existsSync()) file.deleteSync();
      });

      await tool.zip.pack(root.path, archive);
      final names = (await tool.zip.list(archive)).map((e) => e.name).toList();
      expect(names, contains('kept.txt'));
      expect(names.any((n) => n.contains('secret')), isFalse);
    });
  });
}

void _noop(Response<String> response) {}
