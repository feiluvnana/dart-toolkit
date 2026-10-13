// Launching Chromium is slow on a cold cache: allow minutes overall.
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:test/test.dart';

void main() {
  late Browser browser;
  late HttpServer server;
  late String base;
  final hits = <String>[];

  setUpAll(() async {
    browser = await Chrome.launch();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    server.listen((request) async {
      hits.add('${request.method} ${request.uri.path}');
      final path = request.uri.path;
      if (path == '/echo-header') {
        request.response.write(request.headers.value('x-test') ?? 'none');
      } else if (path == '/imgpage') {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<img src="/img.png">');
      } else if (path == '/img.png') {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
        ));
      } else if (path == '/file') {
        request.response.headers.contentType = ContentType.binary;
        request.response.headers.set(
          'content-disposition',
          'attachment; filename="hello.txt"',
        );
        request.response.write('download-me');
      } else if (path == '/cookie') {
        request.response.headers.set(
          'set-cookie',
          'tok=abc; Path=/',
        );
        request.response.write('<title>C</title>');
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('nope');
      }
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await browser.close();
    await browser.close(); // idempotent
    await server.close(force: true);
  });

  setUp(() => hits.clear());

  String dataUrl(String html) =>
      Uri.dataFromString(html, mimeType: 'text/html').toString();

  const testHtml = '''
<html><head><title>T</title></head>
<body><p class="a">Hi <a href="/x">L</a></p></body></html>
''';

  group('Chrome', () {
    test('connect to a dead port throws', () async {
      expect(
        Chrome.connect('http://127.0.0.1:1'),
        throwsA(anything),
      );
    });
  });

  group('Browser', () {
    test('open waits for load and pages lists tabs', () async {
      final before = (await browser.pages()).length;
      final page = await browser.open(dataUrl(testHtml));
      expect((await browser.pages()).length, greaterThanOrEqualTo(before + 1));
      await page.close();
    });

    test('open applies headers, block, viewport', () async {
      final page = await browser.open(
        '$base/echo-header',
        headers: {'x-test': 'hi'},
        block: ['image'],
        width: 800,
        height: 600,
      );
      expect(await page.text(), contains('hi'));
      expect(await page.eval<int>('window.innerWidth'), 800);
      await page.close();
      expect(hits.any((h) => h.endsWith('/img.png')), isFalse);
    });

    test('block aborts image requests', () async {
      await browser
          .open('$base/imgpage', block: ['image'])
          .then((p) => p.close());
      expect(hits.any((h) => h.endsWith('/img.png')), isFalse);
      // Without block the image loads (settled via waitIdle).
      final page = await browser.open('$base/imgpage');
      await page.waitIdle();
      await page.close();
      expect(hits.any((h) => h.endsWith('/img.png')), isTrue);
    });

    test('Future mirrors match', () async {
      final f = Chrome.launch();
      final b = await f;
      final page = await f.open(dataUrl(testHtml));
      expect((await f.pages()).length, greaterThanOrEqualTo(1));
      await page.close();
      await b.close();
    });
  });

  group('Page navigation', () {
    test('goto/back/reload return the page', () async {
      final page = await browser.open(dataUrl('<title>One</title>'));
      expect(
        (await page.goto(dataUrl('<title>Two</title>')).html())
            .$('title')
            .text(),
        'Two',
      );
      await page.goto(dataUrl('<title>One</title>'));
      await page.goto(dataUrl('<title>Two</title>'));
      await page.back();
      expect((await page.html()).$('title').text(), 'One');
      await page.reload();
      expect((await page.html()).$('title').text(), 'One');
      await page.close();
    });

    test('url() is the current URL', () async {
      final page = await browser.open('$base/echo-header');
      expect(await page.url(), '$base/echo-header');
      await page.close();
    });
  });

  group('Page reading', () {
    test('html() is the rendered DOM with the page URL as base', () async {
      final page = await browser.open(dataUrl(testHtml));
      final doc = await page.html();
      expect(doc.$('title').text(), 'T');
      expect(doc.$('a').attr('href'), isNotNull);
      await page.close();
    });

    test('text() is innerText', () async {
      final page = await browser.open(dataUrl(testHtml));
      final text = await page.text();
      expect(text, contains('Hi'));
      expect(text, contains('L'));
      await page.close();
    });

    test('eval<T>() evaluates, awaits, and nulls mistypes', () async {
      final page = await browser.open(dataUrl(testHtml));
      expect(await page.eval<String>('document.title'), 'T');
      expect(await page.eval<int>('1 + 1'), 2);
      expect(await page.eval<String>('1 + 1'), isNull);
      expect(await page.eval<String>('null'), isNull);
      expect(await page.eval<String>('undefined'), isNull);
      expect(await page.eval<String>('document.title'), 'T');
      await page.close();
    });

    test('cookieHeader() feeds Http', () async {
      final page = await browser.open('$base/cookie');
      expect(await page.cookieHeader(), contains('tok=abc'));
      await page.close();
    });
  });

  group('Page driving', () {
    test('click drives the page', () async {
      final page = await browser.open(
        dataUrl('<button id="b" onclick="document.title=\'C\'">x</button>'),
      );
      await page.click('#b');
      expect(await page.eval<String>('document.title'), 'C');
      await page.close();
    });

    test('click on a missing selector times out naming it', () async {
      final page = await browser.open(dataUrl(testHtml));
      expect(
        page.click('#missing', timeout: const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>().having(
          (e) => e.toString(),
          'message',
          contains('#missing'),
        )),
      );
      await page.close();
    });

    test('fill replaces the value with keystrokes', () async {
      final page = await browser.open(
        dataUrl('<input id="q" value="old">'),
      );
      await page.fill('#q', 'hi');
      expect(
        await page.eval<String>("document.querySelector('#q').value"),
        'hi',
      );
      await page.close();
    });

    test('press sends keys and chords', () async {
      final page = await browser.open(dataUrl(
        '<input id="q"><script>window.ks=[];'
        'document.querySelector("#q").addEventListener("keydown",'
        'e=>window.ks.push(e.key+"|"+e.ctrlKey));</script>',
      ));
      await page.click('#q');
      await page.press('a');
      await page.press('b');
      expect(await page.eval<String>("document.querySelector('#q').value"), 'ab');
      await page.press('ctrl+a');
      expect(
        await page.eval<String>('JSON.stringify(window.ks)'),
        contains('a|true'),
      );
      await page.press('backspace');
      expect(await page.eval<String>("document.querySelector('#q').value"), 'a');
      await page.press('enter');
      await page.close();
    });

    test('select picks the option by value', () async {
      final page = await browser.open(
        dataUrl(
          '<select id="s"><option value="a">A</option>'
          '<option value="b">B</option></select>',
        ),
      );
      await page.select('#s', 'b');
      expect(await page.eval<String>("document.querySelector('#s').value"), 'b');
      await page.close();
    });

    test('upload sets a file input from a Reader', () async {
      final page = await browser.open(dataUrl('<input type="file" id="f">'));
      final dir = await Directory.systemTemp.createTemp('chrome_up');
      try {
        await Fs.file('${dir.path}/note.txt').write('up-bytes');
        await page.upload('#f', Fs.file('${dir.path}/note.txt'));
        expect(
          await page.eval<String>("document.querySelector('#f').files[0].name"),
          'note.txt',
        );
      } finally {
        await dir.delete(recursive: true);
      }
      await page.close();
    });

    test('scroll goes to the bottom, or an element into view', () async {
      final page = await browser.open(
        dataUrl(
          '<div style="height:3000px">top</div><div id="bottom">bot</div>',
        ),
      );
      await page.scroll();
      expect(await page.eval<bool>('window.scrollY > 0'), isTrue);
      await page.scroll('#bottom');
      await page.close();
    });
  });

  group('Page waiting', () {
    test('wait resolves when the selector appears', () async {
      final page = await browser.open(
        dataUrl(
          '<script>setTimeout(() => document.body.innerHTML = '
          '"<p class=late>now</p>", 300)</script>',
        ),
      );
      await page.wait('.late');
      expect((await page.html()).$('.late').text(), 'now');
      await page.close();
    });

    test('wait times out naming the selector', () async {
      final page = await browser.open(dataUrl(testHtml));
      expect(
        page.wait('.never', timeout: const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>().having(
          (e) => e.toString(),
          'message',
          contains('.never'),
        )),
      );
      await page.close();
    });

    test('waitIdle returns on a quiet page', () async {
      final page = await browser.open(dataUrl(testHtml));
      await page.waitIdle();
      await page.close();
    });
  });

  group('Page content out', () {
    test('screenshot is a PNG Reader, captured when read', () async {
      final page = await browser.open(dataUrl(testHtml));
      final reader = page.screenshot();
      final dir = await Directory.systemTemp.createTemp('chrome_shot');
      try {
        await (reader > Fs.file('${dir.path}/shot.png'));
        final bytes = await Fs.file('${dir.path}/shot.png').bytes();
        expect(bytes.length, greaterThan(100));
        expect(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
        await (page.screenshot(fullPage: true) >
            Fs.file('${dir.path}/full.png'));
        expect(await Fs.file('${dir.path}/full.png').size(),
            greaterThanOrEqualTo(await Fs.file('${dir.path}/shot.png').size()));
      } finally {
        await dir.delete(recursive: true);
      }
      await page.close();
    });

    test('pdf is a Reader', () async {
      final page = await browser.open(dataUrl(testHtml));
      final bytes = await page.pdf().bytes();
      expect(bytes.length, greaterThan(100));
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
      await page.close();
    });

    test('download clicks and returns the file plus its name', () async {
      final page = await browser.open(
        dataUrl('<a id="d" href="$base/file">get it</a>'),
      );
      final download = await page.download('#d');
      expect(download.name(), 'hello.txt');
      expect(await download.text(), 'download-me');
      final dir = await Directory.systemTemp.createTemp('chrome_dl');
      try {
        await (download > Fs.file('${dir.path}/${download.name()}'));
        expect(
          await Fs.file('${dir.path}/hello.txt').text(),
          'download-me',
        );
      } finally {
        await dir.delete(recursive: true);
      }
      await page.close();
    });

    test('Future mirrors chain without an inner await', () async {
      final page = await browser
          .open(dataUrl('<button id="b" onclick="document.title=\'C\'">x</button>'))
          .click('#b')
          .waitIdle();
      expect(await page.eval<String>('document.title'), 'C');
      expect(await browser.open(dataUrl(testHtml)).html().$('p').text(), 'Hi L');
      await page.close();
    });
  });
}
