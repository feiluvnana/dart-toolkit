// Launching Chromium is slow on a cold cache: allow minutes overall.
@Timeout(Duration(minutes: 5))
@Tags(['chrome'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/src/chrome_find.dart';
import 'package:dart_toolkit/utils.dart';
import 'package:test/test.dart';

import 'support/io.dart';

void main() {
  late Browser browser;
  late HttpServer server;
  late String base;
  final hits = <String>[];
  final hang = Completer<void>(); // never completes: a long-poll that never answers

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
        request.response.headers.add('set-cookie', 'tok=abc; Path=/');
        request.response.headers.add('set-cookie', 'b64=YQ==; Path=/');
        request.response.headers.add('set-cookie', 'rur="NHA\\05412"; Path=/');
        request.response.headers.add('set-cookie', 'deep=1; Path=/deep');
        request.response.write('<title>C</title>');
      } else if (path == '/slow-img') {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
          ),
        );
      } else if (path == '/trigger') {
        // Starts a slow image 100 ms after load (with a cache-buster so
        // every run really flies it over the network).
        final b = DateTime.now().microsecondsSinceEpoch;
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<script>setTimeout(() => { const i = new Image();'
          ' i.src = "/slow-img?b=$b"; }, 100);</script>',
        );
      } else if (path == '/spa') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<script>fetch("/api/graphql/query?q=1").then(() => '
          'setTimeout(() => { document.cookie = "sid=late; path=/"; }, 300));</script>',
        );
      } else if (path == '/api/graphql/query') {
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('x-kind', 'data');
        request.response.write('{"user":{"pk":42}}');
      } else if (path == '/framed') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<iframe name="f" src="/echo-header"></iframe><a id="d" href="/file" target="f">get it</a>',
        );
      } else if (path == '/hang') {
        await hang.future;
      } else if (path == '/longpoll') {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<script>fetch("/hang")</script>');
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

  /// A headless browser this test owns, with its DevTools `ws://` URL.
  Future<String> host() async {
    final dir = await Directory.systemTemp.createTemp('chrome_host');
    final proc = await Process.start(await chromeExecutable(headless: true), [
      '--headless',
      '--no-first-run',
      '--remote-debugging-port=0',
      '--user-data-dir=${dir.path}',
      'about:blank',
    ]);
    addTearDown(() async {
      proc.kill(ProcessSignal.sigkill);
      await proc.exitCode;
      await dir.delete(recursive: true);
    });
    final ws = Completer<String>();
    proc.stdout.drain<void>();
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final m = RegExp(r'ws://\S+').stringMatch(line);
      if (m != null && !ws.isCompleted) ws.complete(m);
    });
    return ws.future;
  }

  Future<int> hostTabs(String ws) async {
    final client = HttpClient();
    final res = await (await client.getUrl(Uri.parse(ws).replace(scheme: 'http', path: '/json/list'))).close();
    final list = jsonDecode(await res.transform(utf8.decoder).join()) as List<Object?>;
    client.close();
    return list.where((t) => (t! as Map)['type'] == 'page').length;
  }

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

      bool profiles() => tmp.listSync().any((e) => e.path.contains('dart_toolkit_chrome'));

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

    test('a launched browser never closed lets the script exit, and Chromium goes with it (B8)', () async {
      final tmp = await Directory.systemTemp.createTemp('chrome_noclose');
      addTearDown(() => tmp.delete(recursive: true));
      final child = await Process.start(
        Platform.resolvedExecutable,
        ['run', 'test/fixtures/chrome_noclose.dart'],
        environment: {'TMPDIR': tmp.path},
      );
      final out = StringBuffer(), err = StringBuffer();
      child.stdout.transform(utf8.decoder).listen(out.write);
      child.stderr.transform(utf8.decoder).listen(err.write);
      final code = await child.exitCode.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          child.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      expect((code, out.toString().trim()), (0, 'hi'), reason: '$err');
      Future<List<String>> chromes() async {
        final r = await Process.run('pgrep', ['-f', tmp.path]);
        return (r.stdout as String).split('\n').where((e) => e.isNotEmpty).toList();
      }

      final end = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(end) &&
          ((await chromes()).isNotEmpty || tmp.listSync().any((e) => e.path.contains('dart_toolkit_chrome')))) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final left = await chromes();
      for (final pid in left) {
        Process.killPid(int.parse(pid), ProcessSignal.sigkill);
      }
      expect(left, isEmpty);
    }, skip: Platform.isWindows ? 'watchdog is POSIX only' : null);

    test('S11: Chromium that exits on its own takes its watchdog and temp profile with it', () async {
      final tmp = await Directory.systemTemp.createTemp('chrome_gone');
      addTearDown(() => tmp.delete(recursive: true));
      final child = await Process.start(
        Platform.resolvedExecutable,
        ['run', 'test/fixtures/chrome_gone.dart'],
        environment: {'TMPDIR': tmp.path},
      );
      addTearDown(() => child.kill(ProcessSignal.sigkill));
      final err = StringBuffer();
      child.stderr.transform(utf8.decoder).listen(err.write);
      await child.stdout.transform(utf8.decoder).firstWhere((s) => s.contains('up')).timeout(const Duration(seconds: 60));
      Future<List<(String, String)>> ours() async {
        final ps = await Process.run('ps', ['-ax', '-o', 'pid=,args=']);
        return [
          for (final line in '${ps.stdout}'.split('\n'))
            if (line.contains(tmp.path)) (line.trim().split(' ').first, line),
        ];
      }

      // Every process with our TMPDIR in its arguments is this test's.
      for (final (pid, line) in await ours()) {
        if (line.contains('--user-data-dir=')) Process.killPid(int.parse(pid), ProcessSignal.sigkill);
      }
      final end = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(end) &&
          ((await ours()).isNotEmpty || tmp.listSync().any((e) => e.path.contains('dart_toolkit_chrome')))) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final left = await ours();
      for (final (pid, _) in left) {
        Process.killPid(int.parse(pid), ProcessSignal.sigkill);
      }
      expect(left, isEmpty, reason: '$err');
      expect(tmp.listSync().where((e) => e.path.contains('dart_toolkit_chrome')), isEmpty);
      child.stdin.writeln('done');
      expect(await child.exitCode.timeout(const Duration(seconds: 20)), 0, reason: '$err');
    }, skip: Platform.isWindows ? 'watchdog is POSIX only' : null);

    test('S10: a launched Chrome talks over a pipe and listens on no TCP port', () async {
      if (Platform.isWindows) return markTestSkipped('Windows keeps the debugging port');
      final profile = await Directory.systemTemp.createTemp('chrome_nolisten');
      addTearDown(() => profile.delete(recursive: true));
      final b = await Chrome.launch(profile: profile.path);
      addTearDown(b.close);
      expect(await (await b.open('$base/')).url(), '$base/');
      final ps = await Process.run('ps', ['-ax', '-o', 'pid=,args=']);
      final pids = [
        for (final line in '${ps.stdout}'.split('\n'))
          if (line.contains('--user-data-dir=${profile.path}') && !line.contains('--type=')) line.trim().split(' ').first,
      ];
      expect(pids, isNotEmpty);
      for (final pid in pids) {
        final lsof = await Process.run('lsof', ['-a', '-p', pid, '-iTCP', '-sTCP:LISTEN']);
        expect('${lsof.stdout}'.trim(), isEmpty, reason: 'Chrome $pid listens: ${lsof.stdout}');
      }
    });

    test('a reused profile keeps its cookies but not its tabs', () async {
      final profile = await Directory.systemTemp.createTemp('chrome_profile');
      addTearDown(() => profile.delete(recursive: true));
      final first = await Chrome.launch(profile: profile.path);
      await first.open('$base/cookie');
      await first.close();
      final again = await Chrome.launch(profile: profile.path);
      addTearDown(again.close);
      await Future<void>.delayed(const Duration(seconds: 1)); // restored tabs open late
      expect(await Future.wait([for (final p in await again.pages()) p.url()]), isNot(contains('$base/cookie')));
      expect((await (await again.open('$base/')).cookies())['tok'], 'abc');
    });

    test('closing a connected browser closes its own tabs, not the host\'s', () async {
      final ws = await host();
      final before = await hostTabs(ws);
      final b = await Chrome.connect(ws);
      await b.open('data:text/html,<p>x</p>');
      await b.open('data:text/html,<p>y</p>');
      expect(await hostTabs(ws), before + 2);
      await b.close();
      expect(await hostTabs(ws), before);
    });

    test('connect by http URL finds the endpoint', () async {
      final ws = await host();
      final b = await Chrome.connect(Uri.parse(ws).replace(scheme: 'http', path: '/').toString());
      expect(await b.open(dataUrl(testHtml)).text(), contains('Hi'));
      await b.close();
    });

    test('a connected browser restores the host download behaviour on close (regression: left pointing at a deleted folder)', () async {
      final ws = await host();
      // A recording proxy between the client and the host.
      final sent = <Map<String, Object?>>[];
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      proxy.listen((req) async {
        final down = await WebSocketTransformer.upgrade(req);
        final up = await WebSocket.connect(ws);
        down.listen((m) {
          sent.add(jsonDecode(m as String) as Map<String, Object?>);
          up.add(m);
        }, onDone: up.close);
        up.listen(down.add, onDone: down.close);
      });
      final b = await Chrome.connect('ws://127.0.0.1:${proxy.port}/');
      final page = await b.open(dataUrl('<a id="d" href="$base/file">get it</a>'));
      final download = await page.download('#d');
      await download.bytes(); // the path is known once the browser finishes
      final folder = Directory(download.origin().path()!).parent;
      await b.close();
      expect(
        [
          for (final m in sent)
            if (m['method'] == 'Browser.setDownloadBehavior') (m['params']! as Map)['behavior'],
        ],
        ['allowAndName', 'default'],
      );
      expect(folder.existsSync(), isFalse);
    });

    test('connect to a dead port throws', () async {
      expect(Chrome.connect('http://127.0.0.1:1'), throwsA(isA<BrowserException>()));
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
        block: {.image},
        width: 800,
        height: 600,
      );
      expect(await page.text(), contains('hi'));
      expect(await page.run('window.innerWidth').value<int>(), 800);
      await page.close();
      expect(hits.any((h) => h.endsWith('/img.png')), isFalse);
    });

    test('block aborts image requests', () async {
      await browser.open('$base/imgpage', block: {.image}).then((p) => p.close());
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
    test('go returns the page; go to its own url reloads', () async {
      final page = await browser.open(dataUrl('<title>One</title>'));
      expect((await page.go(dataUrl('<title>Two</title>')).html()).$('title').text(), 'Two');
      await page.go(dataUrl('<title>One</title>'));
      await page.go(await page.url());
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
      expect(await page.run('document.title').value<String>(), 'T');
      expect(await page.run('1 + 1').value<int>(), 2);
      expect(await page.run('1 + 1').value<String>(), isNull);
      expect(await page.run('null').value<String>(), isNull);
      expect(await page.run('undefined').value<String>(), isNull);
      expect(await page.run('document.title').value<String>(), 'T');
      await page.close();
    });

    test('B5: evaluate coerces numbers like Json.value; collections read via asList', () async {
      final page = await browser.open(dataUrl(testHtml));
      expect(await page.run('1.0').value<double>(), 1.0);
      expect(await page.run('1.0').value<int>(), 1);
      expect(await page.run('["a", "b"]').asList<String>(), ['a', 'b']);
      expect(await page.run('({"x": 1})').asMap<Object?>(), {'x': 1});
      await page.close();
    });

    test('cookies() is a jar that feeds Http and survives encode/parse', () async {
      final page = await browser.open('$base/cookie');
      final jar = await page.cookies();
      final header = cookieHeader(jar, '$base/')!;
      expect(header, contains('tok=abc'));
      // Regression: values with `=` or `"` were quoted into an invalid header.
      expect(header, contains('b64=YQ=='));
      expect(header, contains(r'rur="NHA\05412"'));
      expect(jar['tok'], 'abc');
      expect(Cookies.parse(jar.encode())['b64'], 'YQ==');
      await page.close();
    });

    test('cookies() is the current URL\'s jar, not every cookie the browser holds', () async {
      final page = await browser.open('$base/cookie');
      expect((await page.cookies())['deep'], isNull);
      await page.close();
    });

    test('E3: run evaluates its source once, calls a function result once, returns Json', () async {
      final page = await browser.open(dataUrl(testHtml));
      await page.run('window.n = 0');
      expect(await page.run('window.n++; () => ++window.n').value<int>(), 2);
      expect(await page.run('window.n').value<int>(), 2, reason: 'the source ran once, its function once');
      expect(await page.run('({a: {b: [1, 2]}})').$('a.b').asList<int>(), [1, 2]);
      expect(await page.run('undefined').value<int>(), isNull);
      await page.close();
    });

    test('run gives up on a promise that never settles after the page timeout (B19)', () async {
      final page = await browser.open(dataUrl(testHtml), timeout: const Duration(seconds: 1));
      final sw = Stopwatch()..start();
      await expectLater(page.run('new Promise(() => {})'), throwsA(isA<TimeoutException>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      await expectLater(page.run('({then() {}})'), throwsA(isA<TimeoutException>()), reason: 'by reference too');
      expect(await page.run('1 + 1').value<int>(), 2, reason: 'the page still answers');
      await page.close();
    });

    test('run calls a function source; a script that throws is BrowserException', () async {
      final page = await browser.open(dataUrl(testHtml));
      expect(await page.run('() => document.title').value<String>(), 'T');
      expect(await page.run('new Promise((r) => setTimeout(() => r(7), 10))').value<int>(), 7);
      expect(await page.run('NaN').value<double>(), isNaN);
      await expectLater(
        page.run('null.x').value<int>(),
        throwsA(isA<BrowserException>().having((e) => e.message, 'message', contains('TypeError'))),
      );
      await page.close();
    });

    test('cookie() waits until the page sets it; responses() captures XHR/fetch', () async {
      final page = await browser.open('about:blank', timeout: 2.seconds);
      final captured = page.responses('*/graphql/query*').first;
      await page.go('$base/spa');
      final c = await captured;
      expect((c.status(), c.header('X-Kind')), (200, 'data'));
      expect(c.url(), '$base/api/graphql/query?q=1');
      expect(c.name(), 'query', reason: "named like a Response: the URL's last segment");
      expect(await c.text(), '{"user":{"pk":42}}');
      expect(await page.cookie('sid'), 'late');
      await expectLater(page.cookie('never'), throwsA(isA<TimeoutException>())); // the page's 2 s
      await page.close();
    });

    test('BrowserException is an Exception and a ToolkitException, never an Error', () {
      final e = BrowserException('click missed', selector: '#a');
      expect(e, isA<Exception>().having((x) => x, 'is Error', isNot(isA<Error>())));
      expect(e, isA<ToolkitException>().having((x) => x.message, 'message', 'click missed'));
    });

    test('closing the tab during cookie() or wait() is BrowserException', () async {
      final page = await browser.open(dataUrl(testHtml), timeout: 10.seconds);
      final waiting = expectLater(
        page.cookie('never'),
        throwsA(isA<BrowserException>().having((e) => e.message, 'message', 'browser closed')),
      );
      final selecting = expectLater(page.wait('#never'), throwsA(isA<BrowserException>()));
      await Future<void>.delayed(300.milliseconds);
      await page.close();
      await waiting;
      await selecting;
    });
  });

  group('Page driving', () {
    test('click drives the page', () async {
      final page = await browser.open(dataUrl('<button id="b" onclick="document.title=\'C\'">x</button>'));
      await page.click('#b');
      expect(await page.run('document.title').value<String>(), 'C');
      await page.close();
    });

    test('click on a missing selector times out naming it', () async {
      final page = await browser.open(dataUrl(testHtml), timeout: const Duration(milliseconds: 300));
      await expectLater(
        page.click('#missing'),
        throwsA(isA<TimeoutException>().having((e) => e.toString(), 'message', contains('#missing'))),
      );
      await page.close();
    });

    test('timeouts print a human limit once (regression: 0:00:00.300000 twice)', () async {
      final page = await browser.open(dataUrl(testHtml), timeout: const Duration(milliseconds: 300));
      final e = await page
          .click('#nope')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<TimeoutException>());
      expect(e.toString(), 'TimeoutException: no actionable #nope after 300 ms');
      expect((e as TimeoutException).duration, const Duration(milliseconds: 300));
      await page.close();
    });

    test('every action wraps engine failures as BrowserException (regression: puppeteer types leaked)', () async {
      final page = await browser.open(dataUrl('<input id="q">'));
      await page.close();
      await expectLater(page.press('enter'), throwsA(isA<BrowserException>()));
      await expectLater(page.press('wheeldown'), throwsA(isA<BrowserException>()));
      await expectLater(page.scroll(), throwsA(isA<BrowserException>()));
      await expectLater(page.fill('#q', 'x'), throwsA(isA<BrowserException>()));
      await expectLater(page.press('nokey'), throwsArgumentError);
    });

    test('a reader on a failed page future never fails unhandled (regression)', () async {
      final reader = Future<Page>.error(StateError('no page')).screenshot();
      await Future<void>.delayed(Duration.zero);
      await expectLater(reader.bytes(), throwsStateError);
    });

    test('fill replaces the value with keystrokes', () async {
      final page = await browser.open(dataUrl('<input id="q" value="old">'));
      await page.fill('#q', 'hi');
      expect(await page.run("document.querySelector('#q').value").value<String>(), 'hi');
      await page.close();
    });

    test('fill replaces a contenteditable\'s text (regression: did nothing)', () async {
      final page = await browser.open(
        dataUrl(
          '<div id="e" contenteditable>old <b>text</b></div><script>window.n=0;'
          'document.querySelector("#e").addEventListener("input",()=>window.n++);</script>',
        ),
      );
      await page.fill('#e', 'new');
      expect(await page.run("document.querySelector('#e').innerText").value<String>(), 'new');
      expect(await page.run('window.n').value<int>(), greaterThan(0));
      await page.fill('#e', '');
      expect(
        (await page.run("document.querySelector('#e').innerText").value<String>())!.trim(),
        '',
      ); // as a user's delete leaves it
      await page.close();
    });

    test('fill types non-ASCII text and fires keydown per ASCII key', () async {
      final page = await browser.open(
        dataUrl(
          '<input id="q"><script>window.ks=0;'
          'document.querySelector("#q").addEventListener("keydown",()=>window.ks++);</script>',
        ),
      );
      await page.fill('#q', 'héllo 世界');
      expect(await page.run("document.querySelector('#q').value").value<String>(), 'héllo 世界');
      expect(await page.run('window.ks').value<int>(), 5); // h l l o and the space
      await page.close();
    });

    test('B5: fill with an empty value clears the field', () async {
      final page = await browser.open(dataUrl('<input id="q" value="old">'));
      await page.fill('#q', '');
      expect(await page.run("document.querySelector('#q').value").value<String>(), '');
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
      expect(await page.run("document.querySelector('#q').value").value<String>(), 'ab');
      await page.press('ctrl+a');
      expect(await page.run('JSON.stringify(window.ks)').value<String>(), contains('a|true'));
      await page.press('backspace');
      expect(await page.run("document.querySelector('#q').value").value<String>(), 'a');
      await page.press('enter');
      await page.close();
    });

    test('B3: press names are case-insensitive; chars typed; unknown throws', () async {
      final page = await browser.open(dataUrl('<input id="q">'));
      await page.click('#q');
      await page.press('Enter');
      expect(await page.run("document.querySelector('#q').value").value<String>(), '');
      await page.press('esc');
      await page.press('+');
      expect(await page.run("document.querySelector('#q').value").value<String>(), '+');
      expect(page.press('frobnicate'), throwsA(isA<ArgumentError>()));
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
      expect(await page.run("document.querySelector('#s').value").value<String>(), 'b');
      // Regression: a missing option threw TimeoutException at once.
      await expectLater(
        page.select('#s', 'zzz'),
        throwsA(isA<BrowserException>().having((e) => e.selector, 'selector', '#s')),
      );
      await page.close();
    });

    test('upload sets a file input from a Reader', () async {
      final page = await browser.open(
        dataUrl(
          '<input type="file" id="f"><script>window.seen=[];for (const t of ["input","change"])'
          ' document.querySelector("#f").addEventListener(t,()=>window.seen.push(t));</script>',
        ),
      );
      final dir = await Directory.systemTemp.createTemp('chrome_up');
      try {
        await Fs.file('${dir.path}/note.txt').write('up-bytes');
        await page.upload('#f', Fs.file('${dir.path}/note.txt'));
        expect(await page.run("document.querySelector('#f').files[0].name").value<String>(), 'note.txt');
        expect(await page.run('window.seen.join()').value<String>(), 'input,change');
      } finally {
        await dir.delete(recursive: true);
      }
      await page.close();
    });

    test('B4: upload works on hidden file inputs', () async {
      final page = await browser.open(dataUrl('<input type="file" id="f" style="display:none">'));
      final dir = await Directory.systemTemp.createTemp('chrome_up');
      try {
        await Fs.file('${dir.path}/note.txt').write('up-bytes');
        await page.upload('#f', Fs.file('${dir.path}/note.txt'));
        expect(await page.run("document.querySelector('#f').files[0].name").value<String>(), 'note.txt');
      } finally {
        await dir.delete(recursive: true);
      }
      await page.close();
    });

    test('scroll goes to the bottom', () async {
      final page = await browser.open(dataUrl('<div style="height:3000px">top</div><div id="bottom">bot</div>'));
      await page.scroll();
      expect(await page.run('window.scrollY > 0').value<bool>(), isTrue);
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
      final page = await browser.open(dataUrl(testHtml), timeout: const Duration(milliseconds: 300));
      await expectLater(
        page.wait('.never'),
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

  group('Page idle with a long-poll', () {
    test('a request open over 5 s stops holding idle (regression: idle never settled)', () async {
      final page = await browser.open('$base/longpoll', timeout: const Duration(seconds: 15));
      final sw = Stopwatch()..start();
      await page.idle();
      expect(sw.elapsed, lessThan(const Duration(seconds: 8)));
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
        final m = Meter();
        await (download & m > Fs.file('${dir.path}/${download.name()}'));
        expect(await Fs.file('${dir.path}/hello.txt').text(), 'download-me');
        expect((m.done(), m.total()), (11, 11), reason: "a probe hears the browser's bytes");
      } finally {
        await dir.delete(recursive: true);
      }
      await page.close();
    });

    test('download credits one started in an iframe (regression: main frame only)', () async {
      final page = await browser.open('$base/framed', timeout: const Duration(seconds: 10));
      final download = await page.download('#d');
      expect((download.name(), await download.text()), ('hello.txt', 'download-me'));
      await page.close();
    });

    test('B1: download on a missing selector throws, never crashes', () async {
      final page = await browser.open(dataUrl(testHtml), timeout: const Duration(seconds: 2));
      await expectLater(
        page.download('#missing'),
        throwsA(isA<TimeoutException>()),
      );
      await page.close();
    });

    test('H2: a failed download does not block the next one', () async {
      final page = await browser.open(
        dataUrl(
          '<a id="off" href="$base/file" style="position:fixed;left:-9999px;width:10px;height:10px">x</a>'
          '<a id="d" href="$base/file">get it</a>',
        ),
        timeout: const Duration(seconds: 5),
      );
      await expectLater(page.download('#off'), throwsA(anything));
      final download = await page.download('#d');
      expect(download.name(), 'hello.txt');
      await page.close();
    });

    test('M14: engine failures name the selector and are not reported as timeouts', () async {
      final page = await browser.open(
        dataUrl('<a id="off" style="position:fixed;left:-9999px;width:10px;height:10px">x</a>'),
      );
      await expectLater(
        page.click('#off'),
        throwsA(isA<BrowserException>().having((e) => e.message, 'message', contains('#off'))),
      );
      await page.close();
      final sw = Stopwatch()..start();
      await expectLater(
        page.wait('#x'),
        throwsA(isA<BrowserException>().having((e) => e.message, 'message', contains('#x'))),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('Future mirrors chain without an inner await', () async {
      final page = await browser
          .open(dataUrl('<button id="b" onclick="document.title=\'C\'">x</button>'))
          .click('#b')
          .idle();
      expect(await page.run('document.title').value<String>(), 'C');
      expect(await browser.open(dataUrl(testHtml)).html().$('p').text(), 'Hi L');
      await page.close();
    });
  });
}
