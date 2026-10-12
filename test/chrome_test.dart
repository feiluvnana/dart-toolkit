// Browser pipelines through a real Chrome: open, navigate, drive, capture.
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/native.dart';
import 'package:dart_toolkit/path.dart';
import 'package:test/test.dart';

/// The browser executable, or `null` when there is none to drive.
String? _browserExe() {
  final env = io.Platform.environment;
  if (env['DART_TOOLKIT_CHROME'] case final path? when path.isNotEmpty && io.File(path).existsSync()) return path;
  final candidates = <String>[
    if (io.Platform.isWindows) ...[
      '${env['ProgramFiles']}\\Google\\Chrome\\Application\\chrome.exe',
      '${env['ProgramFiles(x86)']}\\Google\\Chrome\\Application\\chrome.exe',
      '${env['LOCALAPPDATA']}\\Google\\Chrome\\Application\\chrome.exe',
      '${env['ProgramFiles']}\\Microsoft\\Edge\\Application\\msedge.exe',
      '${env['ProgramFiles(x86)']}\\Microsoft\\Edge\\Application\\msedge.exe',
    ],
    if (io.Platform.isMacOS) ...['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'],
    if (io.Platform.isLinux) ...['/usr/bin/google-chrome', '/usr/bin/chromium'],
  ];
  for (final c in candidates) {
    if (io.File(c).existsSync()) return c;
  }
  return null;
}

/// Throws a skip unless the native libraries and a browser are all here.
String _requireChrome() {
  if (!Native.ok) markTestSkipped('native libraries not built: ${Native.reason}');
  final exe = _browserExe();
  if (exe == null) markTestSkipped('no Chrome or Edge executable found');
  return exe!;
}

/// Runs [_serve] on a helper isolate and answers its port. The browser calls
/// below block the calling isolate inside FFI, so the fixture server cannot
/// live on this isolate's event loop (it would never answer while a call is
/// in flight — a deadlock, not a browser bug).
Future<(int, Isolate)> _serveIsolated() async {
  final ready = ReceivePort();
  final isolate = await Isolate.spawn(_serveEntry, ready.sendPort);
  final port = await ready.first as int;
  return (port, isolate);
}

/// Helper-isolate entry: serves fixtures until killed.
void _serveEntry(SendPort back) async {
  final server = await _serve();
  back.send(server.port);
  await Completer<void>().future;
}

/// The fixture pages: an SPA that hydrates late, and a form driven by script.
Future<io.HttpServer> _serve() async {
  final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    void html(String body) {
      response.headers.contentType = io.ContentType.html;
      response.write('<html><head><title>fixture</title></head><body>$body</body></html>');
    }

    switch (request.uri.path) {
      case '/spa':
        html('''<div id="app"></div><script>
  setTimeout(() => {
    document.getElementById('app').innerHTML =
      '<div class="product-card"><span class="name">Gadget</span></div>' +
      '<div class="product-card"><span class="name">Widget</span></div>';
  }, 400);
</script>''');
      case '/form':
        html('''<input id="name"><button id="go">go</button><div id="out"></div>
<script>
  document.getElementById('go').addEventListener('click', () => setTimeout(() => {
    document.getElementById('out').innerHTML =
      '<p class="greeting">hello ' + document.getElementById('name').value + '</p>';
  }, 100));
</script>''');
      default:
        response.statusCode = 404;
        response.write('no such fixture');
    }
    await response.close();
  });
  return server;
}

/// Live browser pids right now (tasklist on Windows, pgrep elsewhere).
Future<Set<int>> _chromePids() async {
  if (io.Platform.isWindows) {
    final r = await io.Process.run('tasklist', ['/FO', 'CSV', '/NH']);
    final pids = <int>{};
    for (final line in '${r.stdout}'.split('\n')) {
      final cells = line.split('","');
      if (cells.length < 2) continue;
      final image = cells[0].replaceAll('"', '').toLowerCase();
      if (image != 'chrome.exe' && image != 'msedge.exe') continue;
      final pid = int.tryParse(cells[1].replaceAll('"', '').trim());
      if (pid != null && pid > 0) pids.add(pid);
    }
    return pids;
  }
  final r = await io.Process.run('pgrep', ['-f', 'chrome|chromium|msedge']);
  return '${r.stdout}'.split('\n').map(int.tryParse).whereType<int>().toSet();
}

