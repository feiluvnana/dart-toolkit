import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

/// Launches or attaches to Chrome over the DevTools Protocol.
///
/// ```dart
/// final chrome = await Chrome.launch();
/// final page = await chrome.newPage();
/// await page.goto('https://example.com');
/// print(await page.title());
/// final shot = await page.screenshot();
/// await chrome.close();
/// ```
abstract final class Chrome {
  /// Launches a fresh Chrome and connects to it.
  static Future<Browser> launch({
    String? executable,
    bool headless = true,
    String? port,
    List<String> args = const [],
    bool visible = false,
  }) async {
    final exe = executable ?? _findChrome();
    if (exe == null) throw const ChromeException('No Chrome or Edge executable found');
    final userDataDir = await io.Directory.systemTemp.createTemp('tk_chrome_');
    final debugPort = port ?? '0';
    final process = await io.Process.start(exe, [
      if (headless) '--headless=new',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--remote-debugging-port=$debugPort',
      '--user-data-dir=${userDataDir.path}',
      ...args,
      'about:blank',
    ]);
    final resolvedPort = debugPort == '0' ? await _readActivePort(userDataDir.path) : debugPort;
    final browser = Browser('http://127.0.0.1:$resolvedPort', process: process, userDataDir: userDataDir);
    await browser._waitReady();
    return browser;
  }

  /// Attaches to an already-running Chrome with a debugging [port].
  static Future<Browser> connect({String port = '9222', String host = '127.0.0.1'}) async {
    final browser = Browser('http://$host:$port');
    await browser._waitReady();
    return browser;
  }

