import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/scrape.dart';
import 'package:test/test.dart' hide Retry;

import 'support.dart';

/// A site of HTML pages in memory: each path's page, `null` a 404; [asked] counts the requests.
final class _Site {
  final Map<String, String> pages;
  final asked = <Request>[];

  /// Answers a path not in [pages] instead of a 404, when set.
  Response Function(Request request)? other;

  _Site(this.pages);

  late final client = Client.fake((request) {
    asked.add(request);
    final page = pages[request.url.path];
    if (page != null) return Response(page, 200, headers: {'content-type': 'text/html'}, url: request.url);
    if (other case final answer?) return answer(request);
    return Response('missing', 404, url: request.url);
  });

  /// [body] run with this site as the client, retries quick.
  Future<R> scope<R>(FutureOr<R> Function() body, {Retry retry = const Retry(2, backoff: Duration(milliseconds: 1))}) =>
      Http.scope(client: client, retry: retry, body);

  List<String> get paths => [for (final r in asked) r.url.path];
}

final _home = Uri.parse('https://site.test/');

/// Every `<a>` on the page followed, every `<h2>` emitted.
void _read(ResponseContext<String> ctx) {
  for (final h in ctx.html.$('h2')) {
    ctx.emit(h.text);
  }
  for (final link in ctx.html.$('a').links) {
    ctx.follow(link);
  }
}

/// A crawler whose state is its fields.
final class _Books extends Crawler<String> {
  final titles = <String>{};
  var failed = 0;

  _Books() : super(depth: 5);

  @override
  void onResponse(ResponseContext<String> ctx) {
    for (final h in ctx.html.$('h2')) {
      if (titles.add(h.text)) ctx.emit(h.text);
    }
    ctx.follow(ctx.html.$('a.next').firstOrNull?.link);
  }

  @override
  void onError(ErrorContext<String> ctx) {
    failed++;
    ctx.ignore();
  }
}

