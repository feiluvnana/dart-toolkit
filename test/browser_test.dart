import 'dart:async';
import 'dart:io';

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

void main() {
  final chrome = _chrome();
  final absent = chrome == null ? 'no Chrome installed; set CHROME_PATH to run these' : null;

  group('BrowserClient', () {
    late HttpServer server;
    late Uri base;
    late BrowserClient browser;
    var challenged = 0;

    setUpAll(() async {
      if (chrome == null) return;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://${server.address.host}:${server.port}');
      unawaited(
        server.forEach((request) async {
          final response = request.response;
          switch (request.uri.path) {
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
            case '/asset':
              response.headers.contentType = ContentType.binary;
              response.add(List.filled(2048, 7));
            default:
              response.statusCode = 404;
              response.write('nothing here');
          }
          await response.close();
        }),
      );
      browser = await BrowserClient.launch(tabs: 2);
    });

    tearDownAll(() async {
      if (chrome == null) return;
      await browser.close();
      await server.close(force: true);
    });

    test('reads the DOM the page builds, not the markup it was served', () async {
      await Http.session(client: browser, () async {
        final plain = await IoClient().send(Request('GET', base.resolve('/rendered'))).then((r) => r.read());
        expect(plain.html.$('.item'), isEmpty, reason: 'the served markup has no items');

        final request = Request('GET', base.resolve('/rendered'))..[BrowserClient.waitFor] = '.item';
        final rendered = await (await browser.send(request)).read();
        expect(rendered.html.$('.item').map((e) => e.text), ['alpha', 'beta']);
      });
    }, skip: absent);

    test('a script directive runs before the DOM is read', () async {
      final request = Request('GET', base.resolve('/rendered'))
        ..[BrowserClient.waitFor] = '.item'
        ..[BrowserClient.script] = "document.querySelector('.item').textContent = 'edited'";
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
      final hybrid = await BrowserClient.launch(tabs: 1, assets: assets);
      try {
        // A POST, a ranged GET and an explicit `direct` never open a tab.
        await hybrid.send(Request('POST', base.resolve('/asset'), text: 'x'));
        await hybrid.send(Request('GET', base.resolve('/asset'), headers: {'range': 'bytes=0-'}));
        await hybrid.send(Request('GET', base.resolve('/asset'))..[BrowserClient.direct] = true);
        expect(seen, ['POST /asset', 'GET /asset', 'GET /asset']);
      } finally {
        await hybrid.close();
      }
    }, skip: absent);

    test('an interstitial is waited out, not thrown', () async {
      challenged = 0;
      final res = await (await browser.send(Request('GET', base.resolve('/challenge')))).read();
      expect(res.statusCode, 200);
      expect(res.html.$('#real').text, 'through');
    }, skip: absent);

    test('one that never clears is a page, and the client survives it', () async {
      final stuck = Request('GET', base.resolve('/stuck'))..[BrowserClient.challenge] = 1.s;
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
      final items = await Http.session(
        client: browser,
        () => base
            .resolve('/rendered')
            .scrape<String>()
            .onInit((ctx) => ctx.pages = 1)
            .onRequest((ctx) => ctx.request[BrowserClient.waitFor] = '.item')
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
  });

  if (chrome != null) {
    clientConformance('BrowserClient', (_) => BrowserClient.launch(tabs: 1));
  }
}
