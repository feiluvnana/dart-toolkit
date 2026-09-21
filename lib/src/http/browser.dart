part of '../../http.dart';

/// How far [BrowserClient] waits before it reads a page.
///
/// {@category Networking}
enum BrowserWait {
  /// The document and its subresources have loaded — the `load` event.
  load,

  /// `load`, and then half a second in which no request started or finished. What a page
  /// that fetches its content after loading needs.
  idle,
}

/// A [Client] that renders every page in Chrome and answers with the DOM as it stands
/// after the page's own scripts have run.
///
/// It speaks the DevTools protocol over a websocket — no third-party package, and no
/// Chromium download: [launch] finds the browser already installed, [attach] joins one
/// already running with `--remote-debugging-port`.
///
/// ```dart
/// final browser = await BrowserClient.launch();
/// await Http.session(client: browser, () async {
///   await for (final item in url.scrape<Item>().onResponse(parse).rights) print(item);
/// });
/// ```
///
/// Everything downstream is unchanged: the rendered HTML arrives as [Response.bytes], so
/// `res.html`, `$`, `$x` and the scrape engine's scope and dedupe work exactly as they do
/// over [IoClient]. What the page needs before it is worth reading is said per request,
/// with the keys below:
///
/// ```dart
/// .onRequest((ctx) {
///   ctx.request[BrowserClient.waitFor] = '.results .item';
///   ctx.request[BrowserClient.script] = 'window.scrollTo(0, document.body.scrollHeight)';
/// })
/// ```
///
/// Only a GET without a `range` is rendered. Everything else — a POST, a resumable
/// download, an asset — goes to the plain HTTP client underneath, carrying the browser's
/// cookies for the host, so a crawl that renders its pages still downloads its files at
/// the speed of a socket. [direct] forces one request down that path.
///
/// {@category Networking}
final class BrowserClient implements Client {
  /// Waits until a CSS selector matches before the page is read: `request[waitFor] = '.item'`.
  static const waitFor = RequestKey<String>('browser.wait-for');

  /// How long to wait before reading a page; [BrowserWait.load] unless the client was built
  /// with another default.
  static const waitUntil = RequestKey<BrowserWait>('browser.wait-until');

  /// JavaScript to run once the wait is over and before the DOM is read. It may evaluate to
  /// a promise — an `async` IIFE that scrolls and waits is the usual shape.
  static const script = RequestKey<String>('browser.script');

  /// Sends this request down the plain HTTP client instead of rendering it: `request[direct] = true`.
  static const direct = RequestKey<bool>('browser.direct');

  final WebSocket _socket;
  final Client _assets;
  final bool _ownsAssets;
  final Process? _process;
  final Directory? _profile;
  final Duration _timeout;
  final BrowserWait _wait;
  final String? _userAgent;
  final Semaphore _permits;
  final Queue<_Tab> _idle = Queue();
  final Map<int, Completer<Map<String, Object?>>> _calls = {};
  final Map<String, StreamController<_Cdp>> _sessions = {};
  final Set<_Tab> _open = {};

  var _nextId = 0;
  var _closed = false;

  BrowserClient._(
    this._socket, {
    required Client assets,
    required bool ownsAssets,
    required Duration timeout,
    required BrowserWait wait,
    required int tabs,
    required String? userAgent,
    Process? process,
    Directory? profile,
  }) : _assets = assets,
       _ownsAssets = ownsAssets,
       _timeout = timeout,
       _wait = wait,
       _userAgent = userAgent,
       _process = process,
       _profile = profile,
       _permits = Semaphore(tabs) {
    _socket.listen(_dispatch, onDone: _abort, onError: (Object _) => _abort());
  }

