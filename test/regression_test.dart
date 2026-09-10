/// Regressions for defects found by auditing the library against its own
/// documentation. Each group names the behaviour that used to be wrong.
library;

import 'dart:async';
import 'dart:io';

// Imported unprefixed on purpose. `package:crypto` exports a `Digest` and
// `dart:io` a `Process`; this file compiling at all is the Rule 6 collision
// test, and it failed against both names before 1.6.0.
import 'dart:io' as dart_io;

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

    test('no exported name shadows dart:io any more', () {
      // The Rule 6 collisions 1.7.0 recorded and 2.0.0 paid off. `HttpClient`,
      // `HttpResponse` and `Cookie` used to be this library's — the package
      // import beat the `dart:` one with no diagnostic at all. Unprefixed,
      // they now resolve to dart:io's, which is what this pins.
      final theirs = HttpClient();
      addTearDown(theirs.close);
      expect(theirs, isA<dart_io.HttpClient>());
      expect(Cookie('a', 'b'), isA<dart_io.Cookie>());
      expect(HttpResponse, isNot(equals(Reply)));

      // And the toolkit's carry their own names, which collide with nothing.
      expect(Reply.text('<p>hi</p>').status, 200);
      expect(Morsel('a', 'b').name, 'a');
      final ours = Fetcher();
      addTearDown(ours.close);
      expect(ours.timeout, const Duration(seconds: 30));

      // `Fetch` and `Page` were the two that fought `package:http` for a name
      // and produced an ambiguous_import on use. Nothing to hide now.
      expect(Fetch<String>(Uri.parse('https://a.test')).url.host, 'a.test');
      expect(Page<String>, isNotNull);
    });
  });

  group('net.http cookies', () {
    test('a cookie with no Domain goes back only to the host that set it', () {
      final jar = CookieJar();
      jar.add('sid=abc; Path=/', uri: Uri.parse('https://example.com/'));

      // Host-only, per RFC 6265 section 5.3. It used to be stored with the
      // host as its Domain and matched by suffix, so a session cookie
      // followed the crawl into every subdomain it wandered through.
      expect(jar.header(Uri.parse('https://example.com/')), 'sid=abc');
      expect(jar.header(Uri.parse('https://sub.example.com/')), isNull);
      expect(jar.cookies.single.host, isTrue);
    });

    test('a Domain the host owns still widens to its subdomains', () {
      final jar = CookieJar();
      jar.add(
        'sid=abc; Domain=example.com; Path=/',
        uri: Uri.parse('https://example.com/'),
      );

      expect(jar.header(Uri.parse('https://sub.example.com/')), 'sid=abc');
      expect(jar.cookies.single.host, isFalse);
    });

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
    test('a flag reads the declared env variable', () {
      system.env.set('DT_REGRESSION_FLAG', 'true');
      addTearDown(() => system.env.delete('DT_REGRESSION_FLAG'));

      final force = Cli(const []).flag('force', env: 'DT_REGRESSION_FLAG');
      expect(force(), isTrue);
    });

    test('env beats def for bool, matching every other type', () {
      system.env.set('DT_REGRESSION_MODE', 'off');
      addTearDown(() => system.env.delete('DT_REGRESSION_MODE'));

      final colour = Cli(
        const [],
      ).flag('colour', env: 'DT_REGRESSION_MODE', def: true);
      expect(colour(), isFalse);
    });

    test('the command line still beats env', () {
      system.env.set('DT_REGRESSION_FLAG', 'false');
      addTearDown(() => system.env.delete('DT_REGRESSION_FLAG'));

      final force = Cli(const [
        '--force',
      ]).flag('force', env: 'DT_REGRESSION_FLAG');
      expect(force(), isTrue);
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
    test('Stats.retried counts the retries the client actually made', () async {
      var attempts = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((fetch) async {
        attempts++;
        if (attempts <= 2) {
          fetch.response.statusCode = 503;
        } else {
          fetch.response.headers.contentType = ContentType.html;
          fetch.response.write('<h1>ok</h1>');
        }
        await fetch.response.close();
      });

      final stats = await net
          .crawl<String>('http://127.0.0.1:${server.port}/')
          .retry(3)
          .run((res) {});

      // Retrying happens inside the client, so the engine only knows because
      // the downloader tells it. The counter read zero however hard it tried.
      expect(attempts, 3);
      expect(stats.retried, 2);
      expect(stats.completed, 1);
    });

    test('save writes through a .part file and creates its folder', () async {
      final dir = io.temp('dt_save_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final dest = io.join(dir.path, 'nested', 'items.txt');

      await net
          .crawl<String>('https://site.test/')
          .downloader(MapDownloader<String>({'/': '<h1>hi</h1>'}))
          .save(dest, (res) => res.emit('one'));

      // The folder did not exist: opening the destination directly threw.
      expect(io.read(dest).trim(), 'one');
      expect(io.find(dir.path, pattern: RegExp(r'\.part$')), isEmpty);
    });

    test('the destination is replaced only once the run finishes', () async {
      final dir = io.temp('dt_save_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final dest = io.join(dir.path, 'items.txt');
      io.write(dest, 'PREVIOUS');

      final slow = _SlowDownloader<String>(const Duration(milliseconds: 200));
      final run = net
          .crawl<String>('https://site.test/')
          .downloader(slow)
          .save(dest, (res) => res.emit('one'));

      await Future<void>.delayed(const Duration(milliseconds: 60));
      // Mid-run: the destination used to have been truncated on the way in,
      // so an interrupted crawl took the last good results down with it.
      expect(io.read(dest), 'PREVIOUS');

      await run;
      expect(io.read(dest).trim(), 'one');
      expect(io.find(dir.path, pattern: RegExp(r'\.part$')), isEmpty);
    });

    test('a save whose seeds cannot be resolved keeps the old file', () async {
      final dir = io.temp('dt_save_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final dest = io.join(dir.path, 'items.txt');
      io.write(dest, 'PREVIOUS');

      await _withFailFastClient(() async {
        await expectLater(
          net.crawl
              .sitemap<String>(Uri.parse('http://127.0.0.1:1/sitemap.xml'))
              .save(dest, (res) => res.emit('one')),
          throwsA(anything),
        );
      });

      expect(io.read(dest), 'PREVIOUS');
      expect(io.find(dir.path, pattern: RegExp(r'\.part$')), isEmpty);
    });

    test('a stream whose seeds cannot be resolved still ends', () async {
      final events = <String>[];
      final ended = Completer<void>();

      await _withFailFastClient(() async {
        net.crawl
            .sitemap<String>(Uri.parse('http://127.0.0.1:1/sitemap.xml'))
            .stream((res) => res.emit('x'))
            .listen(
              (_) => events.add('item'),
              onError: (Object _) => events.add('error'),
              onDone: () {
                events.add('done');
                if (!ended.isCompleted) ended.complete();
              },
              cancelOnError: false,
            );

        // The stream used to carry the error and then stay open forever, with
        // the resume hook still holding the process alive behind it.
        await ended.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () => events.add('never closed'),
        );
      });

      expect(events, ['error', 'done']);
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
      expect(
        const PoolFailure<String, int>([]).toString(),
        contains('no failures'),
      );
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
      expect(system.console.progress(total: 1).fill, Progress(total: 1).fill);
      expect(system.console.progress(total: 1).empty, Progress(total: 1).empty);
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

  group('net.http extraction', () {
    test('the repeated @text shorthand reads text as a browser renders it', () {
      final res = Reply.text(
        '<a class="t">Wireless\n        Keyboard</a><a class="t">Mouse</a>',
      );

      // Every other spelling collapsed the page's indentation; the plural
      // attribute form handed back the source.
      expect(
        res.extract({
          'x': const ['.t@text'],
        }),
        {
          'x': ['Wireless Keyboard', 'Mouse'],
        },
      );
      expect(
        res.extract({
          'x': const ['.t'],
        }),
        {
          'x': ['Wireless Keyboard', 'Mouse'],
        },
      );
      expect(res.pick(Field.attrs('.t', 'text')), [
        'Wireless Keyboard',
        'Mouse',
      ]);
    });

    test('a fixture that says where it came from resolves from there', () {
      final res = Reply.text(
        '<h1>hi</h1>',
        requested: 'https://example.com/a/b'.url,
      );

      // It used to sit at localhost however clearly the caller had said
      // otherwise, so anything resolving against it resolved wrong.
      expect(res.url, Uri.parse('https://example.com/a/b'));
      expect(res.requested, Uri.parse('https://example.com/a/b'));
    });
  });

  group('concurrent.retry', () {
    test('its backoff draws from the one seeded generator', () async {
      util.rand.seed(1);
      util.rand.jitter(const Duration(seconds: 1));
      final second = util.rand.jitter(const Duration(seconds: 1));

      util.rand.seed(1);
      var attempts = 0;
      await concurrent.retry(
        () {
          attempts++;
          if (attempts < 2) throw StateError('again');
          return attempts;
        },
        times: 3,
        backoff: const Duration(milliseconds: 1),
      );
      addTearDown(util.rand.seed);

      // One retry, so one draw: the next value is the second of the seeded
      // sequence. A Random of its own used to make `util.rand.seed` a
      // promise this half of the library did not keep.
      expect(util.rand.jitter(const Duration(seconds: 1)), second);
    });
  });

  group('util.size', () {
    test('parse reads back everything format writes', () {
      for (final bytes in [
        0,
        512,
        2048,
        5 * 1024 * 1024,
        3 * 1024 * 1024 * 1024,
        7 * 1024 * 1024 * 1024 * 1024,
        // Petabytes: format printed them and parse answered 0.
        3 * 1024 * 1024 * 1024 * 1024 * 1024,
      ]) {
        expect(
          util.size.parse(util.size.format(bytes)),
          bytes,
          reason: '\$bytes',
        );
      }
      expect(util.size.parse('2 P'), 2 * 1024 * 1024 * 1024 * 1024 * 1024);
      // A unit nobody knows is still refused rather than read as bytes.
      expect(util.size.parse('10 XB'), 0);
    });
  });
}

/// Runs [body] against a shared client that gives up at the first refusal,
/// so a test of a failing fetch does not sit through the retry backoff.
Future<void> _withFailFastClient(Future<void> Function() body) async {
  final previous = net.http;
  await net.use(
    Fetcher(retries: 0, timeout: const Duration(seconds: 2)),
    close: false,
  );
  try {
    await body();
  } finally {
    await net.use(previous);
  }
}

/// A downloader that takes its time, for watching what a run leaves behind
/// while it is still going.
class _SlowDownloader<T> extends Downloader<T> {
  _SlowDownloader(this.pause);

  /// How long each fetch takes.
  final Duration pause;

  @override
  Future<Page<T>> download(Fetch<T> fetch) async {
    await Future<void>.delayed(pause);
    return Page<T>(
      fetch: fetch,
      status: 200,
      headers: const {'content-type': 'text/html'},
      bytes: '<h1>hi</h1>'.codeUnits,
      engine: engine,
    );
  }
}

void _noop(Page<String> response) {}
