// Phase D exit gate (reports/roadmap.md + browser_chrome.md §4.3): the native
// CDP engine behind the `lib2` surface, against a real browser.
//
// open → wait → html() on a local SPA fixture; type + click drive a form;
// shot() pipes to a File Image decodes; pdf() starts with %PDF; close()
// leaves zero Chrome children and drops the temp profile. Without the browser
// executable or the `dart_toolkit_chrome` cdylib the tests skip with a reason
// instead of failing.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/core.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/image.dart';
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

/// Throws a skip unless the native engine and a browser are both here.
String _requireChrome() {
  if (!Lib2Chrome.isAvailable) markTestSkipped('dart_toolkit_chrome not built: ${Lib2Chrome.reason}');
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
  group('native seam', () {
    test('reports loaded or a reason', () {
      if (Lib2Chrome.isAvailable) {
        expect(Lib2Chrome.reason, isNull);
      } else {
        expect(Lib2Chrome.reason, isNotNull);
      }
    });
  });

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
      final chrome = await Chrome.launch(executable: exe);
      try {
        expect(await chrome.alive, isTrue);
        final page = await chrome.open('$base/spa');
        await page.wait('.product-card');
        final markup = await page.html();
        expect(markup, contains('Gadget'));
        final doc = Html.parse(markup);
        expect(doc.all('.product-card'), hasLength(2));
        await page.close();
      } finally {
        await chrome.close();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('type + click drive the form', () async {
      final chrome = await Chrome.launch(executable: exe);
      try {
        final page = await chrome.open('$base/form');
        await page.type('#name', 'ada');
        await page.click('#go');
        await page.wait('.greeting');
        expect(await page.html(), contains('hello ada'));
        await page.close();
      } finally {
        await chrome.close();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('shot() pipes to a File Image decodes', () async {
      final tmp = await io.Directory.systemTemp.createTemp('lib2_phased_shot_');
      try {
        final chrome = await Chrome.launch(executable: exe);
        try {
          final page = await chrome.open('$base/spa');
          await page.wait('.product-card');
          final png = await page.shot();
          expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
          final path = '${tmp.path}/shot.png';
          await page.shot().pipe(File(path));
          final back = await Image.decode(await io.File(path).readAsBytes());
          expect(back.width, greaterThan(0));
          expect(back.height, greaterThan(0));
          await page.close();
        } finally {
          await chrome.close();
        }
      } finally {
        await tmp.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('pdf() starts with %PDF', () async {
      final chrome = await Chrome.launch(executable: exe);
      try {
        final page = await chrome.open('$base/spa');
        final pdf = await page.pdf();
        expect(utf8.decode(pdf.sublist(0, 5)), '%PDF-');
        await page.close();
      } finally {
        await chrome.close();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('close() leaves zero children and drops the temp profile', () async {
      final beforePids = await _chromePids();
      final beforeProfiles = await _tempProfiles();
      final chrome = await Chrome.launch(executable: exe);
      final page = await chrome.open('$base/spa');
      expect(await chrome.alive, isTrue);
      await page.close();
      await chrome.close();
      expect(await chrome.alive, isFalse);
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