  /// Starts a headless Chrome of its own and connects to it.
  ///
  /// [executable] defaults to `CHROME_PATH` and then to the usual install locations of
  /// Chrome, Chromium and Edge. [tabs] is how many pages render at once — the crawl's
  /// `concurrency` is the engine's budget, this is the browser's. [wait] is the default
  /// for every request that does not carry [waitUntil]. [userAgent] overrides Chrome's
  /// own; without it a request's `user-agent` header is dropped, because a browser that
  /// announces itself as something else is a browser for no reason.
  ///
  /// [assets] answers everything that is not a page render, and is closed with this client
  /// unless it was supplied.
  static Future<BrowserClient> launch({
    String? executable,
    bool headless = true,
    int tabs = 4,
    Duration timeout = const Duration(seconds: 30),
    BrowserWait wait = BrowserWait.load,
    String? userAgent,
    Client? assets,
    List<String> args = const [],
  }) async {
    final binary = executable ?? _chrome();
    if (binary == null) {
      throw const ClientException('No Chrome found. Install Chrome or Chromium, set CHROME_PATH, or pass executable:.');
    }
    final profile = await Directory.systemTemp.createTemp('dart_toolkit_chrome_');
    final process = await Process.start(binary, [
      if (headless) '--headless=new',
      '--remote-debugging-port=0',
      '--user-data-dir=${profile.path}',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-networking',
      '--disable-backgrounding-occluded-windows',
      '--disable-renderer-backgrounding',
      '--disable-features=Translate,MediaRouter',
      '--hide-scrollbars',
      '--mute-audio',
      ...args,
      'about:blank',
    ]);
    try {
      final endpoint = await _activePort(profile, process, timeout);
      return BrowserClient._(
        await WebSocket.connect(endpoint.toString()),
        assets: assets ?? IoClient(),
        ownsAssets: assets == null,
        timeout: timeout,
        wait: wait,
        tabs: tabs,
        userAgent: userAgent,
        process: process,
        profile: profile,
      );
    } catch (_) {
      process.kill();
      await _erase(profile);
      rethrow;
    }
  }

  /// Connects to a Chrome already running with `--remote-debugging-port=<port>`.
  ///
  /// The browser outlives [close], which only lets go of it: the tabs this client opened
  /// are closed, nothing else is. See [launch] for the other arguments.
  static Future<BrowserClient> attach({
    int port = 9222,
    String host = '127.0.0.1',
    int tabs = 4,
    Duration timeout = const Duration(seconds: 30),
    BrowserWait wait = BrowserWait.load,
    String? userAgent,
    Client? assets,
  }) async {
    final probe = IoClient();
    final Uri endpoint;
    try {
      final res = await probe.send(Request('GET', Uri.parse('http://$host:$port/json/version'))).then((r) => r.read());
      if (!res.isOk) throw ClientException('DevTools answered ${res.statusCode}', res.url);
      final debugger = res.json['webSocketDebuggerUrl'].to<String>();
      if (debugger == null) throw ClientException('DevTools named no websocket endpoint', res.url);
      endpoint = Uri.parse(debugger);
    } finally {
      probe.close();
    }
    return BrowserClient._(
      await WebSocket.connect(endpoint.toString()),
      assets: assets ?? IoClient(),
      ownsAssets: assets == null,
      timeout: timeout,
      wait: wait,
      tabs: tabs,
      userAgent: userAgent,
    );
  }

  @override
  Future<StreamedResponse> send(Request request) async {
    if (_closed) throw ClientException('The browser client is closed', request.url);
    if (direct(request) == true || request.method != 'GET' || request.headers.containsKey('range')) {
      return _assets.send(await _withCookies(request));
    }
    final permit = await _permits.acquire();
    _Tab? tab;
    try {
      tab = _idle.isNotEmpty ? _idle.removeFirst() : await _open_();
      final rendered = await _render(tab, request);
      _idle.add(tab);
      tab = null;
      return rendered;
    } finally {
      if (tab != null) await _discard(tab);
      permit.release();
    }
  }