  static Future<String> _readActivePort(String dir) async {
    final file = io.File('$dir${io.Platform.pathSeparator}DevToolsActivePort');
    for (var i = 0; i < 100; i++) {
      if (await file.exists()) {
        final lines = await file.readAsLines();
        if (lines.isNotEmpty) return lines.first.trim();
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const ChromeException('Chrome did not report a DevTools port');
  }

  static String? _findChrome() {
    final env = io.Platform.environment;
    final candidates = <String>[
      if (env['CHROME_PATH'] != null) env['CHROME_PATH']!,
      if (io.Platform.isWindows) ...[
        '${env['ProgramFiles']}\\Google\\Chrome\\Application\\chrome.exe',
        '${env['ProgramFiles(x86)']}\\Google\\Chrome\\Application\\chrome.exe',
        '${env['LOCALAPPDATA']}\\Google\\Chrome\\Application\\chrome.exe',
        '${env['ProgramFiles(x86)']}\\Microsoft\\Edge\\Application\\msedge.exe',
      ],
      if (io.Platform.isMacOS) ...[
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
      ],
      if (io.Platform.isLinux) ...['/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser'],
    ];
    for (final c in candidates) {
      if (io.File(c).existsSync()) return c;
    }
    return null;
  }
}

/// A connected browser instance.
final class Browser {
  /// The DevTools HTTP endpoint, e.g. `http://127.0.0.1:9222`.
  final String endpoint;
  final io.Process? _process;
  final io.Directory? _userDataDir;

  Browser(this.endpoint, {io.Process? process, io.Directory? userDataDir})
    : _process = process,
      _userDataDir = userDataDir;

  Future<void> _waitReady() async {
    for (var i = 0; i < 100; i++) {
      try {
        final res = await _http('GET', '$endpoint/json/version');
        if (res.statusCode == 200) return;
      } on Object {
        // Chrome not up yet.
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const ChromeException('Chrome DevTools endpoint did not become ready');
  }

  /// Metadata about the browser.
  Future<Map<String, dynamic>> version() async {
    final res = await _http('GET', '$endpoint/json/version');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Opens a new tab and answers a connected [Page].
  Future<Page> newPage() async {
    final res = await _http('PUT', '$endpoint/json/new?about:blank');
    if (res.statusCode != 200) {
      final pages = await this.pages();
      if (pages.isNotEmpty) return pages.first;
      throw ChromeException('Could not open a new page (${res.statusCode})');
    }
    final info = jsonDecode(res.body) as Map<String, dynamic>;
    return Page._(info['webSocketDebuggerUrl'] as String, info['id'] as String);
  }

  /// The open pages.
  Future<List<Page>> pages() async {
    final res = await _http('GET', '$endpoint/json/list');
    final list = jsonDecode(res.body) as List<dynamic>;
    return [
      for (final item in list.cast<Map<String, dynamic>>())
        if (item['type'] == 'page' && item['webSocketDebuggerUrl'] != null)
          Page._(item['webSocketDebuggerUrl'] as String, item['id'] as String),
    ];
  }

  /// Closes the browser, terminating it if we launched it.
  Future<void> close() async {
    if (_process != null) {
      _process.kill();
      await _process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
      final dir = _userDataDir;
      if (dir != null) {
        await dir.delete(recursive: true).catchError((_) => dir);
      }
    }
  }
}

/// A single tab, driven over a DevTools websocket.
final class Page {
  final String _wsUrl;

  /// The target id.
  final String id;

  _Cdp? _cdp;

  Page._(this._wsUrl, this.id);

  Future<_Cdp> get _conn async => _cdp ??= await _Cdp.connect(_wsUrl);

  /// Sends a raw DevTools command.
  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) async =>
      (await _conn).send(method, params);

  /// Navigates to [url] and waits for the load event.
  Future<void> goto(String url, {Duration timeout = const Duration(seconds: 30)}) async {
    final cdp = await _conn;
    await cdp.send('Page.enable');
    final loaded = cdp.event('Page.loadEventFired').first;
    await cdp.send('Page.navigate', {'url': url});
    await loaded.timeout(timeout);
  }

  /// The page title.
  Future<String> title() async => (await eval('document.title')).toString();

  /// The full HTML of the document.
  Future<String> content() async => (await eval('document.documentElement.outerHTML')).toString();

  /// Evaluates [expression] and answers its value.
  Future<dynamic> eval(String expression) async {
    final result = await send('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    });
    final res = result['result'] as Map<String, dynamic>?;
    if (result['exceptionDetails'] != null) {
      throw ChromeException('Evaluation failed: ${result['exceptionDetails']}');
    }
    return res?['value'];
  }

  /// Clicks the first element matching [selector].
  Future<void> click(String selector) => eval('document.querySelector(${jsonEncode(selector)}).click()');

  /// Sets the value of the first input matching [selector] and fires `input`.
  Future<void> fill(String selector, String value) => eval(
    '(() => { const el = document.querySelector(${jsonEncode(selector)});'
    ' el.value = ${jsonEncode(value)};'
    " el.dispatchEvent(new Event('input', { bubbles: true })); })()",
  );

  /// Waits until [selector] matches or [timeout] elapses.
  Future<void> waitFor(String selector, {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final found = await eval('!!document.querySelector(${jsonEncode(selector)})');
      if (found == true) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw ChromeException('Timed out waiting for $selector');
  }

  /// Captures a PNG screenshot.
  Future<Uint8List> screenshot({bool fullPage = false}) async {
    final result = await send('Page.captureScreenshot', {'format': 'png', if (fullPage) 'captureBeyondViewport': true});
    return base64Decode(result['data'] as String);
  }

  /// Closes the tab.
  Future<void> close() async {
    await _cdp?.close();
    _cdp = null;
  }
}

final class _Cdp {
  final io.WebSocket _ws;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<Map<String, dynamic>> _events = StreamController.broadcast();
  int _nextId = 0;

  _Cdp(this._ws) {
    _ws.listen((raw) {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      final id = msg['id'];
      if (id is int && _pending.containsKey(id)) {
        final completer = _pending.remove(id)!;
        if (msg['error'] != null) {
          completer.completeError(ChromeException('CDP error: ${msg['error']}'));
        } else {
          completer.complete((msg['result'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{});
        }
      } else if (msg['method'] != null) {
        _events.add(msg);
      }
    });
  }

  static Future<_Cdp> connect(String url) async => _Cdp(await io.WebSocket.connect(url));

  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) {
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _ws.add(jsonEncode({'id': id, 'method': method, 'params': ?params}));
    return completer.future;
  }

  Stream<Map<String, dynamic>> event(String method) => _events.stream.where((e) => e['method'] == method);

  Future<void> close() => _ws.close();
}

final class _HttpResponse {
  final int statusCode;
  final String body;

  _HttpResponse(this.statusCode, this.body);
}

Future<_HttpResponse> _http(String method, String url) async {
  final client = io.HttpClient();
  try {
    final request = await client.openUrl(method, Uri.parse(url));
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    return _HttpResponse(response.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

/// Thrown when Chrome interaction fails.
final class ChromeException implements Exception {
  final String message;

  const ChromeException(this.message);

  @override
  String toString() => 'ChromeException: $message';
}
