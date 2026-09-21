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
