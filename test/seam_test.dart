import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

/// The injectable IO seam must cover every path that writes to the console,
/// and must also drive the decision about *what* to render.
void main() {
  group('ConsoleIo seam', () {
    late StringBuffer out;

    setUp(() {
      out = StringBuffer();
      ConsoleIo.out = out;
    });

    tearDown(() {
      ConsoleIo.reset();
      Ansi.enabled = null;
      Env.remove('NO_COLOR');
    });

    test('captures subprocess output, not just Logger output', () async {
      Logger.ok('via Logger');
      await run('echo SUBPROCESS_MARKER');

      expect(out.toString(), contains('via Logger'));
      expect(out.toString(), contains('SUBPROCESS_MARKER'));
    });

    test('quiet: true still suppresses subprocess output', () async {
      final result = await run('echo QUIET_MARKER', quiet: true);

      expect(result.stdout, contains('QUIET_MARKER'));
      expect(out.toString(), isNot(contains('QUIET_MARKER')));
    });

    test('a redirected sink is never treated as a terminal', () {
      expect(ConsoleIo.isTerminal, isFalse);
      expect(ConsoleIo.columns, isNull);
    });

    test('a redirected sink disables ANSI unless explicitly overridden', () {
      expect(Ansi.enabled, isFalse);

      Ansi.enabled = true;
      expect(Ansi.enabled, isTrue);
    });

    test('Ansi resolves override, then NO_COLOR, then the sink', () {
      ConsoleIo.reset();

      // 1. An explicit override wins over everything.
      Ansi.enabled = true;
      Env.set('NO_COLOR', '1');
      expect(Ansi.enabled, isTrue, reason: 'explicit override beats NO_COLOR');

      // 2. With no override, NO_COLOR read from Env disables styling. The value
      //    lives in Env only -- Platform.environment never sees it -- so this
      //    pins Env as the source Ansi consults.
      Ansi.enabled = null;
      expect(Platform.environment.containsKey('NO_COLOR'), isFalse);
      expect(Env.has('NO_COLOR'), isTrue);
      expect(Ansi.enabled, isFalse);
    });

    test('ConsoleMultiProgress reports each completion without a terminal', () {
      final progress = Console.multiProgress(total: 3, slots: 2, message: 'files', columns: 80);

      for (final name in ['a.txt', 'b.txt', 'c.txt']) {
        progress.updateTask(name, label: name, ratio: 0.5, received: 512, total: 1024);
        progress.tick();
        progress.updateTask(name, label: name, ratio: 1.0, received: 1024, total: 1024, isDone: true);
      }
      progress.done('finished');

      final lines = out.toString().trim().split('\n');
      expect(lines.length, greaterThanOrEqualTo(4));
      for (final name in ['a.txt', 'b.txt', 'c.txt']) {
        expect(lines.where((l) => l.contains(name)).length, equals(1), reason: '\$name reported exactly once');
      }
      expect(lines.last, contains('finished'));
    });

    test('report() renders a BatchProgress without the caller restating its fields', () {
      final progress = Console.multiProgress(slots: 2, message: 'files', columns: 80);
      final url = 'https://example.com/a.txt'.url;
      final path = Path('out/a.txt');

      progress.report(
        BatchDownloadProgress(
          completed: 0,
          total: null,
          written: 0,
          current: Downloading(url, path, received: 512, total: 1024),
        ),
      );
      expect(progress.total, equals(0), reason: 'an open stream has no total yet');

      progress.report(BatchDownloadProgress(completed: 1, total: 2, written: 1, current: Downloaded(url, path, 1024)));
      expect(progress.total, equals(2), reason: 'total is revised as the source discovers work');

      progress.report(
        BatchDownloadProgress(completed: 2, total: 2, written: 1, current: DownloadSkipped(url, Path('out/b.txt'))),
      );
      progress.done('finished');

      final lines = out.toString().trim().split('\n');
      expect(lines.any((l) => l.contains('a.txt') && l.contains('[done]')), isTrue);
      expect(lines.any((l) => l.contains('b.txt') && l.contains('[skipped]')), isTrue);
    });

    test('ConsoleProgress still reports a line per tick without a terminal', () {
      final progress = Console.progress(3, message: 'files', columns: 80);
      progress
        ..tick()
        ..tick()
        ..tick();
      progress.done('finished');

      expect(out.toString().trim().split('\n').length, equals(4));
    });
  });

  group('scrape -> download -> progress, over real sockets', () {
    late HttpServer server;
    late Uri base;
    late Directory tempDir;
    late StringBuffer out;

    setUp(() async {
      out = StringBuffer();
      ConsoleIo.out = out;
      tempDir = Directory.systemTemp.createTempSync('pipeline_test_');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((req) {
        final path = req.uri.path;
        final res = req.response;
        if (path == '/index') {
          res.write([for (var i = 1; i <= 3; i++) '<a class="track" href="/track/$i">t$i</a>'].join());
        } else if (path.startsWith('/track/')) {
          res.write('<a href="/file/${path.split('/').last}.mp3">dl</a>');
        } else if (path.startsWith('/file/') || path.startsWith('/art/')) {
          final body = List<int>.filled(64, 7);
          res.headers.contentLength = body.length;
          res.add(body);
        } else {
          res.statusCode = 404;
        }
        res.close();
      });
    });

    tearDown(() async {
      ConsoleIo.reset();
      await server.close(force: true);
      tempDir.deleteSync(recursive: true);
    });

    test('one session, overlapped discovery, one report() per update', () async {
      final dir = Path(tempDir.path);
      final artwork = <Uri, Path>{
        base.resolve('/art/1.png'): dir / 'art' / '1.png',
        base.resolve('/art/2.png'): dir / 'art' / '2.png',
      };

      final progress = Console.multiProgress(slots: 2, message: 'Downloading');
      BatchDownloadProgress? last;

      await Http.session(() async {
        Stream<({Uri url, Path path})> queue() async* {
          yield* Stream.fromIterable(artwork.pairs);
          yield* base.resolve('/index').scrape<({Uri url, Path path})>((ctx) {
            for (final a in ctx.response.html().$('a.track')) {
              ctx.follow(
                a.attr('href')!,
                callback: (song) {
                  final href = song.response.html().$('a').first.attr('href')!;
                  song.emit((url: song.resolve(href), path: dir / 'tracks' / song.url.pathSegments.last));
                },
              );
            }
          }, concurrency: 2);
        }

        await for (final p in queue().downloadAll(concurrency: 2)) {
          progress.report(last = p);
        }
      });
      progress.done('done');

      expect(last, isNotNull);
      expect(last!.total, equals(5), reason: 'two artworks plus three scraped tracks');
      expect(last!.completed, equals(5));
      expect(last!.written, equals(5));
      expect(last!.current, isA<Downloaded>());

      expect((dir / 'art' / '1.png').existsSync(), isTrue);
      for (var i = 1; i <= 3; i++) {
        expect((dir / 'tracks' / '$i').existsSync(), isTrue, reason: 'track $i landed');
      }

      // Every completion is reported exactly once, without a terminal.
      final lines = out.toString().trim().split('\n');
      expect(lines.where((l) => l.contains('[done]')).length, equals(5));

      // Re-running skips what is already on disk instead of re-fetching it.
      final again = await artwork.downloadAll().toList();
      expect(again.last.written, equals(0));
      expect(again.every((p) => p.current is DownloadSkipped), isTrue);
    });

    test('a paused consumer stops the crawl instead of buffering it', () async {
      // /chain/n links to /chain/n+1, so the frontier is as long as the crawl runs.
      var served = 0;
      final chain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      chain.listen((req) {
        served++;
        final n = int.parse(req.uri.pathSegments.last);
        req.response
          ..write(n < 200 ? '<a href="/chain/${n + 1}">next</a>' : '')
          ..close();
      });
      addTearDown(() => chain.close(force: true));

      final root = Uri.parse('http://127.0.0.1:${chain.port}/chain/0');
      const concurrency = 4;
      final sub = root
          .scrape<String>((ctx) {
            ctx.emit(ctx.url.toString());
            for (final a in ctx.response.html().$('a')) {
              final href = a.attr('href');
              if (href != null) ctx.follow(href);
            }
          }, concurrency: concurrency)
          .listen((_) {});

      sub.pause();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Bounded by the in-flight requests, not by the size of the frontier.
      expect(served, lessThanOrEqualTo(concurrency + 1), reason: 'fetched $served pages while paused');

      sub.resume();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(served, greaterThan(concurrency + 1), reason: 'resuming restarts the crawl');
      await sub.cancel();
    });
  });
}
