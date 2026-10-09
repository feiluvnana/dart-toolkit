import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/scrape.dart';
import 'package:test/test.dart' hide Retry;

import 'client_conformance.dart';
import 'support.dart';

/// Chrome is not a test dependency: without one, these are skipped rather than failed.
String? _chrome() {
  if (Platform.environment['DART_TOOLKIT_CHROME'] case final path? when path.isNotEmpty) return path;
  final local = Platform.environment['LOCALAPPDATA'];
  for (final candidate in [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/snap/bin/chromium',
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    if (local != null) '$local\\Google\\Chrome\\Application\\chrome.exe',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// The pages the tests render, by path.
Future<void> _route(HttpRequest request) async {
  final response = request.response;
  void html(String body) {
    response.headers.contentType = ContentType.html;
    response.write('<html><body>$body</body></html>');
  }

  switch (request.uri.path) {
    case '/rendered':
      html('''<div id="app"></div><script>
  setTimeout(() => {
    document.getElementById('app').innerHTML = '<ul><li class="item">alpha</li><li class="item">beta</li></ul>';
  }, ${request.uri.queryParameters['after'] ?? 150});
</script>''');
    case '/slow':
      await Future<void>.delayed(Duration(milliseconds: int.parse(request.uri.queryParameters['ms'] ?? '300')));
      html('<p id="slow">slow</p>');
    case '/agent':
      html('<p id="ua">${request.headers.value('user-agent')}</p>');
    case '/form':
      html('''<input id="name"><button id="go">go</button><div id="out"></div><p id="changed"></p>
<script>
  document.getElementById('name').addEventListener('change', (e) => document.getElementById('changed').textContent = 'changed');
  document.getElementById('go').addEventListener('click', () => setTimeout(() => {
    document.getElementById('out').innerHTML = '<p class="greeting">hello ' + document.getElementById('name').value + '</p>';
  }, 100));
</script>''');
    case '/spinner':
      html(
        '<div class="spinner">…</div><script>setTimeout(() => document.querySelector(".spinner").remove(), 200)</script>',
      );
    case '/links':
      html('<a id="next" href="/rendered">next</a>');
    case '/downloads':
      html('<a id="get" href="/blob.bin" download>take it</a>');
    case '/blob.bin':
      response.headers
        ..contentType = ContentType.binary
        ..set('content-disposition', 'attachment; filename="report.bin"');
      response.add(List.filled(1024, 3));
    case '/api-page':
      html('''<button id="more">more</button><div id="out"></div><script>
  document.getElementById('more').addEventListener('click', async () => {
    const res = await fetch('/api/items');
    document.getElementById('out').textContent = (await res.json()).items.length;
  });
</script>''');
    case '/api/items':
      response.headers.contentType = ContentType.json;
      response.write('{"items":[1,2,3]}');
    case '/outer':
      html('<p id="here">outside</p><iframe name="inner" src="/inner"></iframe>');
    case '/inner':
      html('<p id="here">inside</p>');
    case '/challenge':
      response
        ..statusCode = 403
        ..headers.contentType = ContentType.html
        ..write('<html><head><title>Just a moment...</title></head><body>Checking your browser</body></html>');
    case '/never':
      html('<img src="/hang.png">');
    case '/hang.png':
      await Future<void>.delayed(const Duration(seconds: 5));
    default:
      response.statusCode = 404;
      response.write('nothing here');
  }
}

void main() {
  final absent = _chrome() == null ? 'no Chrome installed; set DART_TOOLKIT_CHROME to run these' : null;

  group('settings, with no browser', () {
    test('a bad setting is an ArgumentError before anything starts', () async {
      await expectLater(Chrome.launch(concurrency: 0), throwsArgumentError);
      await expectLater(Chrome.launch(render: const Render(timeout: Duration.zero)), throwsArgumentError);
      await expectLater(Chrome.launch(proxies: [Uri.parse('ftp://x:1')]), throwsArgumentError);
    });

    test('connect with nothing on the port and no start: is a MissingException', () async {
      final socket = await ServerSocket.bind('127.0.0.1', 0);
      final port = socket.port;
      await socket.close();
      await expectLater(
        Chrome.connect(port: port),
        throwsA(isA<MissingException>().having((e) => '$e', 'text', 'Missing Chrome in 127.0.0.1:$port')),
      );
    });

    test('a Chrome that cannot start leaves no scratch folder behind', () async {
      List<String> scratch() => [
        for (final e in Directory.systemTemp.listSync())
          if (e.path.split(Platform.pathSeparator).last.startsWith('dart_toolkit_chrome_')) e.path,
      ];
      final before = scratch().toSet();
      await expectLater(Chrome.launch(executable: '${Directory.systemTemp.path}/tk-no-such-chrome'), throwsA(anything));
      expect(scratch().where((p) => !before.contains(p)), isEmpty);
    });
  });

  group('Chrome', () {
    late Uri base;
    late Chrome chrome;

    setUpAll(() async {
      if (absent != null) return;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((r) async {
        await _route(r);
        await r.response.close().catchError((Object _) {}); // a route that hung up already
      });
      chrome = await Chrome.launch(concurrency: 2);
      addTearDown(() async {
        await chrome.close();
        await server.close(force: true);
      });
    });

    test('renders through the ordinary HTTP API, the DOM the scripts built', () async {
      await Http.scope(client: chrome, () async {
        final request = Request('GET', base.resolve('/rendered'))..[Chrome.render] = const Render(waitFor: '.item');
        final html = await request.send().html;
        expect(html.$('.item').map((e) => e.text), ['alpha', 'beta']);
      });
    }, skip: absent);

    test('a script runs before the DOM is read; a waitFor that never comes is a TimeoutException', () async {
      await Http.scope(client: chrome, retry: Retry.none, () async {
        final scripted = Request('GET', base.resolve('/links'))
          ..[Chrome.render] = const Render(script: 'document.body.dataset.done = "yes"');
        expect((await scripted.send().html).$('body').first.attr('data-done'), 'yes');
        final never = Request('GET', base.resolve('/links'))
          ..[Chrome.render] = const Render(waitFor: '#absent', timeout: Duration(milliseconds: 300));
        await expectLater(never.send(), throwsA(isA<TimeoutException>()));
      });
    }, skip: absent);

    test("the scope's timeout starts once a tab is had, never covering the queue for one", () async {
      // The regression: a crawl over Chrome timed out pages that waited for a tab.
      await Http.scope(client: chrome, timeout: 700.ms, retry: Retry.none, () async {
        final pages = [for (var i = 0; i < 4; i++) base.replace(path: '/slow', query: 'ms=400&n=$i')];
        final all = await pages.parallelize((u) => u.get(), concurrency: 4);
        expect(all, hasLength(4), reason: 'two tabs, four pages of 400 ms: the last waited ~800 ms for its tab');
      });
    }, skip: absent);

    test("the request's user-agent is the one the site sees", () async {
      await Http.scope(client: chrome, headers: {'user-agent': 'polite-bot/1'}, () async {
        expect((await base.resolve('/agent').get().html).$('#ua').first.text, 'polite-bot/1');
      });
      final own = await Http.scope(
        client: chrome,
        () async => (await base.resolve('/agent').get().html).$('#ua').first.text,
      );
      expect(own, contains('Chrome'), reason: 'without one, the browser\'s own again');
    }, skip: absent);

    test('a download through it writes the file, not a rendering of it', () async {
      final dir = tempDir();
      await Http.scope(client: chrome, () => base.resolve('/blob.bin').download(into: dir));
      expect(File('$dir/report.bin').lengthSync(), 1024);
    }, skip: absent);

    test('an interstitial that never clears is the answer, its status kept', () async {
      await Http.scope(client: chrome, retry: Retry.none, () async {
        final request = Request('GET', base.resolve('/challenge'))
          ..[Chrome.render] = const Render(challenge: Duration(milliseconds: 600));
        final status = await request.send().settled;
        expect(status, isA<Failed<Object?, Response>>().having((f) => f.error, 'error', isA<StatusException>()));
      });
    }, skip: absent);

    test('a page is driven: fill fires change, click, wait, then the DOM', () async {
      final page = await chrome.open(base.resolve('/form'));
      addTearDown(page.close);
      await page.fill('#name', 'world');
      await page.click('#go');
      await page.wait('.greeting');
      final html = await page.html;
      expect(html.$('.greeting').first.text, 'hello world');
      expect(html.$('#changed').first.text, 'changed');
      await expectLater(page.click('#absent'), throwsA(isA<MissingException>()));
      await expectLater(page.wait('#absent', timeout: 200.ms), throwsA(isA<TimeoutException>()));
    }, skip: absent);

    test('waitGone waits out a spinner', () async {
      final page = await chrome.open(base.resolve('/spinner'));
      addTearDown(page.close);
      await page.waitGone('.spinner');
      expect((await page.html).$('.spinner'), isEmpty);
    }, skip: absent);

    test('expectNavigation waits out a click that leaves; back returns, and with no history is Missing', () async {
      final page = await chrome.open(base.resolve('/links'));
      addTearDown(page.close);
      await page.expectNavigation(() => page.click('#next'));
      expect(page.url.path, '/rendered');
      await page.back();
      expect(page.url.path, '/links');
      await page.forward();
      expect(page.url.path, '/rendered');
      await expectLater(page.forward(), throwsA(isA<MissingException>()));
    }, skip: absent);

    test('goto is a wait too: a page that never loads is a TimeoutException', () async {
      final page = await chrome.open(null);
      addTearDown(page.close);
      await expectLater(
        page.goto(base.resolve('/never'), render: const Render(timeout: Duration(milliseconds: 300))),
        throwsA(isA<TimeoutException>()),
      );
    }, skip: absent);

    test("a page's waits end at a cancel of their work, not at their timeout", () async {
      final page = await chrome.open(null);
      addTearDown(page.close);
      await expectLater(
        Cancel.scope(timeout: const Duration(milliseconds: 300), () => page.goto(base.resolve('/never'))),
        throwsA(isA<CancelledException>()),
      );
      await expectLater(
        Cancel.scope(timeout: const Duration(milliseconds: 300), () => page.wait('.never')),
        throwsA(isA<CancelledException>()),
      );
      expect(page.isClosed, isFalse, reason: 'the tab is still there to use');
      expect(await page.eval<int>('1 + 1'), 2);
    }, skip: absent);

    test('expectDownload into a folder is a Task of the file; a rerun is Done(fresh: false)', () async {
      final dir = tempDir();
      final page = await chrome.open(base.resolve('/downloads'));
      addTearDown(page.close);
      final file = await page.expectDownload(() => page.click('#get'), into: dir);
      expect(file, '$dir/report.bin');
      expect(File(file).lengthSync(), 1024);
      final again = await page.expectDownload(() => page.click('#get'), into: dir).settled;
      expect(again, isA<Done<Object?, Path>>().having((d) => d.fresh, 'fresh', isFalse));
    }, skip: absent);

    test('expectResponse answers the JSON behind the page', () async {
      final page = await chrome.open(base.resolve('/api-page'));
      addTearDown(page.close);
      final res = await page.expectResponse('/api/items', () => page.click('#more'));
      expect(res.json['items'].list, hasLength(3));
    }, skip: absent);

    test('eval is the type asked for, a Doc to read JSON in; a script that throws is a ChromeException', () async {
      final page = await chrome.open(base.resolve('/links'));
      addTearDown(page.close);
      expect((await page.eval<Doc>('({a: [1, 2]})'))['a'].list, hasLength(2));
      expect(await page.eval<String>('document.querySelector("#next").id'), 'next');
      expect(await page.eval<int>('"41"') + 1, 42, reason: 'read as Doc.to reads it');
      await expectLater(page.eval<Object?>('null.x'), throwsA(isA<ChromeException>()));
    }, skip: absent);

    test('screenshot of the window, of one element, of the whole page; a missing element is Missing', () async {
      final page = await chrome.open(base.resolve('/form'));
      addTearDown(page.close);
      final png = [0x89, 0x50, 0x4e, 0x47];
      expect((await page.screenshot()).take(4), png);
      expect((await page.screenshot(of: '#go')).take(4), png);
      expect((await page.screenshotPage()).take(4), png);
      await expectLater(page.screenshot(of: '#absent'), throwsA(isA<MissingException>()));
    }, skip: absent);

    test('pdf reads the whole document, a chunk at a time', () async {
      final page = await chrome.open(base.resolve('/form'));
      addTearDown(page.close);
      final pdf = await page.pdf();
      expect(pdf.take(5), '%PDF-'.codeUnits);
      expect(
        String.fromCharCodes(pdf.skip(pdf.length - 8)),
        contains('%%EOF'),
        reason: 'every chunk, the last one too',
      );
    }, skip: absent);

    test('a frame is a page; one that is not there is a MissingException', () async {
      final page = await chrome.open(base.resolve('/outer'));
      addTearDown(page.close);
      final inner = await page.frame('inner');
      expect((await inner.html).$('#here').first.text, 'inside');
      await expectLater(page.frame('absent'), throwsA(isA<MissingException>()));
    }, skip: absent);

    test('cookies are the browser\'s, and setCookies puts a session back', () async {
      await chrome.setCookies(CookieJar([HttpCookie('sid', 'a,b', domain: '127.0.0.1')]));
      final jar = await chrome.cookies();
      expect(jar.where((c) => c.name == 'sid').single.value, 'a,b');
    }, skip: absent);

    test('a crawl over it reads what the scripts built', () async {
      final items = await Http.scope(client: chrome, () {
        return base
            .resolve('/rendered')
            .crawl<String>(
              onRequest: (ctx) => ctx[Chrome.render] = const Render(waitFor: '.item'),
              onResponse: (ctx) => ctx.html.$('.item').forEach((e) => ctx.emit(e.text)),
            )
            .items
            .toList();
      });
      expect(items, ['alpha', 'beta']);
    }, skip: absent);

    test('a cancel while Chrome starts stops it and erases its folder', () async {
      List<String> scratch() => [
        for (final e in Directory.systemTemp.listSync())
          if (e.path.split(Platform.pathSeparator).last.startsWith('dart_toolkit_chrome_')) e.path,
      ];
      final before = scratch().toSet();
      await expectLater(
        Cancel.scope(timeout: const Duration(milliseconds: 50), () => Chrome.launch()),
        throwsA(isA<CancelledException>()),
      );
      expect(scratch().where((p) => !before.contains(p)), isEmpty);
    }, skip: absent);

    test('a closed client fails at once, saying the browser is gone', () async {
      final own = await Chrome.launch();
      final page = await own.open(null);
      await own.close();
      await expectLater(
        page.click('#x'),
        throwsA(isA<ChromeException>().having((e) => e.detached, 'detached', isTrue)),
      );
    }, skip: absent);
  });

  if (absent == null) {
    clientConformance('Chrome', (_) => Chrome.launch(), skip: {'methods', 'stream', 'status'});
  }
}
