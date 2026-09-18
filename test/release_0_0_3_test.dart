import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:dart_toolkit/testing.dart';
import 'package:test/test.dart';

/// Every test here reproduced a defect in 0.0.2 before the fix landed.
void main() {
  group('scrape', () {
    test('a hook that calls stop() and then throws still closes the stream', () async {
      final client = MockClient((r) async => Response('ok', 200));
      final items = await Http.session(
        () => 'https://a.com/x'.url.scrape<int>().onResponse((ctx) {
          ctx.stop();
          throw StateError('boom');
        }).toList(),
        client: client,
      ).timeout(const Duration(seconds: 3));
      expect(items, hasLength(1));
      expect(items.single.leftOrNull, isA<HookFailed>());
    });

    test('follow returns false for a URL already followed, and the drop is counted', () async {
      final client = MockClient((r) async => Response('<a href="/song/1">s</a>', 200));
      final results = <bool>[];
      ScrapeSummary? summary;
      final out = await Http.session(
        () => 'https://a.com/list'.url
            .scrape<String>()
            .onResponse((ctx) {
              if (ctx.depth > 0) return;
              for (final ext in ['mp3', 'flac']) {
                results.add(ctx.follow('/song/1', onResponse: (song) => song.emit(ext)));
              }
            })
            .onFinish((s) => summary = s)
            .rights
            .toList(),
        client: client,
      );
      expect(results, [true, false]);
      expect(out, ['mp3']);
      expect(summary!.dropped, 1);
    });

    test('fragments are not part of a page identity', () async {
      final hits = <String>[];
      final client = MockClient((r) async {
        hits.add(r.url.toString());
        return Response(
          r.url.path == '/' ? '<a href="/p#a">a</a><a href="/p#b">b</a><a href="/p">c</a>' : 'x',
          200,
        );
      });
      await Http.session(
        () => 'https://a.com/#top'.url.scrape<int>().onResponse((ctx) {
          for (final a in ctx.response.html.$('a')) {
            ctx.follow(a.attr('href')!);
          }
        }).toList(),
        client: client,
      );
      expect(hits, ['https://a.com/', 'https://a.com/p']);
    });

    test('the default scope treats www. and the apex as one site', () async {
      final hits = <String>[];
      final client = MockClient((r) async {
        hits.add(r.url.host);
        return Response(
          r.url.host == 'a.com' ? '<a href="https://www.a.com/q">w</a><a href="https://b.com/">b</a>' : '',
          200,
        );
      });
      await Http.session(
        () => 'https://a.com/'.url.scrape<int>().onResponse((ctx) {
          for (final a in ctx.response.html.$('a')) {
            ctx.follow(a.attr('href')!);
          }
        }).toList(),
        client: client,
      );
      expect(hits, ['a.com', 'www.a.com']);
    });

    test('credentials do not follow a redirect to another host', () async {
      final seen = <String, String?>{};
      final client = MockClient((r) async {
        seen[r.url.host] = r.headers['authorization'];
        if (r.url.host == 'a.com') return Response('', 302, headers: {'location': 'https://cdn.example/'});
        return Response('ok', 200);
      });
      await Http.session(
        () => 'https://a.com/'.url
            .scrape<int>()
            .onRequest((ctx) {
              if (ctx.url.host == 'a.com') ctx.request.headers['authorization'] = 'Bearer SECRET';
            })
            .onResponse((ctx) {})
            .toList(),
        client: client,
      );
      expect(seen['a.com'], 'Bearer SECRET');
      expect(seen['cdn.example'], isNull);
    });

    test('Retry-After as an HTTP date in the past means no wait', () async {
      var n = 0;
      final client = MockClient((r) async {
        n++;
        if (n == 1) return Response('', 503, headers: {'retry-after': 'Wed, 21 Oct 2015 07:28:00 GMT'});
        return Response('ok', 200);
      });
      final sw = Stopwatch()..start();
      final out = await Http.session(
        () => 'https://a.com/'.url.scrape<int>().onResponse((c) => c.emit(1)).rights.toList(),
        client: client,
      );
      expect(out, [1]);
      expect(sw.elapsedMilliseconds, lessThan(400));
    });

    test('a second 429 never shortens a longer pause', () async {
      var n = 0;
      final sent = <int>[];
      final sw = Stopwatch()..start();
      final client = MockClient((r) async {
        sent.add(sw.elapsedMilliseconds);
        n++;
        if (n <= 2) return Response('', 429, headers: {'retry-after': n == 1 ? '1' : '0'});
        return Response('ok', 200);
      });
      await Http.session(
        () => ['https://a.com/1'.url, 'https://a.com/2'.url].scrape<int>().onResponse((c) => c.emit(1)).toList(),
        client: client,
      );
      // The third and fourth sends waited for the 1 s pause, not the 0 s one that arrived later.
      expect(sent.skip(2).every((t) => t >= 900), isTrue, reason: '$sent');
    });
  });

  group('download', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('dl_'));
    tearDown(() => dir.deleteSync(recursive: true));

    Client slowClient() => MockClient.streaming((req, body) async {
      Stream<List<int>> chunks() async* {
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          yield List.filled(100, 65);
        }
      }

      return StreamedResponse(chunks(), 200, contentLength: 2000);
    });

    test('a consumer that stops listening leaves no .part file behind', () async {
      final target = Path(dir.path) / 'f.bin';
      await Http.session(() async {
        var events = 0;
        await for (final _ in {'https://a.com/f'.url: target}.downloadAll()) {
          if (++events == 3) break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }, client: slowClient());
      expect(Path(dir.path).listSync(), isEmpty);
    });

    test('a non-2xx response is drained so the connection is not held', () async {
      var cancelled = false;
      final client = MockClient.streaming((req, body) async {
        final c = StreamController<List<int>>(onCancel: () => cancelled = true, onListen: () {});
        return StreamedResponse(c.stream, 404, contentLength: 10);
      });
      final r = await Http.session(
        () => (Path(dir.path) / 'x').download('https://a.com/x'.url).toList(),
        client: client,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(r.single, isA<DownloadFailed>());
      expect(cancelled, isTrue);
    });
  });

  group('process', () {
    test('a child that echoes a large stdin does not deadlock', () async {
      final big = 'x' * 2000000;
      final r = await run('cat', input: big, quiet: true).timeout(const Duration(seconds: 10));
      expect(r.stdout.length, big.length);
    });

    test('the splitter reads quotes and backslashes as a POSIX shell does', () async {
      expect(await run(r'echo C:\Users\x', quiet: true).text, 'C:Usersx');
      expect(await run(r"echo 'a\b'", quiet: true).text, r'a\b');
      expect(await run(r'echo "\d \$ \" \\"', quiet: true).text, r'\d $ " \');
      expect((await run(r'printf %s ""', quiet: true)).stdout, '');
      expect(await run(r'echo "two words" one', quiet: true).lines, ['two words one']);
    });
  });

  group('cli', () {
    test('an ArgumentError in the action is not a usage error', () async {
      final cli = CliCommand('demo')..action((ctx) => throw ArgumentError('bug in the action'));
      expect(() => cli.run([]), throwsA(isA<ArgumentError>()));
    });

    test('a usage error is a UsageException with the message', () async {
      final cli = CliCommand('demo')..number('n');
      expect(
        () => cli.run(['--n', 'x']),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('Invalid numeric value'))),
      );
    });

    test('ctx.cancel is cancelled when the action ends, and exit hooks run when it throws', () async {
      CancelToken? seen;
      var hookRan = false;
      onExit(() => hookRan = true);
      final cli = Cli(name: 'demo')
        ..action((ctx) {
          seen = ctx.cancel;
          expect(ctx.cancel.isCancelled, isFalse);
          throw StateError('bug');
        });
      await expectLater(cli.run([]), throwsStateError);
      expect(hookRan, isTrue);
      expect(seen!.isCancelled, isTrue);
    });
  });

  group('brevity', () {
    test('merge runs its sources at the same time', () async {
      Stream<String> tick(String tag, int ms) async* {
        for (var i = 0; i < 3; i++) {
          await Future<void>.delayed(Duration(milliseconds: ms));
          yield '$tag$i';
        }
      }

      final out = await [tick('a', 30), tick('b', 20)].merge().toList();
      expect(out, hasLength(6));
      expect(out.first, 'b0');
    });

    test('show() renders a batch and returns its last event', () async {
      final out = StringBuffer();
      ConsoleIo.out = out;
      try {
        final client = MockClient((r) async => Response('data', 200));
        final dir = Directory.systemTemp.createTempSync('show_');
        try {
          final last = await Http.session(
            () => {
              'https://a.com/1'.url: Path(dir.path) / '1',
              'https://a.com/2'.url: Path(dir.path) / '2',
            }.downloadAll().show(slots: 2, message: 'Downloading', done: 'All done'),
            client: client,
          );
          expect(last!.completed, 2);
          expect(out.toString(), contains('All done'));
        } finally {
          dir.deleteSync(recursive: true);
        }
      } finally {
        ConsoleIo.reset();
      }
    });

    test('Elements answers for its first match and queries within every match', () {
      final doc = '<ul><li><a href="/1">one</a></li><li><a href="/2">two</a></li></ul><p>x</p>'.html;
      expect(doc.$('li a').text, 'one');
      expect(doc.$('li a').attr('href'), '/1');
      expect(doc.$('li').$('a').map((a) => a.attr('href')), ['/1', '/2']);
      expect(doc.$('nothing').attr('href'), isNull);
      expect(() => doc.$('nothing').text, throwsStateError);
      expect(doc.$('li').length, 2);
    });

    test('String.match returns the group in one pass', () {
      expect('disc-12-track'.match(RegExp(r'-(\d+)-'), 1), '12');
      expect('disc-12-track'.match(RegExp(r'-(\d+)-'), 2), isNull);
      expect('nothing'.match(RegExp(r'\d+')), isNull);
      expect('a.b'.match('.'), '.');
    });
  });

  group('html parser', () {
    test('tag soup lands where a browser puts it', () {
      final doc = '<p>one<p>two<ul><li>a<li>b</ul><table><tr><td>1<td>2</table>'.html;
      expect(doc.$('p').map((p) => p.text), ['one', 'two']);
      expect(doc.$('ul > li').map((li) => li.text), ['a', 'b']);
      expect(doc.$('table > tbody > tr > td').map((td) => td.text), ['1', '2']);
      expect(doc.body.children.map((e) => e.name), ['p', 'p', 'ul', 'table']);
    });

    test('head and body are synthesised, title is in head, script text is raw', () {
      final doc = '<title>T &amp; U</title><script>if (a < b) {}</script><div>x</div>'.html;
      expect(doc.head.$('title').text, 'T & U');
      expect(doc.head.$('script').text, 'if (a < b) {}');
      expect(doc.body.$('div').text, 'x');
    });

    test('entities: named, decimal, hex, and unterminated', () {
      expect(decodeEntities('&lt;a&gt; &amp; &#65;&#x42; &nbsp;x &unknown; &amp'), '<a> & AB \u00a0x &unknown; &');
    });

    test('attributes: quoted, unquoted, valueless, duplicated, case', () {
      final a = '<A HREF=/x Data-Id="7" disabled title=\'q "t"\' href="/dup">'.html.$('a').first;
      expect(a.attributes, {'href': '/x', 'data-id': '7', 'disabled': '', 'title': 'q "t"'});
    });

    test('selectors: combinators, attribute operators, pseudo-classes, lists', () {
      final doc =
          '''
        <div id="root" class="a b">
          <p class="x">1</p><p>2</p><span>3</span><p lang="en-US">4</p>
          <ul><li>i</li><li>ii</li><li>iii</li></ul>
        </div>'''
              .html;
      String t(String sel) => doc.$(sel).map((e) => e.text).join(',');
      expect(t('#root > p'), '1,2,4');
      expect(t('div p.x'), '1');
      expect(t('p + p'), '2');
      expect(t('p ~ span'), '3');
      expect(t('p ~ p'), '2,4');
      expect(t('[lang|=en]'), '4');
      expect(t('[class~=b] > span'), '3');
      expect(t('li:first-child, li:last-child'), 'i,iii');
      expect(t('li:nth-child(2)'), 'ii');
      expect(t('li:nth-child(odd)'), 'i,iii');
      expect(t('li:not(:first-child)'), 'ii,iii');
      expect(t('div:has(span) > p:first-of-type'), '1');
      expect(t('P.x'), '1'); // type names are case-insensitive, class names are not
      expect(t('p.X'), '');
      expect(() => doc.$('p >'), throwsFormatException);
    });

    test('serialisation round-trips', () {
      const src = '<div class="a"><p>x &amp; y</p><br><img src="i.png"></div>';
      expect(src.html.body.innerHtml, src);
    });
  });
}