/// Temp profiles the engine made (`tk_chrome_profile_*` under the temp dir).
Future<Set<String>> _tempProfiles() async {
  final root = io.Directory.systemTemp;
  final out = <String>{};
  await for (final e in root.list()) {
    if (e is io.Directory && e.path.split(io.Platform.pathSeparator).last.startsWith('tk_chrome_profile_')) {
      out.add(e.path);
    }
  }
  return out;
}

void main() {
  group('browser pipeline', () {
    late int port;
    late Isolate serverIsolate;
    late String base;
    late String exe;

    setUpAll(() async {
      exe = _requireChrome();
      final served = await _serveIsolated();
      port = served.$1;
      serverIsolate = served.$2;
      base = 'http://127.0.0.1:$port';
    });

    tearDownAll(() async {
      serverIsolate.kill();
    });

    test('open → wait → html() carries hydrated markup', () async {
      final chrome = Chrome(executable: exe);
      try {
        expect(await chrome.alive(), isFalse);
        final page = await chrome.open('$base/spa');
        expect(await chrome.alive(), isTrue);
        await page.wait('.product-card');
        final doc = await page.html();
        expect(doc.text, contains('Gadget'));
        expect(doc.all('.product-card'), hasLength(2));
        await page.close();
      } finally {
        await chrome.close();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('type + click drive the form', () async {
      final chrome = Chrome(executable: exe);
      try {
        final page = await chrome.open('$base/form');
        await page.type('#name', 'ada');
        await page.click('#go');
        await page.wait('.greeting');
        expect((await page.html()).text, contains('hello ada'));
        await page.close();
      } finally {
        await chrome.close();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('screenshot() pipes to a File Image decodes', () async {
      final tmp = await io.Directory.systemTemp.createTemp('tk_phased_shot_');
      try {
        final chrome = Chrome(executable: exe);
        try {
          final page = await chrome.open('$base/spa');
          await page.wait('.product-card');
          final png = await page.screenshot();
          expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
          final path = '${tmp.path}/shot.png';
          await page.screenshot().pipe(File(path));
          final back = Image.decode(await io.File(path).readAsBytes());
          expect(back.w, greaterThan(0));
          expect(back.h, greaterThan(0));
          await page.close();
        } finally {
          await chrome.close();
        }
      } finally {
        await tmp.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('pdf() starts with %PDF', () async {
      final chrome = Chrome(executable: exe);
      try {
        final page = await chrome.open('$base/spa');
        final pdf = await page.pdf();
        expect(utf8.decode(pdf.sublist(0, 5)), '%PDF-');
        await page.close();
      } finally {
        await chrome.close();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('an attached pages() does not close the owner tabs on exit', () async {
      final owner = Chrome(executable: exe);
      try {
        final keep = <Page>[
          await owner.open('$base/spa'),
          await owner.open('$base/spa'),
          await owner.open('$base/spa'),
        ];
        final endpoint = (await owner.pages()).first.endpoint;
        final port = Uri.parse(endpoint).port;
        final before = (await owner.pages()).length;
        expect(before, greaterThanOrEqualTo(3));
        final tmp = await io.Directory.systemTemp.createTemp('tk_attach_');
        try {
          io.File('${tmp.path}/second.dart').writeAsStringSync(r'''
import 'package:dart_toolkit/chrome.dart';
Future<void> main(List<String> args) async {
  final chrome = Chrome(port: int.parse(args[0]));
  final pages = await chrome.pages();
  print('second script saw ${pages.length} pages');
  // Nudge the GC while alive, then exit without closing anything.
  var sink = 0;
  for (var i = 0; i < 500000; i++) {
    sink += '$i'.length;
  }
  await Future<void>.delayed(const Duration(milliseconds: 500));
  if (sink == -1) print('unreachable');
}
''');
          final res = await io.Process.run(io.Platform.executable, [
            '--packages=${io.Directory.current.path}/.dart_tool/package_config.json',
            '${tmp.path}/second.dart',
            '$port',
          ]);
          expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
        } finally {
          await tmp.delete(recursive: true);
        }
        expect((await owner.pages()).length, before);
        expect(keep.length, 3);
      } finally {
        await owner.close();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('automation marks stay hidden: navigator.webdriver is not true', () async {
      final chrome = Chrome(executable: exe);
      try {
        final page = await chrome.open('data:text/html,<title>x</title><p>hi</p>');
        expect(await page.eval('navigator.webdriver'), isNot(true));
        await page.close();
      } finally {
        await chrome.close();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('headless launch reports a Chrome user agent without HeadlessChrome', () async {
      final chrome = Chrome(executable: exe);
      try {
        final page = await chrome.open('data:text/html,<title>x</title><p>hi</p>');
        final ua = (await page.eval('navigator.userAgent')).toString();
        expect(ua, contains('Chrome/'));
        expect(ua, isNot(contains('HeadlessChrome')));
        await page.close();
      } finally {
        await chrome.close();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('a failing eval reports the thrown description, not raw exceptionDetails', () async {
      final chrome = Chrome(executable: exe);
      try {
        final page = await chrome.open('data:text/html,<title>x</title><p>hi</p>');
        await expectLater(
          page.eval('noSuchVariable_xyz'),
          throwsA(
            predicate(
              (e) => e.toString().contains('ReferenceError:') && !e.toString().contains('exceptionDetails'),
              'an error naming ReferenceError: without exceptionDetails',
            ),
          ),
        );
        await page.close();
      } finally {
        await chrome.close();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('a failed launch leaves no temp profile behind', () async {
      final before = await _tempProfiles();
      final chrome = Chrome(executable: '/nonexistent-chrome-xyz');
      await expectLater(chrome.open('$base/spa'), throwsA(isA<NativeException>()));
      final after = await _tempProfiles()
        ..removeAll(before);
      expect(after, isEmpty, reason: 'temp profiles left behind: $after');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the event loop stays free during navigate: a 5 ms timer keeps ticking', () async {
      final chrome = Chrome(executable: exe);
      try {
        final page = await chrome.open('$base/spa');
        var last = DateTime.now();
        var worst = Duration.zero;
        final tick = Timer.periodic(const Duration(milliseconds: 5), (_) {
          final now = DateTime.now();
          final gap = now.difference(last);
          last = now;
          if (gap > worst) worst = gap;
        });
        try {
          await page.navigate('$base/form');
          await page.wait('#go');
        } finally {
          tick.cancel();
        }
        expect(worst, lessThan(const Duration(milliseconds: 50)), reason: 'worst timer gap was $worst');
        await page.close();
      } finally {
        await chrome.close();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('closing a page fails its in-flight calls with StateError(closed)', () async {
      final chrome = Chrome(executable: exe);
      try {
        final page = await chrome.open('$base/spa');
        final waiting = page.wait('#never-appears', timeout: const Duration(seconds: 30));
        final check = expectLater(waiting, throwsA(isA<StateError>()));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await page.close();
        await check;
        await expectLater(page.navigate('$base/spa'), throwsA(isA<StateError>()));
      } finally {
        await chrome.close();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('close() leaves zero children and drops the temp profile', () async {
      final beforePids = await _chromePids();
      final beforeProfiles = await _tempProfiles();
      final chrome = Chrome(executable: exe);
      final page = await chrome.open('$base/spa');
      expect(await chrome.alive(), isTrue);
      await page.close();
      await chrome.close();
      expect(await chrome.alive(), isFalse);
      for (var i = 0; i < 150; i++) {
        final now = await _chromePids();
        now.removeAll(beforePids);
        if (now.isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final after = await _chromePids()
        ..removeAll(beforePids);
      expect(after, isEmpty, reason: 'orphaned browser processes: $after');
      final profiles = await _tempProfiles()
        ..removeAll(beforeProfiles);
      expect(profiles, isEmpty, reason: 'temp profiles left behind: $profiles');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
