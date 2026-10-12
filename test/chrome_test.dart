// Launching Chromium (plus a first-run binary download) is slow:
// allow the whole file to take minutes, individual tests stay fast.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:dart_toolkit/chrome.dart';
import 'package:test/test.dart';

void main() {
  late Browser browser;

  setUpAll(() async {
    browser = await Chrome.launch();
  });

  tearDownAll(() async {
    await browser.close();
  });

  String dataUrl(String html) =>
      Uri.dataFromString(html, mimeType: 'text/html').toString();

  const testHtml = '''
<html><head><title>T</title></head>
<body><p class="a">Hi <a href="/x">L</a></p></body></html>
''';

  group('Page', () {
    test('html() returns parsed rendered dom', () async {
      final page = await browser.open(dataUrl(testHtml));
      final doc = await page.html();
      expect(doc.$('title')[0].text(), 'T');
      expect(doc.$('a')[0].attr('href'), '/x');
      await page.close();
    });

    test('text() returns full page text', () async {
      final page = await browser.open(dataUrl(testHtml));
      final text = await page.text();
      expect(text, contains('Hi'));
      expect(text, contains('L'));
      await page.close();
    });

    test('eval runs JS and returns strings', () async {
      final page = await browser.open(dataUrl(testHtml));
      expect(await page.eval('document.title'), 'T');
      expect(await page.eval('String(1 + 1)'), '2');
      expect(await page.eval('null'), isNull);
      await page.close();
    });

    test('click drives the page', () async {
      final page = await browser.open(
        dataUrl('<button id="b" onclick="document.title=\'C\'">x</button>'),
      );
      await page.click('#b');
      expect(await page.eval('document.title'), 'C');
      await page.close();
    });

    test('type fills inputs', () async {
      final page = await browser.open(dataUrl('<input id="q">'));
      await page.type('#q', 'hi');
      expect(await page.eval("document.querySelector('#q').value"), 'hi');
      await page.close();
    });

    test('goto re-navigates the tab', () async {
      final page = await browser.open(dataUrl('<title>One</title>'));
      await page.goto(dataUrl('<title>Two</title>'));
      expect((await page.html()).$('title')[0].text(), 'Two');
      await page.close();
    });

    test('wait sleeps', () async {
      final page = await browser.open(dataUrl(testHtml));
      final sw = Stopwatch()..start();
      await page.wait(Duration(milliseconds: 300));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(300));
      await page.close();
    });

    test('dismiss swallows dialogs', () async {
      final page = await browser.open(dataUrl('<title>D</title>'));
      await page.dismiss();
      await page.eval("alert('x')"); // hangs forever if not dismissed
      await page.close();
    });

    test('screenshot writes a PNG file', () async {
      final page = await browser.open(dataUrl(testHtml));
      final dir = await Directory.systemTemp.createTemp('chrome_test');
      final path = '${dir.path}/shot.png';
      await page.screenshot(path);
      final bytes = await File(path).readAsBytes();
      expect(bytes.length, greaterThan(100));
      expect(
        bytes.sublist(0, 8),
        [137, 80, 78, 71, 13, 10, 26, 10],
      );
      await dir.delete(recursive: true);
      await page.close();
    });
  });
}
