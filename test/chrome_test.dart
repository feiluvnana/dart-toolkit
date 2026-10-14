// Launching Chromium is slow on a cold cache: allow minutes overall.
@Timeout(Duration(minutes: 5))
@Tags(['chrome'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/src/cache.dart' as cache;
import 'package:puppeteer/puppeteer.dart' as pp;
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
        request.response.add(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
          ),
        );
      } else if (path == '/file') {
        request.response.headers.contentType = ContentType.binary;
        request.response.headers.set('content-disposition', 'attachment; filename="hello.txt"');
        request.response.write('download-me');
      } else if (path == '/cookie') {
        request.response.headers.set('set-cookie', 'tok=abc; Path=/');
        request.response.write('<title>C</title>');
      } else if (path == '/slow-img') {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
        ));
      } else if (path == '/trigger') {
        // Starts a slow image 100 ms after load (with a cache-buster so
        // every run really flies it over the network).
        final b = DateTime.now().microsecondsSinceEpoch;
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<script>setTimeout(() => { const i = new Image();'
          ' i.src = "/slow-img?b=$b"; }, 100);</script>',
        );
      } else if (path == '/chain') {
        // A slow request, then a follow-up 200 ms after it finished.
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<script>setTimeout(() => fetch("/slow-img?c=1").then(() =>'
          ' setTimeout(() => fetch("/follow"), 200)), 100);</script>',
        );
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

  String dataUrl(String html) => Uri.dataFromString(html, mimeType: 'text/html').toString();

  const testHtml = '''
<html><head><title>T</title></head>
<body><p class="a">Hi <a href="/x">L</a></p></body></html>
''';

  group('Chrome', () {
    test('Chromium and its temp profile die with a VM that throws before close', () async {
      final tmp = await Directory.systemTemp.createTemp('chrome_leak');
      addTearDown(() => tmp.delete(recursive: true));
      Future<List<String>> chromes() async {
        final r = await Process.run('pgrep', ['-f', tmp.path]);
        return (r.stdout as String).split('\n').where((e) => e.isNotEmpty).toList();
      }

      bool profiles() => tmp.listSync().any((e) => e.path.contains('puppeteer_dev_profile'));

      final child = await Process.start(
        Platform.resolvedExecutable,
        ['run', 'test/fixtures/chrome_leak.dart'],
        environment: {'TMPDIR': tmp.path},
      );
      final out = StringBuffer();
      child.stdout.transform(utf8.decoder).listen(out.write);
      child.stderr.drain<void>();
      // The VM must exit by itself: the watchdog's pipe must not hold it.
      expect(await child.exitCode.timeout(const Duration(minutes: 2)), isNot(0));
      expect(out.toString(), contains('ready'));
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(end) && ((await chromes()).isNotEmpty || profiles())) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final left = await chromes();
      for (final pid in left) {
        Process.killPid(int.parse(pid), ProcessSignal.sigkill);
      }
      expect(left, isEmpty);
      expect(profiles(), isFalse);
    }, skip: Platform.isWindows ? 'watchdog is POSIX only' : null);

    test('closing a connected browser closes its own tabs, not the host\'s', () async {
      final exe = (await pp.downloadChrome(cachePath: '${cache.userCacheDir()}/dart_toolkit/chrome')).executablePath;
      final host = await pp.puppeteer.launch(executablePath: exe);
      addTearDown(host.close);
      final before = (await host.pages).length;
      final b = await Chrome.connect(host.wsEndpoint);
      await b.open('data:text/html,<p>x</p>');
      await b.open('data:text/html,<p>y</p>');
      await b.close();
      expect((await host.pages).length, before);
    });

    test('connect to a dead port throws', () async {
      expect(Chrome.connect('http://127.0.0.1:1'), throwsA(anything));
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
      expect(await page.run<int>('window.innerWidth'), 800);
      await page.close();
      expect(hits.any((h) => h.endsWith('/img.png')), isFalse);
    });

    test('block aborts image requests', () async {
      await browser.open('$base/imgpage', block: ['image']).then((p) => p.close());
      expect(hits.any((h) => h.endsWith('/img.png')), isFalse);
      // Without block the image loads (settled via idle).
      final page = await browser.open('$base/imgpage');
      await page.idle();
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
    test('go/back/reload return the page', () async {
      final page = await browser.open(dataUrl('<title>One</title>'));
      expect((await page.go(dataUrl('<title>Two</title>')).html()).$('title').text(), 'Two');
      await page.go(dataUrl('<title>One</title>'));
      await page.go(dataUrl('<title>Two</title>'));
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

    test('evaluate<T>() evaluates, awaits, and nulls mistypes', () async {
      final page = await browser.open(dataUrl(testHtml));
      expect(await page.run<String>('document.title'), 'T');
      expect(await page.run<int>('1 + 1'), 2);
      expect(await page.run<String>('1 + 1'), isNull);
      expect(await page.run<String>('null'), isNull);
      expect(await page.run<String>('undefined'), isNull);
      expect(await page.run<String>('document.title'), 'T');
      await page.close();
    });

    test('B5: evaluate coerces numbers like Json.value; collections read via asList', () async {
      final page = await browser.open(dataUrl(testHtml));
      expect(await page.run<double>('1.0'), 1.0);
      expect(await page.run<int>('1.0'), 1);
      expect(
        Json.of(await page.run<dynamic>('["a", "b"]')).asList<String>(),
        ['a', 'b'],
      );
      expect(
        await page.run<Map<String, Object?>>('({"x": 1})'),
        {'x': 1},
      );
      await page.close();
    });

    test('cookies() feeds Http', () async {
      final page = await browser.open('$base/cookie');
      expect(await page.cookies(), contains('tok=abc'));
      await page.close();
    });
  });

  group('Page driving', () {
    test('click drives the page', () async {
      final page = await browser.open(dataUrl('<button id="b" onclick="document.title=\'C\'">x</button>'));
      await page.click('#b');
      expect(await page.run<String>('document.title'), 'C');
      await page.close();
    });

    test('click on a missing selector times out naming it', () async {
      final page = await browser.open(dataUrl(testHtml));
      await expectLater(
        page.click('#missing', timeout: const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>().having((e) => e.toString(), 'message', contains('#missing'))),
      );
      await page.close();
    });

    test('fill replaces the value with keystrokes', () async {
      final page = await browser.open(dataUrl('<input id="q" value="old">'));
      await page.fill('#q', 'hi');
      expect(await page.run<String>("document.querySelector('#q').value"), 'hi');
      await page.close();
    });

    test('B5: fill with an empty value clears the field', () async {
      final page = await browser.open(dataUrl('<input id="q" value="old">'));
      await page.fill('#q', '');
      expect(await page.run<String>("document.querySelector('#q').value"), '');
      await page.close();
    });

    test('press sends keys and chords', () async {
      final page = await browser.open(
        dataUrl(
          '<input id="q"><script>window.ks=[];'
          'document.querySelector("#q").addEventListener("keydown",'
          'e=>window.ks.push(e.key+"|"+e.ctrlKey));</script>',
        ),
      );
      await page.click('#q');
      await page.press('a');
      await page.press('b');
      expect(await page.run<String>("document.querySelector('#q').value"), 'ab');
      await page.press('ctrl+a');
      expect(await page.run<String>('JSON.stringify(window.ks)'), contains('a|true'));
      await page.press('backspace');
      expect(await page.run<String>("document.querySelector('#q').value"), 'a');
      await page.press('enter');
      await page.close();
    });

    test('B3: press names are case-insensitive; chars typed; unknown throws',
        () async {
      final page = await browser.open(dataUrl('<input id="q">'));
      await page.click('#q');
      await page.press('Enter');
      expect(await page.run<String>("document.querySelector('#q').value"), '');
      await page.press('esc');
      await page.press('+');
      expect(await page.run<String>("document.querySelector('#q').value"), '+');
      expect(
        page.press('frobnicate'),
        throwsA(isA<ArgumentError>()),
      );
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
      expect(await page.run<String>("document.querySelector('#s').value"), 'b');
      await page.close();
    });

    test('upload sets a file input from a Reader', () async {
      final page = await browser.open(dataUrl('<input type="file" id="f">'));
      final dir = await Directory.systemTemp.createTemp('chrome_up');
      try {
        await Fs.file('${dir.path}/note.txt').write('up-bytes');
        await page.upload('#f', Fs.file('${dir.path}/note.txt'));
        expect(await page.run<String>("document.querySelector('#f').files[0].name"), 'note.txt');
      } finally {
        await dir.delete(recursive: true);
      }
      await page.close();
    });

    test('B4: upload works on hidden file inputs', () async {
      final page = await browser.open(
          dataUrl('<input type="file" id="f" style="display:none">'));
      final dir = await Directory.systemTemp.createTemp('chrome_up');
      try {
        await Fs.file('${dir.path}/note.txt').write('up-bytes');
        await page.upload('#f', Fs.file('${dir.path}/note.txt'));
        expect(await page.run<String>("document.querySelector('#f').files[0].name"), 'note.txt');
      } finally {
        await dir.delete(recursive: true);
      }
      await page.close();
    });

    test('scroll goes to the bottom, scroll(sel) brings an element into view', () async {
      final page = await browser.open(dataUrl('<div style="height:3000px">top</div><div id="bottom">bot</div>'));
      await page.scroll();
      expect(await page.run<bool>('window.scrollY > 0'), isTrue);
      await page.scroll('#bottom');
      await page.close();
    });

    test('B6: scroll on a missing selector times out, not StateError',
        () async {
      final page = await browser.open(dataUrl(testHtml));
      await expectLater(
        page.scroll('#missing', const Duration(milliseconds: 500)),
        throwsA(isA<TimeoutException>()),
      );
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
      await expectLater(
        page.wait('.never', timeout: const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>().having((e) => e.toString(), 'message', contains('.never'))),
      );
      await page.close();
    });

    test('idle returns on a quiet page', () async {
      final page = await browser.open(dataUrl(testHtml));
      await page.idle();
      await page.close();
    });

    test('B2: idle waits for requests in flight', () async {
      // The image starts after load (open already returned): at the
      // idle call it is still in flight for ~1.5 s.
      final page = await browser.open('$base/trigger');
      final sw = Stopwatch()..start();
      await page.idle();
      sw.stop();
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(1000));
      await page.close();
    });
  });

  group('Page content out', () {
    test('H3: idle keeps a quiet period after the last request ends', () async {
      final page = await browser.open('$base/chain');
      await page.idle();
      expect(hits, contains('GET /follow'));
      await page.close();
    });

    test('screenshot is a PNG Reader, captured when read', () async {
      final page = await browser.open(dataUrl(testHtml));
      final reader = page.screenshot();
      final dir = await Directory.systemTemp.createTemp('chrome_shot');
      try {
        await (reader > Fs.file('${dir.path}/shot.png'));
        final bytes = await Fs.file('${dir.path}/shot.png').bytes();
        expect(bytes.length, greaterThan(100));
        expect(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
        await (page.screenshot(fullPage: true) > Fs.file('${dir.path}/full.png'));
        expect(
          await Fs.file('${dir.path}/full.png').size(),
          greaterThanOrEqualTo(await Fs.file('${dir.path}/shot.png').size()),
        );
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
      final page = await browser.open(dataUrl('<a id="d" href="$base/file">get it</a>'));
      final download = await page.download('#d');
      expect(download.name(), 'hello.txt');
      expect(await download.text(), 'download-me');
      final dir = await Directory.systemTemp.createTemp('chrome_dl');
      try {
        await (download > Fs.file('${dir.path}/${download.name()}'));
        expect(await Fs.file('${dir.path}/hello.txt').text(), 'download-me');
      } finally {
        await dir.delete(recursive: true);
      }
      await page.close();
    });

    test('B1: download on a missing selector throws, never crashes',
        () async {
      final page = await browser.open(dataUrl(testHtml));
      await expectLater(
        page.download('#missing', timeout: const Duration(seconds: 2)),
        throwsA(isA<TimeoutException>()),
      );
      await page.close();
    });

    test('H2: a failed download does not block the next one', () async {
      final page = await browser.open(dataUrl(
        '<a id="off" href="$base/file" style="position:fixed;left:-9999px;width:10px;height:10px">x</a>'
        '<a id="d" href="$base/file">get it</a>',
      ));
      await expectLater(
        page.download('#off', timeout: const Duration(seconds: 3)),
        throwsA(anything),
      );
      final download = await page.download('#d', timeout: const Duration(seconds: 5));
      expect(download.name(), 'hello.txt');
      await page.close();
    });

    test('M14: engine failures name the selector and are not reported as timeouts', () async {
      final page = await browser.open(dataUrl(
        '<a id="off" style="position:fixed;left:-9999px;width:10px;height:10px">x</a>',
      ));
      await expectLater(
        page.click('#off'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('#off'))),
      );
      await page.close();
      final sw = Stopwatch()..start();
      await expectLater(
        page.wait('#x', timeout: const Duration(seconds: 20)),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('#x'))),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('Future mirrors chain without an inner await', () async {
      final page = await browser
          .open(dataUrl('<button id="b" onclick="document.title=\'C\'">x</button>'))
          .click('#b')
          .idle();
      expect(await page.run<String>('document.title'), 'C');
      expect(await browser.open(dataUrl(testHtml)).html().$('p').text(), 'Hi L');
      await page.close();
    });
  });
}
