import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

import 'client_conformance.dart';
import 'mock_client.dart';

/// Chrome is not a test dependency: without one, this file is skipped rather than failed.
String? _chrome() {
  if (Platform.environment['CHROME_PATH'] case final path? when path.isNotEmpty) return path;
  const candidates = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// The launched Chromes whose command line carries [marker], as pid and command line — the
/// browser itself, not its helpers and not the shell it runs under.
Future<List<(int, String)>> _browsers(String marker) async {
  final ps = await Process.run('ps', ['-Ao', 'pid=,command=']);
  return [
    for (final line in LineSplitter.split('${ps.stdout}'))
      if (line.trim() case final row when row.contains(marker) && !row.contains('--type=') && !row.contains('/bin/sh'))
        (int.parse(row.split(' ').first), row),
  ];
}

/// Waits up to [within] for [condition], polling; answers whether it came true.
Future<bool> _eventually(FutureOr<bool> Function() condition, {Duration within = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return condition();
}

void main() {
  final chrome = _chrome();
  final absent = chrome == null ? 'no Chrome installed; set CHROME_PATH to run these' : null;

  group('ChromeClient', () {
    late HttpServer server;
    late Uri base;
    late ChromeClient browser;
    var challenged = 0;
    final hits = <String, int>{};
    String? ownPixel;
    // What the working directory held before any test here ran; see the last test.
    final before = Directory.current.listSync().map((e) => e.path).toSet();

    setUpAll(() async {
      if (chrome == null) return;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://${server.address.host}:${server.port}');
      unawaited(
        server.forEach((request) async {
          final response = request.response;
          hits.update(request.uri.path, (n) => n + 1, ifAbsent: () => 1);
          switch (request.uri.path) {
            // Everything a blocked crawl should never ask for, on one page.
            case '/heavy':
              response.headers.contentType = ContentType.html;
              response.write('''
<html><head><link rel="stylesheet" href="/style.css"></head>
<body><h1 id="title">heavy</h1><img id="pic" src="/pixel.png"></body></html>''');
            case '/style.css':
              response.headers.contentType = ContentType('text', 'css');
              response.write('h1 { color: red }');
            case '/pixel.png':
              response.headers.contentType = ContentType('image', 'png');
              response.add(List.filled(64, 0));
            // A link that downloads rather than navigates.
            case '/downloads':
              response.headers.contentType = ContentType.html;
              response.write('<html><body><a id="get" href="/blob.bin" download>take it</a></body></html>');
            // A file that arrives steadily but takes far longer than any one wait would allow.
            case '/slow.bin':
              response.headers
                ..contentType = ContentType.binary
                ..set('content-disposition', 'attachment; filename="slow.bin"');
              for (var i = 0; i < 20; i++) {
                response.add(List.filled(4096, 1));
                await response.flush();
                await Future<void>.delayed(const Duration(milliseconds: 200));
              }
            // One that begins and then says nothing ever again.
            case '/stalled.bin':
              response.headers
                ..contentType = ContentType.binary
                ..set('content-length', '999999')
                ..set('content-disposition', 'attachment; filename="stalled.bin"');
              response.add(List.filled(1024, 1));
              await response.flush();
              await Future<void>.delayed(const Duration(seconds: 30));
            case '/blob.bin':
              response.headers
                ..contentType = ContentType.binary
                ..set('content-disposition', 'attachment; filename="report.bin"');
              response.add(List.filled(1024, 3));
            // The JSON behind the page, fetched by a click.
            case '/api-page':
              response.headers.contentType = ContentType.html;
              response.write('''
<html><body><button id="more">more</button><div id="out"></div><script>
  document.getElementById('more').addEventListener('click', async () => {
    const res = await fetch('/api/items');
    document.getElementById('out').textContent = (await res.json()).items.length;
  });
</script></body></html>''');
            case '/api/items':
              response.headers.contentType = ContentType.json;
              response.write('{"items":[1,2,3]}');
            case '/picker':
              response.headers.contentType = ContentType.html;
              response.write('''
<html><body><input id="pick" type="file"><p id="picked"></p><script>
  document.getElementById('pick').addEventListener('change', (e) => {
    document.getElementById('picked').textContent = e.target.files[0].name;
  });
</script></body></html>''');
            case '/outer':
              response.headers.contentType = ContentType.html;
              response.write('''
<html><body><p id="here">outside</p><iframe name="inner" src="/inner"></iframe></body></html>''');
            case '/inner':
              response.headers.contentType = ContentType.html;
              response.write('''
<html><body><p id="here">inside</p><input id="card"><button id="pay">pay</button>
<script>document.getElementById('pay').addEventListener('click', () => {
  document.getElementById('here').textContent = 'paid ' + document.getElementById('card').value;
});</script></body></html>''');
            case '/who':
              response.headers.contentType = ContentType.html;
              response.write('<html><body><p id="sent">${request.headers.value('cookie')}</p></body></html>');
            // Nothing in the markup; everything in the script. This is the page an HTTP
            // client cannot read and a browser can.
            case '/rendered':
              response.headers.contentType = ContentType.html;
              response.write('''
<html><body><div id="app"></div><script>
  setTimeout(() => {
    document.getElementById('app').innerHTML =
      '<ul class="items"><li class="item">alpha</li><li class="item">beta</li></ul>';
  }, 150);
</script></body></html>''');
            // An interstitial that becomes the real page on its own, the way Cloudflare's
            // does: 403, a marker, and a reload.
            case '/challenge':
              challenged++;
              if (challenged <= 2) {
                response.statusCode = 403;
                response.headers.contentType = ContentType.html;
                response.write('''
<html><head><title>Just a moment...</title></head>
<body class="cf-browser-verification">Checking your browser
<script>setTimeout(() => location.reload(), 300);</script></body></html>''');
              } else {
                response.headers.contentType = ContentType.html;
                response.write('<html><body><h1 id="real">through</h1></body></html>');
              }
            // One that never clears, the captcha nobody clicked.
            case '/stuck':
              response.statusCode = 403;
              response.headers.contentType = ContentType.html;
              response.write('''
<html><head><title>Just a moment...</title></head>
<body class="cf-browser-verification">Checking your browser
<script>setTimeout(() => location.reload(), 300);</script></body></html>''');
            case '/form':
              response.headers.contentType = ContentType.html;
              response.write('''
<html><body>
  <input id="name"><button id="go">go</button><div id="out"></div>
  <script>
    document.getElementById('go').addEventListener('click', () => {
      setTimeout(() => {
        const out = document.createElement('p');
        out.className = 'greeting';
        out.textContent = 'hello ' + document.getElementById('name').value;
        document.getElementById('out').appendChild(out);
      }, 100);
    });
  </script>
</body></html>''');
            case '/widgets':
              response.headers.contentType = ContentType.html;
              response.write('''
<html><body>
  <a id="link" href="/rendered" data-kind="next">go</a>
  <select id="fmt">
    <option value="e">EPUB</option>
    <option value="p">PDF</option>
  </select>
  <div id="menu">menu</div><div id="pop"></div>
  <p id="status">idle</p>
  <script>
    document.getElementById('fmt').addEventListener('change', (e) => {
      document.getElementById('status').textContent = 'picked ' + e.target.value;
    });
    document.getElementById('menu').addEventListener('mouseover', () => {
      document.getElementById('pop').textContent = 'opened';
    });
  </script>
</body></html>''');
            // A page that opens a dialog while it loads. Chrome holds the renderer on it,
            // so nothing below `load` ever happens until someone answers.
            case '/dialog':
              response.headers.contentType = ContentType.html;
              response.write('''
<html><body><p id="said"></p><script>
  const answer = prompt('who are you?', 'nobody');
  document.getElementById('said').textContent = 'answered ' + answer;
</script></body></html>''');
            case '/asset':
              response.headers.contentType = ContentType.binary;
              response.add(List.filled(2048, 7));
            // A page with credentials on it, a subresource of its own and one from a third party.
            case '/creds':
              response.headers.contentType = ContentType.html;
              response.write('''
<html><body><p id="auth">${request.headers.value('authorization')}</p>
<p id="cookie">${request.headers.value('cookie')}</p><p id="probe">${request.headers.value('x-probe')}</p>
<img src="/own.png"><img src="http://localhost:${request.uri.queryParameters['third']}/pixel.png"></body></html>''');
            case '/own.png':
              ownPixel = request.headers.value('authorization');
              response.headers.contentType = ContentType('image', 'png');
            case '/start':
              response.statusCode = 302;
              response.headers.set('location', '/dir/page');
            case '/dir/page':
              response.headers.contentType = ContentType.html;
              response.write('<html><body><a href="next">next</a></body></html>');
            default:
              response.statusCode = 404;
              response.write('nothing here');
          }
          await response.close();
        }),
      );
      browser = await ChromeClient.launch(tabs: 2);
    });

    tearDownAll(() async {
      if (chrome == null) return;
      await browser.close();
      await server.close(force: true);
    });

    test('reads the DOM the page builds, not the markup it was served', () async {
      await Http.scope(client: browser, () async {
        final plain = await IoClient().send(Request('GET', base.resolve('/rendered'))).then((r) => r.read());
        expect(plain.html.$('.item'), isEmpty, reason: 'the served markup has no items');

        final request = Request('GET', base.resolve('/rendered'))..[ChromeClient.waitFor] = '.item';
        final rendered = await (await browser.send(request)).read();
        expect(rendered.html.$('.item').map((e) => e.text), ['alpha', 'beta']);
      });
    }, skip: absent);

    test('a script directive runs before the DOM is read', () async {
      final request = Request('GET', base.resolve('/rendered'))
        ..[ChromeClient.waitFor] = '.item'
        ..[ChromeClient.script] = "document.querySelector('.item').textContent = 'edited'";
      final res = await (await browser.send(request)).read();
      expect(res.html.$('.item').text, 'edited');
    }, skip: absent);

    test('the status the server sent survives the render', () async {
      final res = await (await browser.send(Request('GET', base.resolve('/missing')))).read();
      expect(res.statusCode, 404);
      expect(res.isOk, isFalse);
    }, skip: absent);

    test('what is not a page render goes to the client underneath', () async {
      final seen = <String>[];
      final assets = MockClient((request) async {
        seen.add('${request.method} ${request.url.path}');
        return Response('delegated', 200);
      });
      final hybrid = await ChromeClient.launch(tabs: 1, assets: assets);
      try {
        // A POST, a ranged GET and an explicit `raw` never open a tab.
        await hybrid.send(Request('POST', base.resolve('/asset'), text: 'x'));
        await hybrid.send(Request('GET', base.resolve('/asset'), headers: {'range': 'bytes=0-'}));
        await hybrid.send(Request('GET', base.resolve('/asset'))..[Request.raw] = true);
        expect(seen, ['POST /asset', 'GET /asset', 'GET /asset']);
      } finally {
        await hybrid.close();
      }
    }, skip: absent);

    test('a download inside a Chrome scope writes the file, not a rendering of it', () async {
      final dir = await Directory.systemTemp.createTemp('dt_chrome_download_');
      try {
        final into = Path(dir.path) / 'asset.bin';
        // The bug this pins: a fresh download is a GET with no `range`, which used to be
        // indistinguishable from a page and got rendered — 2048 binary bytes came back as
        // the DOM Chrome builds to display them. `Request.raw` is what tells them apart.
        await Http.scope(client: browser, () => into.download(base.resolve('/asset')).drain<void>());
        expect(await into.asFile.length(), 2048);
        expect(await into.asFile.readAsBytes(), everyElement(7));
      } finally {
        await dir.delete(recursive: true);
      }
    }, skip: absent);

    test('an interstitial is waited out, not thrown', () async {
      challenged = 0;
      final res = await (await browser.send(Request('GET', base.resolve('/challenge')))).read();
      expect(res.statusCode, 200);
      expect(res.html.$('#real').text, 'through');
    }, skip: absent);

    test('one that never clears is a page, and the client survives it', () async {
      final stuck = Request('GET', base.resolve('/stuck'))..[ChromeClient.challenge] = 1.s;
      final res = await (await browser.send(stuck)).read();

      // Not an exception, not a closed tab: the interstitial itself, with its real status,
      // for the caller to decide about — and a human to click, in a visible window.
      expect(res.statusCode, 403);
      expect(res.text, contains('Just a moment'));
      expect(browser.isClosed, isFalse);

      // The next page still renders through the same client.
      final after = await (await browser.send(Request('GET', base.resolve('/rendered')))).read();
      expect(after.statusCode, 200);
    }, skip: absent);

    test('a page is driven by hand: fill, click, read, and read again', () async {
      final page = await browser.open(base.resolve('/form'));
      try {
        expect((await page.html()).$('.greeting'), isEmpty);
        expect(await page.fill('#name', 'world'), isTrue);
        expect(await page.click('#go'), isTrue);
        expect(await page.waitFor('.greeting'), isTrue);
        expect((await page.html()).$('.greeting').text, 'hello world');
        expect(await page.waitWhile('.nothing-like-this', timeout: 1.s), isTrue);
        expect(await page.waitFor('.never-appears', timeout: 500.ms), isFalse);
        expect((await page.screenshot()).length, greaterThan(100));
        expect(page.statusCode, 200);
      } finally {
        await page.close();
      }
    }, skip: absent);

    test('a held page does not starve the render pool', () async {
      final held = await browser.open(base.resolve('/form'));
      try {
        // `tabs: 2` and a page held open: renders still go through.
        for (var i = 0; i < 3; i++) {
          expect((await (await browser.send(Request('GET', base.resolve('/rendered')))).read()).statusCode, 200);
        }
        expect(held.isOpen, isTrue);
      } finally {
        await held.close();
      }
    }, skip: absent);

    test('a crawl over it emits what the scripts produced', () async {
      final items = await Http.scope(
        client: browser,
        () => base
            .resolve('/rendered')
            .scrape<String>()
            .onInit((ctx) => ctx.pages = 1)
            .onRequest((ctx) => ctx.request[ChromeClient.waitFor] = '.item')
            .onResponse((ctx) {
              for (final item in ctx.response.html.$('.item')) {
                ctx.emit(item.text);
              }
            })
            .rights
            .toList(),
      );
      expect(items, ['alpha', 'beta']);
    }, skip: absent);

    test('a raw request carries the browser\'s own user-agent, not nothing', () async {
      final seen = <String, String?>{};
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        probe.forEach((request) async {
          seen['ua'] = request.headers.value('user-agent');
          request.response.add(List.filled(64, 1));
          await request.response.close();
        }),
      );
      final at = Uri.parse('http://${probe.address.address}:${probe.port}/file.bin');
      await (await browser.send(Request('GET', at)..[Request.raw] = true)).read();
      await probe.close(force: true);
      expect(seen['ua'], contains('Chrome/'), reason: 'the file and the pages tell one story');
    }, skip: absent);

    test('text, attr and has read one value off a live page', () async {
      await browser.page(base.resolve('/widgets'), (page) async {
        expect(await page.text('#status'), 'idle');
        expect(await page.has('#fmt'), isTrue);
        expect(await page.has('.nothing'), isFalse);
        // Resolved by the DOM, so a root-relative href comes back absolute.
        expect(await page.attr('#link', 'href'), base.resolve('/rendered').toString());
        // Not a property, so it falls through to getAttribute.
        expect(await page.attr('#link', 'data-kind'), 'next');
        expect(await page.attr('.nothing', 'href'), isNull);
      });
    }, skip: absent);

    test('select fires change, by value or by the text a person reads', () async {
      await browser.page(base.resolve('/widgets'), (page) async {
        expect(await page.select('#fmt', 'p'), isTrue);
        expect(await page.text('#status'), 'picked p');
        expect(await page.select('#fmt', 'EPUB'), isTrue, reason: 'matched on the option text');
        expect(await page.text('#status'), 'picked e');
        expect(await page.select('#fmt', 'nope'), isFalse);
        expect(await page.select('.nothing', 'p'), isFalse);
      });
    }, skip: absent);

    test('hover opens what only opens on hover', () async {
      await browser.page(base.resolve('/widgets'), (page) async {
        expect(await page.text('#pop'), '');
        expect(await page.hover('#menu'), isTrue);
        expect(await page.waitFor('#pop:not(:empty)'), isTrue);
        expect(await page.text('#pop'), 'opened');
        expect(await page.hover('.nothing'), isFalse);
      });
    }, skip: absent);

    test('waitForNavigation waits out a click that leaves the page, and back returns', () async {
      await browser.page(base.resolve('/widgets'), (page) async {
        expect(await page.waitForNavigation(() => page.click('#link')), isTrue);
        expect(page.url.path, '/rendered');
        expect(await page.back(), isTrue);
        expect(page.url.path, '/widgets');
        expect(await page.has('#fmt'), isTrue, reason: 'the first page is really back');
      });
    }, skip: absent);

    test('cookies come back for handing to something that is not a browser', () async {
      await browser.page(base.resolve('/widgets'), (page) async {
        await page.eval("document.cookie = 'who=me; path=/'");
        final jar = await page.cookies();
        expect(jar.map((c) => '${c.name}=${c.value}'), contains('who=me'));
      });
    }, skip: absent);

    test('a dialog is answered, so the tab is not lost to it', () async {
      // Without an answer Chrome holds the renderer and this never returns: `load` does not
      // fire, the render times out, and the tab goes back into the pool still blocked.
      final page = await browser.open();
      final res = await page.goto(base.resolve('/dialog')).timeout(20.s);
      expect(res.text, contains('answered null'), reason: 'dismissed by default');

      page.onDialog((d) {
        expect(d.type, 'prompt');
        expect(d.message, 'who are you?');
        expect(d.defaultValue, 'nobody');
        return d.accept('me');
      });
      expect((await page.goto(base.resolve('/dialog')).timeout(20.s)).text, contains('answered me'));
      await page.close();
    }, skip: absent);

    test('what is blocked is never asked for, and the page still reads', () async {
      final page = await browser.open();
      await page.block(Resource.heavy);
      hits.clear();
      await page.goto(base.resolve('/heavy'));
      expect(await page.text('#title'), 'heavy');
      expect(hits['/pixel.png'], isNull, reason: 'an image was asked for anyway');
      expect(hits['/style.css'], 1, reason: 'a stylesheet is not heavy');
      // And the same tab lets it through again once it is told to.
      await page.block(const {});
      hits.clear();
      await page.goto(base.resolve('/heavy'));
      expect(hits['/pixel.png'], 1);
      await page.close();
    }, skip: absent);

    test('a click that downloads answers with the file it wrote', () async {
      final dir = await Directory.systemTemp.createTemp('tk_dl_');
      addTearDown(() => dir.delete(recursive: true));
      final page = await browser.open(base.resolve('/downloads'));
      final file = await page.waitForDownload(() => page.click('#get'), to: dir.path.path);
      expect(file, isNotNull);
      expect(file!.name, 'report.bin', reason: 'the name the site gave it');
      expect(await file.readBytes(), hasLength(1024));
      await page.close();
    }, skip: absent);

    test('a slow download is waited out; a stalled one is not', () async {
      final dir = await Directory.systemTemp.createTemp('tk_slow_');
      addTearDown(() => dir.delete(recursive: true));
      final page = await browser.open();

      // Twenty chunks 200ms apart is about four seconds of transfer, against a wait of two:
      // a deadline on the whole thing would fail it, and a wait on silence does not, because
      // Chrome reports progress about twice a second the entire way.
      await page.goto(base.resolve('/downloads'));
      final began = DateTime.now();
      final slow = await page.waitForDownload(
        () => page.eval("location.href = '/slow.bin'"),
        to: dir.path.path,
        timeout: 2.s,
      );
      expect(slow, isNotNull, reason: 'a download making progress was given up on');
      expect(await slow!.size(), 20 * 4096);
      expect(DateTime.now().difference(began), greaterThan(2.s), reason: 'it outlived its own timeout');

      // One that goes quiet after its first chunk is given up on promptly.
      final gaveUp = DateTime.now();
      final stalled = await page.waitForDownload(
        () => page.eval("location.href = '/stalled.bin'"),
        to: dir.path.path,
        timeout: 2.s,
      );
      expect(stalled, isNull);
      expect(DateTime.now().difference(gaveUp), lessThan(15.s), reason: 'silence should be noticed quickly');
      // Given up on is cancelled and erased, and only a finished file is ever moved in.
      expect(dir.listSync().map((e) => e.path.split(Platform.pathSeparator).last), ['slow.bin']);
      await page.close();
    }, skip: absent);

    test('a download that never starts is null, not a throw', () async {
      final dir = await Directory.systemTemp.createTemp('tk_none_');
      addTearDown(() => dir.delete(recursive: true));
      final page = await browser.open(base.resolve('/downloads'));
      expect(await page.waitForDownload(() async {}, to: dir.path.path, timeout: 2.s), isNull);
      await page.close();
    }, skip: absent);

    test('a download nobody waits for lands nowhere a person would find it', () async {
      // A wait with no `to:` that sees nothing, and then a click nobody waits for at all: the
      // browser-wide download directory used to be left pointing at the working directory.
      final page = await browser.open(base.resolve('/downloads'));
      expect(await page.waitForDownload(() async {}, timeout: 1.s), isNull);
      await page.click('#get');
      await Future<void>.delayed(const Duration(seconds: 2));
      await page.close();
      final added = Directory.current.listSync().map((e) => e.path).toSet().difference(before);
      expect(added.where((p) => p.endsWith('report.bin') || p.contains('crdownload')), isEmpty);
    }, skip: absent);

    test("a scope's credentials reach the page's own origin and no other host", () async {
      final third = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <String>[];
      third.listen((r) {
        seen.add('${r.headers.value('authorization')} ${r.headers.value('cookie')}');
        // A request still open when the test tears the server down is not the test's failure.
        r.response.close().catchError((Object _) {});
      });
      // A browser of its own, so the cookie this plants is not in the shared one's jar.
      final own = await ChromeClient.launch(tabs: 1);
      addTearDown(() async {
        await own.close();
        await third.close(force: true);
      });
      await Http.scope(
        client: own,
        headers: {'authorization': 'Bearer SECRET', 'cookie': 'sid=1', 'x-probe': 'yes'},
        () async {
          final page = (await base.resolve('/creds?third=${third.port}').get()).html;
          expect(page.$('#auth').text, 'Bearer SECRET');
          expect(page.$('#cookie').text, 'sid=1');
          expect(page.$('#probe').text, 'yes', reason: 'a header that is not a credential still goes');
        },
      );
      expect(ownPixel, 'Bearer SECRET', reason: "the page's own subresource is the same origin");
      expect(seen, isNotEmpty, reason: 'the third-party image was asked for');
      expect(seen, everyElement('null null'), reason: 'a third party gets no credential');
    }, skip: absent);

    test('a crawl over a browser reads the page from where it answered, after the redirect', () async {
      final seen = <String>[];
      await browser
          .scrape<void>(base.resolve('/start'))
          .onResponse((ctx) => seen.add('${ctx.url.path} ${ctx.resolve('next').path}'))
          .drain<void>();
      expect(seen, ['/dir/page /dir/next']);
    }, skip: absent);

    test("waitForResponse lets the action's own failure through", () async {
      final page = await browser.open(base.resolve('/api-page'));
      addTearDown(page.close);
      await expectLater(
        page.waitForResponse('/api/items', () => throw StateError('the click itself broke')),
        throwsStateError,
      );
    }, skip: absent);

    test(
      'a launched browser fetches nothing it was not asked for, and its death is noticed',
      () async {
        final marker = '--tk-marker-${DateTime.now().microsecondsSinceEpoch}';
        final own = await ChromeClient.launch(tabs: 1, args: ['--disable-features=TkOwnFeature', marker]);
        final [(pid, command)] = await _browsers(marker);
        expect(command, contains('--disable-component-update'));
        expect('--disable-features='.allMatches(command), hasLength(1), reason: 'Chrome reads only the last one');
        expect(command, allOf(contains('TkOwnFeature'), contains('OptimizationGuideModelDownloading')));

        Process.killPid(pid, ProcessSignal.sigkill);
        expect(await _eventually(() => own.isClosed), isTrue);
        final began = DateTime.now();
        await expectLater(
          own.get(base.resolve('/rendered')),
          throwsA(isA<ClientException>().having((e) => e.message, 'message', contains('disconnected'))),
        );
        expect(DateTime.now().difference(began), lessThan(5.s), reason: 'failed at once, not after a timeout');
        await own.close();
      },
      skip: absent ?? (Platform.isWindows ? 'reads the command line with ps' : null),
    );

    test(
      'a program killed with -9 takes its browser and its profile with it',
      () async {
        final dir = await Directory.systemTemp.createTemp('tk_orphan_');
        addTearDown(() => dir.delete(recursive: true));
        final marker = '--tk-orphan-${DateTime.now().microsecondsSinceEpoch}';
        final script = File('${dir.path}/child.dart')
          ..writeAsStringSync('''
import 'package:dart_toolkit/chrome.dart';
Future<void> main() async {
  await ChromeClient.launch(tabs: 1, args: ['$marker']);
  print('ready');
  await Future<void>.delayed(const Duration(minutes: 5));
}
''');
        final child = await Process.start(Platform.resolvedExecutable, [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          script.path,
        ]);
        final said = StringBuffer();
        child.stderr.transform(utf8.decoder).listen(said.write);
        final ready = await child.stdout.transform(utf8.decoder).any((out) => out.contains('ready')).timeout(60.s);
        expect(ready, isTrue, reason: 'the child never launched Chrome: $said');
        final [(_, command)] = await _browsers(marker);
        final profile = RegExp(r'--user-data-dir=(\S+)').firstMatch(command)![1]!;

        child.kill(ProcessSignal.sigkill);
        expect(await _eventually(() async => (await _browsers(marker)).isEmpty), isTrue, reason: 'Chrome outlived it');
        expect(await _eventually(() => !Directory(profile).parent.existsSync()), isTrue, reason: 'the profile is left');
      },
      skip: absent ?? (Platform.isWindows ? 'Windows has no reaper' : null),
    );

    test('the JSON behind the page comes back instead of the DOM', () async {
      final page = await browser.open(base.resolve('/api-page'));
      final res = await page.waitForResponse('/api/items', () => page.click('#more'));
      expect(res, isNotNull);
      expect(res!.statusCode, 200);
      expect(res.json['items'].to<List<Object?>>().length, 3);
      await page.close();
    }, skip: absent);

    test('a file input is filled the way a person fills one', () async {
      final dir = await Directory.systemTemp.createTemp('tk_up_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/photo.png')..writeAsBytesSync([1, 2, 3]);
      final page = await browser.open(base.resolve('/picker'));
      expect(await page.upload('#pick', [file.path.path]), isTrue);
      expect(await page.text('#picked'), 'photo.png');
      expect(await page.upload('#nothing', [file.path.path]), isFalse);
      await page.close();
    }, skip: absent);

    test('a saved session is put back, and the host sees it', () async {
      final page = await browser.open(base.resolve('/who'));
      await page.cookies([
        Cookie('sid', 'restored')
          ..domain = base.host
          ..path = '/',
      ]);
      await page.goto(page.url);
      expect(await page.text('#sent'), contains('sid=restored'));
      await page.close();
    }, skip: absent);

    test('the page is not told it is being driven', () async {
      final page = await browser.open(base.resolve('/rendered'));
      expect(await page.eval('navigator.webdriver'), isNull);
      expect(await page.eval('!!window.chrome'), isTrue);
      await page.close();
    }, skip: absent);

    test('a device is what the page believes it is on', () async {
      final phone = await ChromeClient.launch(tabs: 1, device: Device.phone);
      try {
        final page = await phone.open(base.resolve('/rendered'));
        expect(await page.eval('navigator.userAgent'), contains('iPhone'));
        // Not `innerWidth`: a page with no `<meta name=viewport>` gets Chrome's 980px mobile
        // fallback layout viewport, which is the emulation working rather than failing.
        expect(await page.eval('screen.width'), 393);
        expect(await page.eval('devicePixelRatio'), 3);
        expect(await page.eval('navigator.maxTouchPoints'), greaterThan(0));
      } finally {
        await phone.close();
      }
    }, skip: absent);

    test('a screenshot of one element is not a screenshot of the window', () async {
      final page = await browser.open(base.resolve('/heavy'));
      final whole = await page.screenshot();
      final one = await page.screenshot(selector: '#title');
      expect(whole, isNotEmpty);
      expect(one, isNotEmpty);
      expect(one.length, lessThan(whole.length));
      expect(await page.screenshot(selector: '#missing'), isEmpty);
      await page.close();
    }, skip: absent);

    test('forward goes back the way back came', () async {
      final page = await browser.open(base.resolve('/widgets'));
      await page.waitForNavigation(() => page.click('#link'));
      expect(page.url.path, '/rendered');
      expect(await page.back(), isTrue);
      expect(page.url.path, '/widgets');
      expect(await page.forward(), isTrue);
      expect(page.url.path, '/rendered');
      expect(await page.forward(), isFalse, reason: 'nothing ahead of the last entry');
      await page.close();
    }, skip: absent);

    test('a frame is a page, so every word already works inside one', () async {
      final page = await browser.open(base.resolve('/outer'));
      expect(await page.text('#here'), 'outside', reason: 'the same selector matches both');

      final inner = await page.frame('inner');
      expect(inner, isNotNull);
      expect(await inner!.text('#here'), 'inside');
      expect(await inner.fill('#card', '4242'), isTrue);
      expect(await inner.click('#pay'), isTrue);
      expect(await inner.waitFor('#here'), isTrue);
      expect(await inner.text('#here'), 'paid 4242');

      // Closing a view of a tab closes nothing; the tab is still there.
      await inner.close();
      expect(page.isOpen, isTrue);
      expect(await page.text('#here'), 'outside');
      expect(await page.frame('nothing-like-this'), isNull);
      await page.close();
    }, skip: absent);

    test('a proxy carries the pages and the files alike', () async {
      // A proxy that only counts and forwards. Chrome sends it absolute-form requests.
      final seen = <String>[];
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final forwarder = HttpClient();
      addTearDown(() async {
        forwarder.close(force: true);
        await proxy.close(force: true);
      });
      unawaited(
        proxy.forEach((request) async {
          final target = request.requestedUri;
          // Chrome talks to its own services through whatever proxy it is given; this one
          // only relays plain HTTP to the test server, and says so to everything else.
          if (request.method == 'CONNECT' || !target.hasScheme || target.host != '127.0.0.1') {
            request.response.statusCode = HttpStatus.badGateway;
            await request.response.close();
            return;
          }
          seen.add(target.path);
          final out = await forwarder.openUrl(request.method, target);
          request.headers.forEach((name, values) {
            if (name != 'host' && name != 'proxy-connection') out.headers.set(name, values.join(', '));
          });
          final answer = await out.close();
          request.response.statusCode = answer.statusCode;
          answer.headers.forEach((name, values) {
            if (name != 'transfer-encoding' && name != 'content-length') {
              request.response.headers.set(name, values.join(', '));
            }
          });
          await answer.pipe(request.response);
        }),
      );

      final through = await ChromeClient.launch(
        tabs: 1,
        proxy: 'http://127.0.0.1:${proxy.port}'.url,
        // Chrome bypasses the loopback for a proxy by default, which is exactly what this
        // test needs it not to do.
        args: const ['--proxy-bypass-list=<-loopback>'],
      );
      try {
        await Http.scope(client: through, () async {
          // A render, and then a download — which goes to the plain client underneath.
          expect((await (base / 'rendered').get()).text, contains('alpha'));
          final file = Path((await Directory.systemTemp.createTemp('tk_px_')).path) / 'asset.bin';
          addTearDown(() => file.parent.delete(recursive: true));
          await file.download(base.resolve('/asset')).drain<void>();
          expect(await file.size(), 2048);
        });
      } finally {
        await through.close();
      }

      expect(seen, contains('/rendered'), reason: 'the page did not go through the proxy');
      expect(seen, contains('/asset'), reason: 'the download went around it');
    }, skip: absent);

    test('a launched browser can keep its profile, and only one may hold it', () async {
      final dir = await Directory.systemTemp.createTemp('tk_profile_');
      addTearDown(() => dir.delete(recursive: true));
      final profile = dir.path.path / 'chrome';

      final first = await ChromeClient.launch(profile: profile, tabs: 1);
      final page = await first.open(base.resolve('/rendered'));
      await page.cookies([
        // Dated, not a session cookie: a session cookie is one a browser is *meant* to forget
        // when it closes, so it would prove nothing about the profile.
        Cookie('remembered', 'yes')
          ..domain = base.host
          ..path = '/'
          ..expires = DateTime.now().toUtc().add(const Duration(days: 1)),
      ]);
      await page.close();

      // A second browser on the same profile is refused, and says which it is rather than
      // leaving the reader to suspect the proxy, the binary or the timeout.
      await expectLater(
        ChromeClient.launch(profile: profile, tabs: 1),
        throwsA(
          isA<ClientException>().having((e) => e.message, 'message', allOf(contains(profile), contains('profile'))),
        ),
      );
      await first.close();

      // ...and once it lets go, the same profile is the same browser: the cookie is still there.
      final second = await ChromeClient.launch(profile: profile, tabs: 1);
      try {
        final again = await second.open(base.resolve('/rendered'));
        expect(
          (await again.cookies()).map((c) => '${c.name}=${c.value}'),
          contains('remembered=yes'),
          reason: 'a kept profile is what makes a login survive the run',
        );
        await again.close();
      } finally {
        await second.close();
      }
      expect(Directory(profile).existsSync(), isTrue, reason: 'a profile that was given is not erased');
    }, skip: absent);

    tearDownAll(() {
      // The last word on downloads: however the tests above went, none of them wrote here.
      if (chrome == null) return;
      final added = Directory.current.listSync().map((e) => e.path).toSet().difference(before);
      expect(
        added.where((p) => RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-|\.crdownload$|\.bin$').hasMatch(p)),
        isEmpty,
        reason: 'a Chrome test left a download in the working directory',
      );
    });

    test('a crawl runs on a client held rather than scoped', () async {
      final seen = <String>[];
      await browser
          .scrape<void>(base.resolve('/rendered'))
          .onRequest((ctx) => ctx.request[ChromeClient.waitFor] = '.item')
          .onResponse((ctx) => seen.addAll(ctx.response.html.$('.item').map((e) => e.text)))
          .drain<void>();
      expect(seen, ['alpha', 'beta'], reason: 'the DOM the page built, so it went through Chrome');
    }, skip: absent);
  });

  group('audit fixes: chrome', () {
    late HttpServer server;
    late HttpServer other;
    late Uri base;
    late ChromeClient browser;
    late Directory scratch;

    setUpAll(() async {
      if (chrome == null) return;
      scratch = await Directory.systemTemp.createTemp('chrome_audit');
      other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // dart:io says SAMEORIGIN by default, and this one is framed from another origin.
      other.defaultResponseHeaders.remove('x-frame-options', 'SAMEORIGIN');
      unawaited(
        other.forEach((request) async {
          request.response.headers.contentType = ContentType.html;
          request.response.write('<html><body><p id="in">inside</p></body></html>');
          await request.response.close();
        }),
      );
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      unawaited(
        server.forEach((request) async {
          final response = request.response;
          switch (request.uri.path) {
            case '/busy':
              // Loads at once, then keeps the network busy so its `networkIdle` comes late.
              response.headers.contentType = ContentType.html;
              response.write('<html><body>busy<script>fetch("/hang")</script></body></html>');
            case '/hang':
              await Future<void>.delayed(const Duration(milliseconds: 1200));
              response.write('late');
            case '/slow':
              await Future<void>.delayed(const Duration(milliseconds: 2500));
              response.headers.contentType = ContentType.html;
              response.write('<html><body><h1>slow</h1></body></html>');
            case '/spa':
              response.headers.contentType = ContentType.html;
              response.write(
                '<html><body><button onclick="history.pushState({}, \'\', \'/spa/2\')">go</button>'
                '<a id="hash" href="#part">part</a></body></html>',
              );
            case '/empty':
              response.statusCode = 204;
            case '/outer':
              response.headers.contentType = ContentType.html;
              response.write(
                '<html><body><iframe name="cross" src="http://localhost:${other.port}/inner"></iframe>'
                '<iframe name="same" src="/inner"></iframe></body></html>',
              );
            case '/inner':
              response.headers.contentType = ContentType.html;
              response.write('<html><body><p id="in">same</p></body></html>');
            case '/other':
              response.headers.contentType = ContentType.html;
              response.write('<html><body>other</body></html>');
            case '/files':
              response.headers.contentType = ContentType.html;
              response.write(
                '<html><body><a id="a" href="/file.txt" download>a</a>'
                '<a id="b" href="/file2.txt" download="file.txt">b</a>'
                '<a id="c" href="/file3.txt" target="_blank">c</a></body></html>',
              );
            case '/file.txt' || '/file2.txt' || '/file3.txt':
              response.headers.set('content-disposition', 'attachment; filename="file.txt"');
              response.write(request.uri.path);
            default:
              response.statusCode = 404;
          }
          await response.close();
        }),
      );
      browser = await ChromeClient.launch(tabs: 1);
    });

    tearDownAll(() async {
      if (chrome == null) return;
      await browser.close();
      await server.close(force: true);
      await other.close(force: true);
      await scratch.delete(recursive: true);
    });

    test('a late event from the page before does not settle the next navigation', () async {
      await browser.page(base.resolve('/busy'), (page) async {
        final res = await page.goto(base.resolve('/slow'), until: ChromeWait.idle);
        expect(res.html.$('h1').text, 'slow');
      }, until: ChromeWait.load);
    }, skip: absent);

    test('pushState and a #hash are navigations, and the URL follows them', () async {
      await browser.page(base.resolve('/spa'), (page) async {
        final watch = Stopwatch()..start();
        expect(await page.waitForNavigation(() => page.click('button')), isTrue);
        expect(page.url.path, '/spa/2');
        expect(await page.waitForNavigation(() => page.click('#hash')), isTrue);
        expect(page.url.fragment, 'part');
        expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      });
    }, skip: absent);

    test('a 204 is a response, not a transport error', () async {
      final res = await browser.get(base.resolve('/empty'));
      expect(res.statusCode, 204);
      expect(res.bytes, isEmpty);
    }, skip: absent);

    test('a cross-origin iframe is a frame, and a frame navigates only itself', () async {
      await browser.page(base.resolve('/outer'), (page) async {
        final cross = await page.frame('cross');
        expect(cross, isNotNull);
        expect(await cross!.text('#in'), 'inside');
        final same = (await page.frame('same'))!;
        await same.goto(base.resolve('/other'));
        expect(page.url.path, '/outer', reason: 'the tab stays where it was');
        expect(await same.text('body'), 'other');
      });
    }, skip: absent);

    test('two downloads of one name land side by side, never over each other', () async {
      await browser.page(base.resolve('/files'), (page) async {
        final to = Path(scratch.path);
        final first = await page.waitForDownload(() => page.click('#a'), to: to);
        final second = await page.waitForDownload(() => page.click('#b'), to: to);
        expect(first!.name, 'file.txt');
        expect(second!.name, 'file (2).txt');
        expect(await first.readText(), '/file.txt');
        expect(await second.readText(), '/file2.txt');
        // A link that opens a tab downloads from that tab, which is no page of ours.
        final third = await page.waitForDownload(() => page.click('#c'), to: to);
        expect(third!.name, 'file (3).txt');
      });
    }, skip: absent);
  });

  group('audit IV: chrome', () {
    late HttpServer server;
    late HttpServer other;
    late Uri base;
    late Uri away;
    late ChromeClient browser;

    setUpAll(() async {
      if (chrome == null) return;
      Future<HttpServer> serve() async {
        final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        unawaited(
          s.forEach((request) async {
            final response = request.response;
            switch (request.uri.path) {
              case '/echo':
                response.write(request.headers.value('cookie') ?? '');
              // A feed that grows by one screen per scroll, six times, and then ends.
              case '/feed':
                response.headers.contentType = ContentType.html;
                response.write('''
<html><body><div id="feed"></div><script>
  let n = 0;
  const more = () => {
    for (let i = 0; i < 5; i++) {
      const p = document.createElement('p');
      p.className = 'post';
      p.style.height = '400px';
      p.textContent = 'post ' + (n++);
      document.getElementById('feed').appendChild(p);
    }
  };
  more();
  window.addEventListener('scroll', () => {
    if (n < 35 && window.innerHeight + window.scrollY >= document.body.scrollHeight - 10) more();
  });
</script></body></html>''');
              default:
                response.headers.contentType = ContentType.html;
                response.write('<html><body>${request.uri.path}</body></html>');
            }
            await response.close();
          }),
        );
        return s;
      }

      server = await serve();
      other = await serve();
      base = Uri.parse('http://127.0.0.1:${server.port}');
      away = Uri.parse('http://localhost:${other.port}');
      browser = await ChromeClient.launch(tabs: 1);
    });

    tearDownAll(() async {
      if (chrome == null) return;
      await browser.close();
      await server.close(force: true);
      await other.close(force: true);
    });

    test('scroll(toEnd:) reads a feed to its end; scroll() stops after three', () async {
      await browser.page(base.resolve('/feed'), (page) async {
        await page.scroll(settle: 200.ms);
        expect((await page.html()).$('.post').length, lessThan(35), reason: 'three scrolls, not the feed');
        await page.scroll(toEnd: true, settle: 200.ms);
        expect((await page.html()).$('.post').length, 35);
      });
    }, skip: absent);

    test('cookies() is the whole browser\'s jar, dates kept, not only the page\'s', () async {
      final expiry = DateTime.now().toUtc().add(const Duration(days: 2));
      await browser.page(away, (page) async {
        await page.eval("document.cookie = 'there=1; path=/; expires=${HttpDate.format(expiry)}'");
      });
      await browser.page(base, (page) async {
        await page.eval("document.cookie = 'here=1; path=/'");
        final jar = await page.cookies();
        expect(jar.map((c) => c.name), containsAll(['here', 'there']));
        final there = jar.firstWhere((c) => c.name == 'there');
        expect(there.expires, isNotNull);
        expect(there.expires!.difference(expiry).inSeconds.abs(), lessThan(5));
        expect(jar.firstWhere((c) => c.name == 'here').expires, isNull, reason: 'a session cookie has no date');
      });
    }, skip: absent);

    test('a raw request carries the browser\'s cookies for its own URL and no other', () async {
      await browser.page(away, (page) => page.eval("document.cookie = 'elsewhere=1; path=/'"));
      await browser.page(base, (page) => page.eval("document.cookie = 'mine=1; path=/'"));
      Future<String> echo() async =>
          (await browser.send(Request('GET', base.resolve('/echo'))..[Request.raw] = true).then((r) => r.read())).text;
      // With no tab open the jar is read whole and matched here; with one, Chrome matches it.
      for (final sent in [await echo(), await browser.page(away, (_) => echo())]) {
        expect(sent, contains('mine=1'));
        expect(sent, isNot(contains('elsewhere')));
      }
    }, skip: absent);

    test(
      'connect starts a browser that outlives the client, and the next run joins it',
      () async {
        final dir = await Directory.systemTemp.createTemp('tk_connect_');
        final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = socket.port;
        await socket.close();
        final marker = '--tk-connect-${DateTime.now().microsecondsSinceEpoch}';
        try {
          final first = await ChromeClient.connect(port: port, profile: dir.path.path, headless: true, args: [marker]);
          await first.close();
          final [(pid, _)] = await _browsers(marker);
          final second = await ChromeClient.connect(port: port, profile: dir.path.path, headless: true, args: [marker]);
          expect(await second.page(base, (p) => p.text('body')), '/');
          await second.close();
          expect((await _browsers(marker)).map((b) => b.$1), [pid], reason: 'the second run joined, it did not start');
        } finally {
          for (final (pid, _) in await _browsers(marker)) {
            Process.killPid(pid);
          }
          await _eventually(() async => (await _browsers(marker)).isEmpty);
          await dir.delete(recursive: true).catchError((Object _) => dir);
        }
      },
      skip: absent ?? (Platform.isWindows ? 'reads the command line with ps' : null),
    );
  });

  if (chrome != null) {
    clientConformance('ChromeClient', (_) => ChromeClient.launch(tabs: 1));
  }
}
