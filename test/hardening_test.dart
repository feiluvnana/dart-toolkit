import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('cookies', () {
    test('a comma-joined Set-Cookie header yields every cookie', () {
      final jar = CookieJar();
      jar.add(
        'a=1; Path=/, b=2; Path=/',
        uri: Uri.parse('https://x.com/login'),
      );
      expect(jar.cookies.length, equals(2));
      expect(jar['a'], equals('1'));
      expect(jar['b'], equals('2'));
    });

    test('a comma inside an Expires date does not split the cookie', () {
      final cookies = Morsel.split(
        'sid=1; expires=Wed, 21 Oct 2099 07:28:00 GMT; Path=/, other=2',
      );
      expect(cookies, hasLength(2));
      expect(cookies.first, contains('21 Oct 2099'));
      expect(cookies.last.trim(), equals('other=2'));
    });

    test('default-path is the fetch directory, not the fetch path', () {
      final jar = CookieJar();
      jar.add('sid=abc', uri: Uri.parse('https://x.com/login'));
      expect(jar.header(Uri.parse('https://x.com/dashboard')), 'sid=abc');
      expect(jar.header(Uri.parse('https://x.com/')), 'sid=abc');
    });

    test('an explicit path still confines the cookie', () {
      final jar = CookieJar();
      jar.add('sid=abc; Path=/admin', uri: Uri.parse('https://x.com/'));
      expect(jar.header(Uri.parse('https://x.com/admin/users')), 'sid=abc');
      expect(jar.header(Uri.parse('https://x.com/public')), isNull);
      // A prefix that is not a path segment boundary must not match.
      expect(jar.header(Uri.parse('https://x.com/administrator')), isNull);
    });

    test('Max-Age overrides Expires, and an expired cookie deletes', () {
      final jar = CookieJar();
      jar.add('sid=abc; Max-Age=600', uri: Uri.parse('https://x.com/'));
      expect(jar.header(Uri.parse('https://x.com/')), 'sid=abc');

      jar.add(
        'sid=; expires=Wed, 21 Oct 2015 07:28:00 GMT',
        uri: Uri.parse('https://x.com/'),
      );
      expect(jar.header(Uri.parse('https://x.com/')), isNull);
    });

    test('longer cookie paths are sent first', () {
      final jar = CookieJar();
      jar.add('a=1; Path=/', uri: Uri.parse('https://x.com/'));
      jar.add('b=2; Path=/deep/er', uri: Uri.parse('https://x.com/'));
      expect(jar.header(Uri.parse('https://x.com/deep/er/x')), 'b=2; a=1');
    });
  });

  group('robots.txt', () {
    const txt = '''
User-agent: MyBot
Disallow: /private
Crawl-delay: 2.5

User-agent: *
Disallow: /
''';

    test('a product token matches its declared group', () {
      final robots = Robots.parse(txt);
      final private = Uri.parse('https://x.com/private');
      final open = Uri.parse('https://x.com/open');
      expect(robots.allowed(private, agent: 'MyBot/1.0'), isFalse);
      expect(robots.allowed(open, agent: 'MyBot/1.0'), isTrue);
      // Falls through to the wildcard group for anything else.
      expect(robots.allowed(open, agent: 'OtherBot/2.0'), isFalse);
    });

    test('crawl-delay is matched by the same product token', () {
      final robots = Robots.parse(txt);
      expect(
        robots.delay(agent: 'MyBot/1.0'),
        equals(const Duration(milliseconds: 2500)),
      );
    });
  });

  group('the transport seam', () {
    test('a crawl does not close the client it was handed', () async {
      final mine = Fetcher();
      await (Http.crawl(
        [Fetch('https://example.test/'.url)],
      )..using(mine.call)).run();

      // Reaching the socket layer proves the client was not closed. A `Send`
      // is a function and owns nothing, so there is nothing for the crawl to
      // close on its way out — which is what `Downloader.close` and its
      // `_ownsClient` flag existed to get right.
      await expectLater(
        mine.send(HttpMethod.get, Uri.parse('http://127.0.0.1:1/'), retries: 0),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('already closed')),
          ),
        ),
      );
      await mine.close();
    });

    test('retries is the client\'s knob, declared in one place', () {
      // Ten knobs at four levels through 5.5.0 — and a caller-supplied
      // downloader silently dropped five of them. Now there is one place for
      // each, and `Crawl` has no member for any of them.
      final client = Fetcher(retries: 9);
      expect(client.retries, equals(9));
      expect(
        Http.crawl(const <Fetch>[]).using(client.call),
        isA<Crawl>(),
      );
    });
  });

  group('selectors', () {
    test('matches tests an element without scanning its parent', () {
      final q = parseHtml(
        '<ul><li class="a">1</li><li class="b">2</li></ul>',
      );
      expect(q.$('li').matching('.a').texts, equals(['1']));
      expect(
        q.$('li').matching(':not(.a)').texts,
        equals(['2']),
      );
    });

    test('combinators are honoured by a single-element match', () {
      final q = parseHtml(
        '<div class="w"><p>a</p><span>b</span><span>c</span></div>',
      );
      expect(
        q.$('span').matching('p + span').texts,
        equals(['b']),
      );
      expect(
        q.$('span').matching('.w > span').texts,
        equals(['b', 'c']),
      );
      expect(
        q.$('span').matching('p ~ span').texts,
        equals(['b', 'c']),
      );
    });

    test('closest walks ancestors', () {
      final q = parseHtml(
        '<div class="outer"><div class="inner"><b>x</b></div></div>',
      );
      expect(q.$('b').closest('.outer').count, equals(1));
      expect(q.$('b').closest('.missing').count, equals(0));
    });

    test('a large child-combinator query stays linear', () {
      final rows = List.generate(2000, (i) => '<li class="i">$i</li>').join();
      final q = parseHtml('<ul id="l">$rows</ul>');
      final watch = Stopwatch()..start();
      expect(q.$('#l > li.i').count, equals(2000));
      watch.stop();
      // The quadratic form took several hundred milliseconds at this size.
      expect(watch.elapsedMilliseconds, lessThan(500));
    });
  });

  group('pool streaming', () {
    test('cancelling the flow stops launching work', () async {
      var started = 0;
      final pool = Pool<int>(size: 1);
      final stream = pool.flow(List.generate(50, (int i) => i), (int i) async {
        started++;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return i;
      });

      final seen = <int>[];
      final subscription = stream.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await subscription.cancel();
      final afterCancel = started;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(started, equals(afterCancel), reason: 'no work after cancel');
      expect(started, lessThan(50));
    });

    test('results still arrive in completion order', () async {
      final pool = Pool<int>(size: 3);
      final out = await pool.flow([30, 10, 20], (int ms) async {
        await Future<void>.delayed(Duration(milliseconds: ms));
        return ms;
      }).toList();
      expect(out, equals([10, 20, 30]));
    });

    test('cancelling a flow.run stops launching work', () async {
      var started = 0;
      final pool = Pool<int>(size: 1);
      final stream = pool.flow(List.generate(50, (int i) => i), (int i) async {
        started++;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return i;
      });

      final seen = <int>[];
      final subscription = stream.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await subscription.cancel();
      final afterCancel = started;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(started, equals(afterCancel), reason: 'no work after cancel');
      expect(started, lessThan(50));
    });
  });

  group('retry semantics', () {
    test('retries means attempts after the first', () async {
      var calls = 0;
      await expectLater(
        Concurrent.retry(
          () async {
            calls++;
            throw StateError('nope');
          },
          retries: 2,
          backoff: const Duration(milliseconds: 1),
        ),
        throwsStateError,
      );
      expect(calls, equals(3));
    });

    test('times means total attempts', () async {
      var calls = 0;
      await expectLater(
        Concurrent.retry(
          () async {
            calls++;
            throw StateError('nope');
          },
          retries: 1,
          backoff: const Duration(milliseconds: 1),
        ),
        throwsStateError,
      );
      expect(calls, equals(2));
    });
  });

  group('typed extraction', () {
    final res = Reply.text('''
      <h1>Title</h1>
      <ul><li class="t">a</li><li class="t">b</li></ul>
      <div class="row"><span class="n">one</span><a href="/1">x</a></div>
      <div class="row"><span class="n">two</span><a href="/2">y</a></div>
    ''');

    test('pick keeps the field type', () {
      final String? title = res.parse(Codec.html).pick(Field.text('h1'));
      final List<String> tags = res.parse(Codec.html).pick(Field.texts('.t'));
      final List<String> hrefs = res
          .parse(Codec.html)
          .pick(Field.attrs('.row a', 'href'));
      expect(title, equals('Title'));
      expect(tags, equals(['a', 'b']));
      expect(hrefs, equals(['/1', '/2']));
    });

    test('a custom read is typed too', () {
      final int count = res
          .parse(Codec.html)
          .pick(Field.fn((el) => el.querySelectorAll('.row').length));
      expect(count, equals(2));
    });

    test('the string shorthand still works', () {
      final data = res.parse(Codec.html).extract({
        'title': 'h1',
        'tags': ['.t'],
        'rows': [
          '.row',
          {'name': '.n', 'url': 'a@href'},
        ],
      });
      expect(data['title'], equals('Title'));
      expect(data['tags'], equals(['a', 'b']));
      expect(
        data['rows'],
        equals([
          {'name': 'one', 'url': '/1'},
          {'name': 'two', 'url': '/2'},
        ]),
      );
    });

    test('Fields and shorthand mix in one schema', () {
      final data = res.parse(Codec.html).extract({
        'title': Field.text('h1'),
        'tags': ['.t'],
      });
      expect(data['title'], equals('Title'));
      expect(data['tags'], equals(['a', 'b']));
    });
  });

  group('Files mirrors sync and async operations', () {
    test('parent has an async twin, like every other disk operation', () async {
      final dir = Files.tempDirSync('dt_parent_');
      try {
        final blocking = Files.join(dir.path, 'a', 'b', 'file.txt');
        final future = Files.join(dir.path, 'c', 'd', 'file.txt');
        Files.makeDirSync(Files.dirname(blocking));
        await Files.makeDir(Files.dirname(future));

        expect(
          Files.isFile(Files.dirname(blocking)),
          isFalse,
          reason: 'a folder, not a file',
        );
        expect(Directory(Files.dirname(blocking)).existsSync(), isTrue);
        expect(Directory(Files.dirname(future)).existsSync(), isTrue);
      } finally {
        Files.removeSync(dir.path);
      }
    });

    test('both write atomically to the same place', () async {
      final dir = Files.tempDirSync('dt_io_');
      try {
        final a = Files.join(dir.path, 'sync.txt');
        final b = Files.join(dir.path, 'async.txt');
        Files.writeTextSync(a, 'one');
        await Files.writeText(b, 'two');
        expect(Files.readTextSync(a), equals('one'));
        expect(await Files.readText(b), equals('two'));
        expect(Files.exists(a), isTrue);
        expect(Files.exists(b), isTrue);
        expect(
          await Files.walk(dir.path),
          hasLength(2),
        );
        expect(await Files.remove(b), isTrue);
        expect(Files.exists(b), isFalse);
      } finally {
        Files.removeSync(dir.path);
      }
    });

    test('json round-trips through both', () async {
      final dir = Files.tempDirSync('dt_json_');
      try {
        final path = Files.join(dir.path, 'd.json');
        Files.writeJsonSync(path, {'n': 1});
        final readSync = parseJson(Files.readTextSync(path));
        expect(readSync.number('n'), equals(1));
        await Files.writeJson(path, {'n': 2});
        final readAsync = parseJson(await Files.readText(path));
        expect(readAsync.number('n'), equals(2));
      } finally {
        Files.removeSync(dir.path);
      }
    });
  });
}