void main() {
  group('a crawl', () {
    test('is a batch of pages: Done(page, items), an empty page too, and items flat', () async {
      final site = _Site({
        '/': '<h2>a</h2><a href="/p">p</a><a href="/q#frag">q</a>',
        '/p': '<h2>b</h2><h2>c</h2>',
        '/q': 'nothing here',
      });
      await site.scope(() async {
        final crawl = _home.crawl<String>(onResponse: _read);
        final done = <String, List<String>>{};
        final watching = crawl.statuses.listen((s) {
          if (s case Done(:final item, :final value)) done[item.path] = value;
        }).asFuture<void>();
        expect(await crawl, [
          ['a'],
          ['b', 'c'],
          <String>[],
        ]);
        await watching;
        expect(done, {
          '/': ['a'],
          '/p': ['b', 'c'],
          '/q': <String>[],
        });
        expect(await crawl.items.toList(), ['a', 'b', 'c'], reason: 'a late listener hears every item');
        expect(crawl.count, 3);
        expect((await crawl.toMap()).keys.map((u) => u.path), ['/', '/p', '/q']);
      });
      expect(site.paths, ['/', '/p', '/q'], reason: 'a fragment is the same page');
    });

    test('a page is seen once; a follow says whether it was scheduled', () async {
      final scheduled = <bool>[];
      final site = _Site({'/': '<a href="/a">a</a>', '/a': '<a href="/">home</a>'});
      await site.scope(
        () => _home.crawl<String>(
          onResponse: (ctx) {
            for (final link in ctx.html.$('a').links) {
              scheduled.add(ctx.follow(link));
            }
            scheduled.add(ctx.follow(null));
          },
        ),
      );
      expect(site.paths, ['/', '/a']);
      expect(scheduled, [true, false, false, false]);
    });

    test('within: by default the seeds\' hosts, www. or not; a follow elsewhere is dropped', () async {
      final site = _Site({
        '/': '<a href="https://www.site.test/w">w</a><a href="https://other.test/o">o</a>',
        '/w': '',
        '/o': '',
      });
      await site.scope(() => _home.crawl<String>(onResponse: _read));
      expect([for (final r in site.asked) '${r.url}'], ['https://site.test/', 'https://www.site.test/w']);
      site.asked.clear();
      await site.scope(() => _home.crawl<String>(within: (u) => u.path != '/w', onResponse: _read));
      expect(site.paths, ['/', '/o']);
    });

    test('depth: and pages: bound the crawl; bad values are ArgumentErrors', () async {
      final site = _Site({for (var i = 0; i < 10; i++) '/${i == 0 ? '' : i}': '<a href="/${i + 1}">next</a>'});
      await site.scope(() => _home.crawl<String>(depth: 2, onResponse: _read));
      expect(site.paths, ['/', '/1', '/2']);
      site.asked.clear();
      await site.scope(() => _home.crawl<String>(pages: 3, onResponse: _read));
      expect(site.paths, hasLength(3));
      expect(() => _home.crawl<String>(depth: -1), throwsArgumentError);
      expect(() => _home.crawl<String>(pages: 0), throwsArgumentError);
      expect(() => _home.crawl<String>(concurrency: 0), throwsArgumentError);
    });

    test('stop() ends it: nothing more is sent, and it is a finished crawl', () async {
      final site = _Site({for (var i = 0; i < 20; i++) '/${i == 0 ? '' : i}': '<a href="/${i + 1}">n</a>'});
      final items = await site.scope(
        () => _home
            .crawl<String>(
              onResponse: (ctx) {
                ctx.emit(ctx.url.path);
                if (ctx.url.path == '/2') return ctx.stop();
                _read(ctx);
              },
            )
            .items
            .toList(),
      );
      expect(items, ['/', '/1', '/2']);
    });

    test('a 404 fails its page, and awaiting the crawl throws them all at the end', () async {
      final site = _Site({'/': '<a href="/gone">x</a><a href="/ok">y</a>', '/ok': '<h2>ok</h2>'});
      await site.scope(() async {
        final crawl = _home.crawl<String>(onResponse: _read);
        final error = await crawl.then<Object?>((_) => null, onError: (Object e) => e);
        expect(
          error,
          isA<BatchException<Uri, List<String>>>()
              .having((e) => e.failures.single.item.path, 'page', '/gone')
              .having((e) => e.failures.single.error, 'error', isA<StatusException>()),
        );
        // The items arrive, then the crawl's failure, so what is chained on them fails too.
        final heard = <String>[];
        final ended = await crawl.items.forEach(heard.add).then<Object?>((_) => null, onError: (Object e) => e);
        expect(heard, ['ok']);
        expect(ended, isA<BatchException<Uri, List<String>>>());
        await expectLater(
          crawl.items.parallelize((item) => item.length),
          throwsA(isA<BatchException<Uri, List<String>>>()),
        );
      });
    });

    test('a 5xx and a transport failure are retried, each retry a Warned on its page', () async {
      var n = 0;
      final site = _Site({});
      site.other = (r) {
        if (n++ < 2) return Response('busy', 503, url: r.url);
        return Response('<h2>fine</h2>', 200, headers: {'content-type': 'text/html'}, url: r.url);
      };
      await site.scope(() async {
        final crawl = _home.crawl<String>(onResponse: _read);
        final warned = crawl.statuses.where((s) => s is Warned).toList();
        expect(await crawl.items.toList(), ['fine']);
        expect(await warned, hasLength(2));
      });
    });

    test('a hook that throws an Error is a bug: it ends the crawl and is rethrown', () async {
      final site = _Site({'/': ''});
      await site.scope(() async {
        await expectLater(
          _home.crawl<String>(onResponse: (ctx) => throw StateError('mine')),
          throwsA(isA<StateError>()),
        );
      });
    });

    test('cancel stops it: Stopped, never Failed, and awaiting throws CancelledException', () async {
      final site = _Site({});
      final gate = Completer<void>();
      site.other = (r) => Response('<a href="${r.url.path}x">n</a>', 200, headers: {'content-type': 'text/html'});
      await site.scope(() async {
        final crawl = _home.crawl<String>(
          onResponse: (ctx) async {
            if (ctx.url.path.length > 3) await gate.future;
            _read(ctx);
          },
        );
        await crawl.statuses.firstWhere((s) => s.item.path.length > 3);
        crawl.cancel('enough');
        gate.complete();
        await expectLater(crawl, throwsA(isA<CancelledException>()));
        final settled = await crawl.settled;
        expect(settled.whereType<Failed<Uri, List<String>>>(), isEmpty);
      });
    });
  });

  group('redirects', () {
    test('a redirect out of within is Skipped(page, outside); one in it is the same page', () async {
      final site = _Site({});
      site.other = (r) => switch (r.url.path) {
        '/' => Response('<a href="/away">a</a><a href="/move">m</a>', 200, headers: {'content-type': 'text/html'}),
        '/away' => Response('', 302, headers: {'location': 'https://elsewhere.test/'}),
        '/move' => Response('', 301, headers: {'location': '/moved'}),
        _ => Response('<h2>${r.url.path}</h2>', 200, headers: {'content-type': 'text/html'}),
      };
      await site.scope(() async {
        final crawl = _home.crawl<String>(onResponse: _read);
        final statuses = await crawl.settled;
        expect(statuses.whereType<Skipped<Uri, List<String>>>().map((s) => '${s.item.path} ${s.reason}'), [
          '/away outside',
        ]);
        expect(await crawl.items.toList(), ['/moved']);
      });
      expect(site.paths, isNot(contains('elsewhere.test')));
    });

    test('a seed that redirects to another host moves the crawl there', () async {
      final site = _Site({});
      site.other = (r) => switch ('${r.url.host}${r.url.path}') {
        'site.test/' => Response('', 302, headers: {'location': 'https://new.test/'}),
        'new.test/' => Response('<a href="/b">b</a>', 200, headers: {'content-type': 'text/html'}),
        _ => Response('<h2>${r.url}</h2>', 200, headers: {'content-type': 'text/html'}),
      };
      final items = await site.scope(() => _home.crawl<String>(onResponse: _read).items.toList());
      expect(items, ['https://new.test/b']);
    });
  });

  group('hooks', () {
    test('onRequest edits what goes out, and skip() is Skipped(page, skipped)', () async {
      final site = _Site({'/': '<a href="/a">a</a><a href="/b">b</a>', '/a': '', '/b': ''});
      await site.scope(() async {
        final crawl = _home.crawl<String>(
          onRequest: (ctx) {
            ctx.headers['accept-language'] = 'en';
            if (ctx.url.path == '/b') ctx.skip();
          },
          onResponse: _read,
        );
        final settled = await crawl.settled;
        expect(settled.whereType<Skipped<Uri, List<String>>>().single.reason, 'skipped');
      });
      expect(site.paths, ['/', '/a']);
      expect(site.asked.every((r) => r.headers['accept-language'] == 'en'), isTrue);
      expect(site.asked.first.headers['user-agent'], 'dart-toolkit');
    });

    test('meta rides with a follow, and a follow can carry its own onResponse', () async {
      final site = _Site({'/': '<a href="/d">d</a>', '/d': '<h2>detail</h2>'});
      void detail(ResponseContext<String> ctx) => ctx.emit('${ctx.meta['from']}: ${ctx.html.$('h2').first.text}');
      final items = await site.scope(
        () => _home
            .crawl<String>(
              onResponse: (ctx) => ctx.follow(ctx.html.$('a').first.link, meta: {'from': 'home'}, onResponse: detail),
            )
            .items
            .toList(),
      );
      expect(items, ['home: detail']);
    });

    test('onError: retry counts against the policy, ignore and emit end the page Done', () async {
      final site = _Site({'/': '<a href="/a">a</a><a href="/b">b</a><a href="/c">c</a>'});
      final tries = <String, int>{};
      final crawl = site.scope(() async {
        final crawl = _home.crawl<String>(
          onResponse: _read,
          onError: (ctx) {
            tries[ctx.url.path] = ctx.attempt;
            switch (ctx.url.path) {
              case '/a':
                ctx.retry();
              case '/b':
                ctx.ignore();
              case '/c':
                ctx.emit('fallback');
            }
          },
        );
        final settled = await crawl.settled;
        return settled;
      }, retry: const Retry(1, backoff: Duration(milliseconds: 1)));
      final settled = await crawl;
      expect(tries, {'/a': 2, '/b': 1, '/c': 1});
      expect(
        {for (final s in settled) s.item.path: s.runtimeType.toString().split('<').first},
        {'/': 'Done', '/a': 'Failed', '/b': 'Done', '/c': 'Done'},
      );
    });

    test('ResponseContext.retry drops what the attempt emitted, and gives up past the policy', () async {
      var n = 0;
      final site = _Site({});
      site.other = (r) =>
          Response(n++ == 0 ? 'please wait' : '<h2>real</h2>', 200, headers: {'content-type': 'text/html'});
      final items = await site.scope(
        () => _home
            .crawl<String>(
              onResponse: (ctx) {
                ctx.emit('attempt ${ctx.attempt}');
                if (ctx.response.text.contains('wait')) ctx.retry();
              },
            )
            .items
            .toList(),
      );
      expect(items, ['attempt 2']);
      final always = _Site({});
      always.other = (r) => Response('please wait', 200);
      await always.scope(() async {
        await expectLater(
          _home.crawl<String>(onResponse: (ctx) => ctx.retry()),
          throwsA(isA<BatchException<Uri, List<String>>>()),
        );
      });
    });

    test('onInit adds seeds before anything is sent, a follow of its own reading them', () async {
      final site = _Site({'/': '<h2>home</h2>', '/api': '<h2>api</h2>'});
      final items = await site.scope(
        () => _home
            .crawl<String>(
              onInit: (ctx) => ctx.follow(_home / 'api', onResponse: (r) => r.emit('own ${r.html.$('h2').first.text}')),
              onResponse: (ctx) => ctx.emit(ctx.html.$('h2').first.text),
            )
            .items
            .toList(),
      );
      expect(items..sort(), ['home', 'own api']);
    });

    test('a context defers a cleanup to when its page ends, and steps on its row', () async {
      final ended = <String>[];
      final site = _Site({'/': ''});
      await site.scope(() async {
        final crawl = _home.crawl<String>(
          onResponse: (ctx) {
            ctx.step('parsing');
            ctx.defer(() => ended.add('${ctx.ended.runtimeType}'.split('<').first));
          },
        );
        final steps = crawl.statuses
            .map(
              (s) => switch (s) {
                Running(:final step) => step,
                _ => null,
              },
            )
            .toList();
        await crawl;
        expect(await steps, contains('parsing'));
      });
      expect(ended, ['Done']);
    });

    test('send(form.submission) sends the form as a browser would', () async {
      final site = _Site({'/': '<form action="/search" method="post"><input name="q" value="dart"></form>'});
      site.other = (r) => Response('<h2>${r.method} ${r.text}</h2>', 200, headers: {'content-type': 'text/html'});
      final items = await site.scope(
        () => _home
            .crawl<String>(
              onResponse: (ctx) {
                if (ctx.url.path == '/') {
                  ctx.send(ctx.html.$('form').first.submission);
                } else {
                  _read(ctx);
                }
              },
            )
            .items
            .toList(),
      );
      expect(items, ['POST q=dart']);
    });
  });

  group('the class form', () {
    test('a subclass keeps its state in fields; run(seeds) is a crawl of its own each time', () async {
      final site = _Site({
        '/': '<h2>one</h2><a class="next" href="/2">n</a>',
        '/2': '<h2>two</h2><h2>one</h2><a class="next" href="/3">n</a>',
      });
      final books = _Books();
      await site.scope(() async {
        expect(await books.run([_home]).items.toList(), ['one', 'two']);
        expect(books.failed, 1);
        expect(await books.run([_home]).items.toList(), isEmpty, reason: 'its titles field remembers');
      });
    });
  });

  group('robots.txt', () {
    test('obeyed for the agent each request sends; a forbidden page is Skipped(page, robots)', () async {
      final site = _Site({
        '/robots.txt': 'User-agent: *\nDisallow: /private\n\nUser-agent: mybot\nDisallow: /mine\n',
        '/': '<a href="/private">p</a><a href="/mine">m</a><a href="/open">o</a>',
        '/private': '',
        '/mine': '',
        '/open': '',
      });
      await site.scope(() async {
        final crawl = _home.crawl<String>(
          robots: true,
          onRequest: (ctx) {
            if (ctx.url.path == '/mine') ctx.headers['user-agent'] = 'MyBot/1.0';
          },
          onResponse: _read,
        );
        final skipped = (await crawl.settled).whereType<Skipped<Uri, List<String>>>();
        expect(skipped.map((s) => '${s.item.path} ${s.reason}'), ['/private robots', '/mine robots']);
      });
      expect(site.paths.where((p) => p == '/robots.txt'), hasLength(1), reason: 'read once for the origin');
      expect(site.paths, isNot(contains('/private')));
    });

    test('off by default, every link is fetched', () async {
      final site = _Site({'/robots.txt': 'User-agent: *\nDisallow: /\n', '/': '<a href="/a">a</a>', '/a': ''});
      await site.scope(() => _home.crawl<String>(onResponse: _read));
      expect(site.paths, ['/', '/a']);
    });
  });

  group('sitemaps', () {
    test('robots.txt names the sitemap, whose pages seed the crawl', () async {
      final site = _Site({
        '/robots.txt': 'Sitemap: https://site.test/map.xml',
        '/map.xml':
            '<urlset><url><loc>https://site.test/a?x=1&amp;y=2</loc></url><url><loc>https://other.test/b</loc></url></urlset>',
        '/': '',
        '/a': '<h2>from the map</h2>',
      });
      final items = await site.scope(() => _home.crawl<String>(sitemaps: true, onResponse: _read).items.toList());
      expect(items, ['from the map']);
      expect(site.asked.map((r) => '${r.url}'), contains('https://site.test/a?x=1&y=2'));
    });
  });

  group('limits', () {
    test('8 pages in flight in all, 4 to one host; Http.scope(perHost:) sets the host limit', () async {
      Future<(int, int)> crawl({int? perHost}) async {
        var open = 0, most = 0;
        final perHostOpen = <String, int>{};
        var mostOneHost = 0;
        final fake = Client.fake((r) async {
          most = ++open > most ? open : most;
          final h = perHostOpen[r.url.host] = (perHostOpen[r.url.host] ?? 0) + 1;
          if (h > mostOneHost) mostOneHost = h;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          open--;
          perHostOpen[r.url.host] = perHostOpen[r.url.host]! - 1;
          final links = r.url.path == '/' ? [for (var i = 0; i < 10; i++) '<a href="/$i">$i</a>'].join() : '';
          return Response(links, 200, headers: {'content-type': 'text/html'});
        });
        await Http.scope(client: fake, perHost: perHost, () {
          return [
            for (final h in ['a', 'b', 'c']) Uri.parse('https://$h.test/'),
          ].parallelize((seed) => seed.crawl<String>(onResponse: _read), concurrency: 3);
        });
        return (most, mostOneHost);
      }

      final (_, oneHost) = await crawl();
      expect(oneHost, 4);
      final (_, limited) = await crawl(perHost: 2);
      expect(limited, 2);
    });
  });

  group('store', () {
    test('a cancelled crawl resumes from its store; a finished one clears it', () async {
      final site = _Site({for (var i = 0; i < 6; i++) '/${i == 0 ? '' : i}': '<h2>$i</h2><a href="/${i + 1}">n</a>'});
      site.pages['/6'] = '<h2>6</h2>';
      final store = Store(tempDir());
      await site.scope(() async {
        final first = _home.crawl<String>(
          store: store,
          concurrency: 1,
          onResponse: (ctx) {
            _read(ctx);
            if (ctx.url.path == '/2') Cancel.check();
          },
        );
        await first.statuses.firstWhere((s) => s.item.path == '/2' && s is Done);
        first.cancel('stop here');
        await first.settled;
        expect(File('${store.folder}/crawl.jsonl').existsSync(), isTrue);
        final before = site.asked.length;
        final second = _home.crawl<String>(store: store, onResponse: _read);
        expect(await second.items.toList(), isNot(contains('0')), reason: 'the seed was done in the first run');
        expect(site.paths.skip(before), isNot(contains('/')));
        expect(File('${store.folder}/crawl.jsonl').existsSync(), isFalse, reason: 'finished: cleared');
      });
    });

    test('under a store, meta must be JSON-ready and a follow cannot carry hooks', () async {
      final site = _Site({'/': '<a href="/a">a</a>'});
      await site.scope(() async {
        await expectLater(
          _home.crawl<String>(
            store: Store.memory(),
            onResponse: (ctx) => ctx.follow(_home / 'a', meta: {'x': Object()}),
          ),
          throwsArgumentError,
        );
        await expectLater(
          _home.crawl<String>(
            store: Store.memory(),
            onResponse: (ctx) => ctx.follow(_home / 'a', onResponse: (_) {}),
          ),
          throwsArgumentError,
        );
      });
    });
  });

  group('over real sockets', () {
    test('a crawl under a scope\'s delay spaces its requests to a host', () async {
      final times = <DateTime>[];
      final (_, base) = await serve((r) {
        times.add(DateTime.now());
        r.response.headers.contentType = ContentType.html;
        if (r.uri.path == '/') r.response.write('<a href="/a">a</a><a href="/b">b</a>');
      });
      await Http.scope(delay: 60.ms, () => base.crawl<String>(onResponse: _read));
      expect(times, hasLength(3));
      // Starts are booked at least 45 ms apart (60 ms ± 25 %); one arrival a busy machine delays
      // can shorten one gap, never the span of two.
      expect(times.last.difference(times.first), greaterThan(const Duration(milliseconds: 70)));
    });
  });
}
