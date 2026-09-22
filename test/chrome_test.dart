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

  group('ChromeClient', () {
    late HttpServer server;
    late Uri base;
    late ChromeClient browser;
    var challenged = 0;
    final hits = <String, int>{};

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

    test('navigating waits out a click that leaves the page, and back returns', () async {
      await browser.page(base.resolve('/widgets'), (page) async {
        expect(await page.navigating(() => page.click('#link')), isTrue);
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
      final file = await page.downloading(() => page.click('#get'), to: dir.path.path);
      expect(file, isNotNull);
      expect(file!.name, 'report.bin', reason: 'the name the site gave it');
      expect(await file.readBytes(), hasLength(1024));
      await page.close();
    }, skip: absent);

    test('a download that never starts is null, not a throw', () async {
      final page = await browser.open(base.resolve('/downloads'));
      expect(await page.downloading(() async {}, timeout: 2.s), isNull);
      await page.close();
    }, skip: absent);

    test('the JSON behind the page comes back instead of the DOM', () async {
      final page = await browser.open(base.resolve('/api-page'));
      final res = await page.fetching('/api/items', () => page.click('#more'));
      expect(res, isNotNull);
      expect(res!.statusCode, 200);
      expect(res.json['items'].to<List<Object?>>()?.length, 3);
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
      await page.reload();
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
      await page.navigating(() => page.click('#link'));
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

  if (chrome != null) {
    clientConformance('ChromeClient', (_) => ChromeClient.launch(tabs: 1));
  }
}