  /// Closes every tab this client opened, the connection, and — for [launch] — the browser.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final tab in _open.toList()) {
      try {
        await _call('Target.closeTarget', {'targetId': tab.target});
      } catch (_) {}
    }
    _open.clear();
    _idle.clear();
    await _socket.close().catchError((Object _) => null);
    _abort();
    if (_ownsAssets) await _assets.close();
    if (_process case final process?) {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => process.kill(ProcessSignal.sigkill) ? -9 : 0,
      );
    }
    if (_profile case final profile?) await _erase(profile);
  }

  // ---- rendering -------------------------------------------------------------------------

  Future<StreamedResponse> _render(_Tab tab, Request request) async {
    final url = request.url;
    final headers = {
      for (final MapEntry(:key, :value) in request.headers.entries)
        if (!_unsafe.contains(key.toLowerCase())) key: value,
    };
    await _call('Network.setExtraHTTPHeaders', {'headers': headers}, tab);

    Map<String, Object?>? document;
    var frame = '';
    final events = _sessions[tab.session]!.stream.listen((event) {
      if (event.method != 'Network.responseReceived') return;
      final params = event.params;
      if (params['type'] != 'Document') return;
      if (frame.isNotEmpty && params['frameId'] != frame) return;
      document = params['response'] as Map<String, Object?>?;
    });
    try {
      final nav = await _call('Page.navigate', {'url': '$url'}, tab);
      if (nav['errorText'] case final String error when error.isNotEmpty) {
        throw ClientException(_readable(error), url);
      }
      frame = nav['frameId'] as String? ?? '';

      await _waitForLoad(tab, waitUntil(request) ?? _wait);
      if (waitFor(request) case final selector?) await _waitForSelector(tab, selector, url);
      if (script(request) case final source?) await _evaluate(tab, source, awaitPromise: true);

      final mime = document?['mimeType'] as String? ?? 'text/html';
      final markup = mime.contains('html') || mime.contains('xml');
      final body = await _evaluate(
        tab,
        markup ? 'document.documentElement.outerHTML' : 'document.body ? document.body.innerText : ""',
      );
      final bytes = utf8.encode(body is String ? body : '$body');

      final answered = Headers();
      switch (document?['headers']) {
        case final Map<String, Object?> raw:
          raw.forEach((name, value) => answered[name] = '$value');
      }
      // The wire's length and encoding described the bytes before the page ran; these are
      // the bytes after it.
      answered
        ..remove('content-encoding')
        ..['content-length'] = '${bytes.length}'
        ..putIfAbsent('content-type', () => '$mime; charset=utf-8');
      return StreamedResponse(
        Stream.value(bytes),
        switch (document?['status']) {
          final int status => status,
          final num status => status.toInt(),
          _ => 200,
        },
        contentLength: bytes.length,
        headers: answered,
        request: request,
        url: switch (document?['url']) {
          final String answeredUrl => Uri.tryParse(answeredUrl) ?? url,
          _ => url,
        },
      );
    } finally {
      await events.cancel();
      await _call('Network.setExtraHTTPHeaders', {
        'headers': <String, String>{},
      }, tab).catchError((Object _) => <String, Object?>{});
    }
  }

  Future<void> _waitForLoad(_Tab tab, BrowserWait wait) async {
    final want = wait == BrowserWait.idle ? 'networkIdle' : 'load';
    final events = _sessions[tab.session]!.stream;
    await events
        .firstWhere((e) => e.method == 'Page.lifecycleEvent' && e.params['name'] == want)
        .timeout(
          _timeout,
          onTimeout: () => throw ClientException('Timed out waiting for $want', Uri.parse(tab.target)),
        );
  }

  Future<void> _waitForSelector(_Tab tab, String selector, Uri url) async {
    final quoted = jsonEncode(selector);
    final found = await _evaluate(tab, '''
new Promise((resolve) => {
  const hit = () => document.querySelector($quoted);
  if (hit()) return resolve(true);
  const observer = new MutationObserver(() => { if (hit()) { observer.disconnect(); resolve(true); } });
  observer.observe(document.documentElement, {childList: true, subtree: true});
})''', awaitPromise: true);
    if (found != true) throw ClientException('Timed out waiting for "$selector"', url);
  }

  Future<Object?> _evaluate(_Tab tab, String expression, {bool awaitPromise = false}) async {
    final result = await _call('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': awaitPromise,
    }, tab);
    if (result['exceptionDetails'] case final Map<String, Object?> thrown) {
      throw ClientException('Page script failed: ${thrown['text'] ?? thrown}');
    }
    return (result['result'] as Map<String, Object?>?)?['value'];
  }

  // ---- tabs ------------------------------------------------------------------------------

  Future<_Tab> _open_() async {
    final created = await _call('Target.createTarget', {'url': 'about:blank'});
    final target = created['targetId'] as String;
    final attached = await _call('Target.attachToTarget', {'targetId': target, 'flatten': true});
    final tab = _Tab(target, attached['sessionId'] as String);
    _sessions[tab.session] = StreamController<_Cdp>.broadcast();
    _open.add(tab);
    await _call('Page.enable', null, tab);
    await _call('Network.enable', null, tab);
    await _call('Page.setLifecycleEventsEnabled', {'enabled': true}, tab);
    if (_userAgent case final agent?) {
      await _call('Emulation.setUserAgentOverride', {'userAgent': agent}, tab);
    }
    return tab;
  }

  Future<void> _discard(_Tab tab) async {
    _open.remove(tab);
    await _sessions.remove(tab.session)?.close();
    try {
      await _call('Target.closeTarget', {'targetId': tab.target});
    } catch (_) {}
  }

  /// The browser's cookies for [request]'s URL, on a request the plain client will send.
  Future<Request> _withCookies(Request request) async {
    if (request.headers.containsKey('cookie')) return request;
    try {
      final all = await _call('Storage.getCookies');
      final jar = <String>[
        for (final cookie in (all['cookies'] as List? ?? const []).cast<Map<String, Object?>>())
          if (_sendsTo(cookie, request.url)) '${cookie['name']}=${cookie['value']}',
      ];
      if (jar.isNotEmpty) request.headers['cookie'] = jar.join('; ');
    } catch (_) {}
    return request;
  }

  static bool _sendsTo(Map<String, Object?> cookie, Uri url) {
    final domain = (cookie['domain'] as String? ?? '').toLowerCase();
    final host = url.host.toLowerCase();
    final match = domain.startsWith('.') ? host == domain.substring(1) || host.endsWith(domain) : host == domain;
    if (!match) return false;
    if (cookie['secure'] == true && url.scheme != 'https') return false;
    final path = cookie['path'] as String? ?? '/';
    return url.path.startsWith(path) || path == '/';
  }

  // ---- the protocol ----------------------------------------------------------------------

  Future<Map<String, Object?>> _call(String method, [Map<String, Object?>? params, _Tab? tab]) {
    if (_closed && method != 'Target.closeTarget') {
      throw ClientException('The browser client is closed');
    }
    final id = ++_nextId;
    final completer = Completer<Map<String, Object?>>();
    _calls[id] = completer;
    _socket.add(jsonEncode({'id': id, 'method': method, 'params': ?params, 'sessionId': ?tab?.session}));
    return completer.future.timeout(
      _timeout,
      onTimeout: () {
        _calls.remove(id);
        throw ClientException('$method timed out after ${_timeout.inSeconds}s');
      },
    );
  }

  void _dispatch(Object? frame) {
    final message = switch (jsonDecode(frame is String ? frame : utf8.decode((frame as List).cast<int>()))) {
      final Map<String, Object?> decoded => decoded,
      _ => <String, Object?>{},
    };
    if (message['id'] case final int id) {
      final completer = _calls.remove(id);
      if (completer == null || completer.isCompleted) return;
      if (message['error'] case final Map<String, Object?> error) {
        return completer.completeError(ClientException('${error['message'] ?? error}'));
      }
      return completer.complete((message['result'] as Map<String, Object?>?) ?? const {});
    }
    final session = _sessions[message['sessionId']];
    if (session == null || session.isClosed) return;
    session.add(_Cdp(message['method'] as String? ?? '', (message['params'] as Map<String, Object?>?) ?? const {}));
  }

  /// Fails every call still waiting; the socket will answer none of them.
  void _abort() {
    for (final completer in _calls.values.toList()) {
      if (!completer.isCompleted) completer.completeError(const ClientException('The browser disconnected'));
    }
    _calls.clear();
    for (final session in _sessions.values) {
      unawaited(session.close());
    }
    _sessions.clear();
  }
}

/// One page, and the DevTools session attached to it.
final class _Tab {
  final String target;
  final String session;

  const _Tab(this.target, this.session);
}

/// One event off the protocol socket.
final class _Cdp {
  final String method;
  final Map<String, Object?> params;

  const _Cdp(this.method, this.params);
}

/// Headers Chrome sets for itself; sending them from a request corrupts the render.
const _unsafe = {'host', 'connection', 'content-length', 'accept-encoding', 'user-agent', 'upgrade', 'keep-alive'};

const _chromes = [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '/usr/bin/google-chrome',
  '/usr/bin/google-chrome-stable',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
  '/snap/bin/chromium',
  r'C:\Program Files\Google\Chrome\Application\chrome.exe',
  r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
];

String? _chrome() {
  if (Platform.environment['CHROME_PATH'] case final path? when path.isNotEmpty) return path;
  for (final candidate in _chromes) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// Chrome writes the port it actually took, and the browser's websocket path, into the
/// profile directory as it starts.
Future<Uri> _activePort(Directory profile, Process process, Duration timeout) async {
  final file = File('${profile.path}/DevToolsActivePort');
  final deadline = DateTime.now().add(timeout);
  var exited = false;
  unawaited(process.exitCode.then((_) => exited = true));
  while (DateTime.now().isBefore(deadline)) {
    if (await file.exists()) {
      final lines = (await file.readAsString()).split('\n');
      if (lines.length >= 2 && lines[0].trim().isNotEmpty) {
        return Uri.parse('ws://127.0.0.1:${lines[0].trim()}${lines[1].trim()}');
      }
    }
    if (exited) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw ClientException(
    exited ? 'Chrome exited before it was ready' : 'Chrome did not start within ${timeout.inSeconds}s',
  );
}

Future<void> _erase(Directory directory) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } catch (_) {}
}

/// `net::ERR_NAME_NOT_RESOLVED` says the same thing with less shouting.
String _readable(String error) =>
    error.startsWith('net::') ? error.substring(5).toLowerCase().replaceAll('_', ' ') : error;
