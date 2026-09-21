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
/// **A page is never lost.** A wait that expires, an interstitial that never clears, a
/// challenge a human has to click: none of them throw and none of them close the tab. The
/// DOM as it stands comes back with the status the server gave it, and [open] hands the
/// same tab over for a human or a script to carry on with:
///
/// ```dart
/// final page = await browser.open('https://example.com/login'.url);
/// await page.fill('#user', 'me');
/// await page.click('button[type=submit]');
/// await page.waitFor('.dashboard');
/// print((await page.html()).$('.balance').text);     // read it whenever you like
/// await page.close();
/// ```
///
/// {@category Networking}
final class BrowserClient implements Client {
  /// Waits until a CSS selector matches before the page is read: `request[waitFor] = '.item'`.
  ///
  /// A selector that never matches is not an error — the page comes back as it stands.
  static const waitFor = RequestKey<String>('browser.wait-for');

  /// How long to wait before reading a page; [BrowserWait.load] unless the client was built
  /// with another default.
  static const waitUntil = RequestKey<BrowserWait>('browser.wait-until');

  /// JavaScript to run once the wait is over and before the DOM is read. It may evaluate to
  /// a promise — an `async` IIFE that scrolls and waits is the usual shape.
  static const script = RequestKey<String>('browser.script');

  /// Sends this request down the plain HTTP client instead of rendering it: `request[direct] = true`.
  static const direct = RequestKey<bool>('browser.direct');

  /// How long this request may sit on an interstitial, overriding the client's `challenge:`.
  static const challenge = RequestKey<Duration>('browser.challenge');

  final WebSocket _socket;
  final Client _assets;
  final bool _ownsAssets;
  final Process? _process;
  final Directory? _profile;
  final Duration _timeout;
  final Duration _challenge;
  final BrowserWait _wait;
  final String? _userAgent;
  final Semaphore _permits;
  final Queue<BrowserPage> _free = Queue();
  final Set<BrowserPage> _pages = {};
  final Map<int, Completer<Map<String, Object?>>> _calls = {};
  final Map<String, StreamController<_Cdp>> _sessions = {};

  var _nextId = 0;
  var _closed = false;

  BrowserClient._(
    this._socket, {
    required Client assets,
    required bool ownsAssets,
    required Duration timeout,
    required Duration challenge,
    required BrowserWait wait,
    required int tabs,
    required String? userAgent,
    Process? process,
    Directory? profile,
  }) : _assets = assets,
       _ownsAssets = ownsAssets,
       _timeout = timeout,
       _challenge = challenge,
       _wait = wait,
       _userAgent = userAgent,
       _process = process,
       _profile = profile,
       _permits = Semaphore(tabs) {
    _socket.listen(_dispatch, onDone: _abort, onError: (Object _) => _abort());
  }

  /// Whether this client has been closed.
  bool get isClosed => _closed;

  /// Starts a headless Chrome of its own and connects to it.
  ///
  /// [executable] defaults to `CHROME_PATH` and then to the usual install locations of
  /// Chrome, Chromium and Edge. [tabs] is how many pages render at once — the crawl's
  /// `concurrency` is the engine's budget, this is the browser's. [wait] is the default
  /// for every request that does not carry [waitUntil]. [userAgent] overrides Chrome's
  /// own; without it a request's `user-agent` header is dropped, because a browser that
  /// announces itself as something else is a browser for no reason.
  ///
  /// [challenge] is how long a page that answers with an interstitial — Cloudflare's "just
  /// a moment", a 503 that reloads itself — is given to become the real page before it is
  /// handed back as it is. Nothing throws when it does not: the interstitial is the
  /// response. With `headless: false` that wait is also a human's chance to click the box,
  /// and [open] takes the tab over for one.
  ///
  /// [assets] answers everything that is not a page render, and is closed with this client
  /// unless it was supplied.
  static Future<BrowserClient> launch({
    String? executable,
    bool headless = true,
    int tabs = 4,
    Duration timeout = const Duration(seconds: 30),
    Duration challenge = const Duration(seconds: 20),
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
        challenge: challenge,
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
  /// are closed, nothing else is. This is the client for a site that already knows the
  /// person running the program — their profile, their cookies, their logged-in session.
  /// See [launch] for the other arguments.
  static Future<BrowserClient> attach({
    int port = 9222,
    String host = '127.0.0.1',
    int tabs = 4,
    Duration timeout = const Duration(seconds: 30),
    Duration challenge = const Duration(seconds: 20),
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
      challenge: challenge,
      wait: wait,
      tabs: tabs,
      userAgent: userAgent,
    );
  }

  /// A tab of its own, for a page that is worked rather than fetched.
  ///
  /// The caller owns it until [BrowserPage.close]; it is outside the pool [send] draws on,
  /// so holding one open — while a human solves a captcha, while a script clicks through a
  /// form — never starves a crawl. [url] is navigated to when given.
  Future<BrowserPage> open([Uri? url, BrowserWait? until]) async {
    final page = await _tab();
    if (url != null) await page.goto(url, until: until);
    return page;
  }

  /// [open], then [action], then closes the tab whatever [action] did.
  Future<T> page<T>(Uri url, FutureOr<T> Function(BrowserPage page) action, {BrowserWait? until}) async {
    final page = await open(url, until);
    try {
      return await action(page);
    } finally {
      await page.close();
    }
  }

  @override
  Future<StreamedResponse> send(Request request) async {
    if (_closed) throw ClientException('The browser client is closed', request.url);
    if (direct(request) == true || request.method != 'GET' || request.headers.containsKey('range')) {
      return _assets.send(await _withCookies(request));
    }
    final permit = await _permits.acquire();
    BrowserPage? page;
    try {
      page = _free.isNotEmpty ? _free.removeFirst() : await _tab();
      await page.headers({
        for (final MapEntry(:key, :value) in request.headers.entries)
          if (!_unsafe.contains(key.toLowerCase())) key: value,
      });
      final res = await page.goto(
        request.url,
        until: waitUntil(request) ?? _wait,
        challenge: challenge(request) ?? _challenge,
        request: request,
      );
      // Both directives may be set, and both change what the DOM says, so the page is read
      // again only after the last of them has run.
      var moved = false;
      if (waitFor(request) case final selector?) {
        await page.waitFor(selector);
        moved = true;
      }
      if (script(request) case final source?) {
        await page.eval(source, awaitPromise: true);
        moved = true;
      }
      return _streamed(moved ? await page.response(request) : res, request);
    } finally {
      // A tab is returned to the pool however the render went: the page it holds may be a
      // challenge someone is in the middle of solving, and closing it would throw that away.
      if (page != null) {
        if (page._alive && !_closed) {
          _free.add(page);
        } else {
          await page.close();
        }
      }
      permit.release();
    }
  }

  StreamedResponse _streamed(Response res, Request request) => StreamedResponse(
    Stream.value(res.bytes),
    res.statusCode,
    contentLength: res.bytes.length,
    headers: res.headers,
    request: request,
    url: res.url,
  );

  /// Closes every tab this client opened, the connection, and — for [launch] — the browser.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final page in _pages.toList()) {
      await page.close();
    }
    _pages.clear();
    _free.clear();
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

  // ---- tabs ------------------------------------------------------------------------------

  Future<BrowserPage> _tab() async {
    final created = await _call('Target.createTarget', {'url': 'about:blank'});
    final attached = await _call('Target.attachToTarget', {'targetId': created['targetId'] as String, 'flatten': true});
    final tab = _Tab(created['targetId'] as String, attached['sessionId'] as String);
    _sessions[tab.session] = StreamController<_Cdp>.broadcast();
    final page = BrowserPage._(this, tab);
    _pages.add(page);
    await _call('Page.enable', null, tab);
    await _call('Network.enable', null, tab);
    await _call('Page.setLifecycleEventsEnabled', {'enabled': true}, tab);
    if (_userAgent case final agent?) {
      await _call('Emulation.setUserAgentOverride', {'userAgent': agent}, tab);
    }
    page._listen();
    final tree = await _call('Page.getFrameTree', null, tab);
    page._frame = switch (tree['frameTree']) {
      final Map<String, Object?> root => (root['frame'] as Map<String, Object?>?)?['id'] as String? ?? '',
      _ => '',
    };
    return page;
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

  Future<Map<String, Object?>> _call(String method, [Map<String, Object?>? params, _Tab? tab, Duration? timeout]) {
    if (_closed && method != 'Target.closeTarget') throw ClientException('The browser client is closed');
    final id = ++_nextId;
    final completer = Completer<Map<String, Object?>>();
    _calls[id] = completer;
    _socket.add(jsonEncode({'id': id, 'method': method, 'params': ?params, 'sessionId': ?tab?.session}));
    final limit = timeout ?? _timeout;
    return completer.future.timeout(
      limit,
      onTimeout: () {
        _calls.remove(id);
        throw ClientException('$method timed out after ${limit.inSeconds}s');
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

/// One tab, open for as long as the work takes.
///
/// A page is what [BrowserClient.open] hands over and what [BrowserClient.send] drives
/// underneath. Its reads never throw on an empty result and its waits never throw on time:
/// [waitFor] answers `false`, [response] answers whatever the DOM says now. What is on the
/// screen is always available, which is the property an interstitial needs.
///
/// {@category Networking}
final class BrowserPage {
  final BrowserClient _client;
  final _Tab _tab;

  StreamSubscription<_Cdp>? _events;
  Map<String, Object?>? _document;
  Completer<void>? _waiter;
  String _want = '';
  String _frame = '';
  Uri _url = Uri.parse('about:blank');
  bool _alive = true;

  BrowserPage._(this._client, this._tab);

  /// The URL this tab is on, after every redirect and navigation it has made.
  Uri get url => _url;

  /// Whether the tab is still open.
  bool get isOpen => _alive;

  /// The status of the last document this tab loaded, or `null` before the first.
  int? get statusCode => switch (_document?['status']) {
    final int status => status,
    final num status => status.toInt(),
    _ => null,
  };

  /// Navigates, waits, and answers with the page as it stands afterwards.
  ///
  /// A navigation that Chrome refuses outright — a name that does not resolve, a refused
  /// connection — throws [ClientException]. Everything softer than that is a response: a
  /// wait that expires, an interstitial that never clears, a 403 challenge page.
  /// [challenge] is how long to let an interstitial become the real page; see
  /// [BrowserClient.launch].
  Future<Response> goto(Uri url, {BrowserWait? until, Duration? challenge, Request? request}) async {
    final wait = until ?? _client._wait;
    _arm(wait == BrowserWait.idle ? 'networkIdle' : 'load');
    final nav = await _call('Page.navigate', {'url': '$url'});
    if (nav['errorText'] case final String error when error.isNotEmpty) {
      _disarm();
      throw ClientException(_readable(error), url);
    }
    if (nav['frameId'] case final String frame when frame.isNotEmpty) _frame = frame;
    _url = url;
    await _settle();

    final patience = challenge ?? _client._challenge;
    var res = await response(request);
    if (patience <= Duration.zero || !_interstitial(res)) return res;
    // The page is a challenge: Cloudflare's reload, a 503 that comes back, a box for a
    // human to click. None of that is a failure, and the tab stays open for it.
    final deadline = DateTime.now().add(patience);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!_alive) break;
      res = await response(request);
      if (!_interstitial(res)) return res;
    }
    return res;
  }

  /// The page as it stands now: the DOM its scripts have built, under the status and headers
  /// the server answered the document with.
  ///
  /// Callable whenever — mid-challenge, mid-form, after a click — and never throws for a
  /// page that has not finished.
  Future<Response> response([Request? request]) async {
    final mime = _document?['mimeType'] as String? ?? 'text/html';
    final markup = mime.contains('html') || mime.contains('xml');
    final body = await eval(
      markup
          ? 'document.documentElement ? document.documentElement.outerHTML : ""'
          : 'document.body ? document.body.innerText : ""',
    );
    final bytes = utf8.encode(body is String ? body : '${body ?? ''}');
    final headers = Headers();
    switch (_document?['headers']) {
      case final Map<String, Object?> raw:
        raw.forEach((name, value) => headers[name] = '$value');
    }
    // The wire's length and encoding described the bytes before the page ran; these are the
    // bytes after it.
    headers
      ..remove('content-encoding')
      ..['content-length'] = '${bytes.length}'
      ..putIfAbsent('content-type', () => '$mime; charset=utf-8');
    return Response.bytes(
      bytes,
      statusCode ?? 200,
      headers: headers,
      request: request,
      url: switch (_document?['url']) {
        final String answered => Uri.tryParse(answered) ?? _url,
        _ => _url,
      },
    );
  }

  /// The page as a parsed document; `(await page.response()).html` without the parentheses.
  Future<HtmlDocument> html() async => (await response()).html;

  /// Waits until [selector] matches, and answers whether it did before [timeout].
  ///
  /// The wait ends the moment the element appears — a mutation observer, not a poll — and
  /// expiring is an answer, not an exception.
  Future<bool> waitFor(String selector, {Duration? timeout}) => _watch(selector, timeout: timeout, gone: false);

  /// Waits until [selector] matches nothing — a spinner going away, a challenge clearing —
  /// and answers whether it did before [timeout].
  Future<bool> waitWhile(String selector, {Duration? timeout}) => _watch(selector, timeout: timeout, gone: true);

  Future<bool> _watch(String selector, {required bool gone, Duration? timeout}) async {
    final limit = timeout ?? _client._timeout;
    final quoted = jsonEncode(selector);
    final hit = gone ? '!document.querySelector($quoted)' : '!!document.querySelector($quoted)';
    final found = await eval(
      '''
new Promise((resolve) => {
  const hit = () => $hit;
  if (hit()) return resolve(true);
  const observer = new MutationObserver(() => { if (hit()) { observer.disconnect(); resolve(true); } });
  observer.observe(document.documentElement, {childList: true, subtree: true, attributes: true});
  setTimeout(() => { observer.disconnect(); resolve(false); }, ${limit.inMilliseconds});
})''',
      awaitPromise: true,
      timeout: limit + const Duration(seconds: 5),
    );
    return found == true;
  }

  /// Clicks the first element [selector] matches, as a mouse would.
  ///
  /// The element is scrolled into view and the click lands at its centre with real mouse
  /// events; an element with no box on screen is clicked through the DOM instead. Answers
  /// `false` when nothing matched.
  Future<bool> click(String selector) async {
    final node = await _node(selector);
    if (node == null) return false;
    try {
      await _call('DOM.scrollIntoViewIfNeeded', {'nodeId': node});
      final box = await _call('DOM.getBoxModel', {'nodeId': node});
      final quad = ((box['model'] as Map<String, Object?>?)?['content'] as List?)?.cast<num>();
      if (quad == null || quad.length < 6) throw const ClientException('no box');
      final x = (quad[0] + quad[4]) / 2;
      final y = (quad[1] + quad[5]) / 2;
      await _call('Input.dispatchMouseEvent', {'type': 'mouseMoved', 'x': x, 'y': y});
      for (final type in ['mousePressed', 'mouseReleased']) {
        await _call('Input.dispatchMouseEvent', {
          'type': type,
          'x': x,
          'y': y,
          'button': 'left',
          'buttons': 1,
          'clickCount': 1,
        });
      }
      return true;
    } catch (_) {
      // Off-screen, zero-sized, or covered: the DOM's own click still runs the handler.
      return await eval('''(() => {
  const el = document.querySelector(${jsonEncode(selector)});
  if (!el) return false;
  el.click();
  return true;
})()''') ==
          true;
    }
  }

  /// Focuses the first element [selector] matches and types [value] into it.
  ///
  /// Answers `false` when nothing matched. The text arrives as text, not as a key at a
  /// time, so a field that listens for `input` sees it and one that listens for `keydown`
  /// may not — [press] is there for the second kind.
  Future<bool> fill(String selector, String value) async {
    final node = await _node(selector);
    if (node == null) return false;
    await _call('DOM.focus', {'nodeId': node});
    await eval('''(() => {
  const el = document.querySelector(${jsonEncode(selector)});
  if (el && 'value' in el) el.value = '';
})()''');
    await _call('Input.insertText', {'text': value});
    return true;
  }

  /// Presses a key on whatever has focus: `Enter`, `Tab`, `Escape`, `ArrowDown`, or a
  /// single character.
  Future<void> press(String key) async {
    final (code, text) = switch (key) {
      'Enter' => (13, '\r'),
      'Tab' => (9, '\t'),
      'Escape' => (27, null),
      'Backspace' => (8, null),
      'ArrowUp' => (38, null),
      'ArrowDown' => (40, null),
      'ArrowLeft' => (37, null),
      'ArrowRight' => (39, null),
      _ => (key.codeUnitAt(0), key),
    };
    for (final type in ['keyDown', 'keyUp']) {
      await _call('Input.dispatchKeyEvent', {
        'type': type == 'keyDown' && text != null ? 'keyDown' : type,
        'key': key,
        'windowsVirtualKeyCode': code,
        'nativeVirtualKeyCode': code,
        if (type == 'keyDown' && text != null) 'text': text,
      });
    }
  }

  /// Scrolls to the bottom [times] times, waiting [settle] after each — an infinite feed,
  /// loaded. Answers the page height when it stopped growing.
  Future<num> scroll({int times = 3, Duration settle = const Duration(milliseconds: 500)}) async {
    num height = 0;
    for (var i = 0; i < times; i++) {
      final grown = await eval(
        '''(async () => {
  const before = document.body ? document.body.scrollHeight : 0;
  window.scrollTo(0, before);
  await new Promise((r) => setTimeout(r, ${settle.inMilliseconds}));
  return document.body ? document.body.scrollHeight : 0;
})()''',
        awaitPromise: true,
        timeout: settle + const Duration(seconds: 10),
      );
      final now = grown is num ? grown : 0;
      if (now == height) break;
      height = now;
    }
    return height;
  }

  /// Runs [expression] in the page and answers what it evaluated to, as JSON-able Dart.
  ///
  /// With [awaitPromise], a promise is waited for — an `async` IIFE is the usual shape.
  /// A script that throws throws [ClientException] naming what it said.
  Future<Object?> eval(String expression, {bool awaitPromise = false, Duration? timeout}) async {
    final result = await _call('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': awaitPromise,
    }, timeout);
    if (result['exceptionDetails'] case final Map<String, Object?> thrown) {
      throw ClientException('Page script failed: ${thrown['text'] ?? thrown}');
    }
    return (result['result'] as Map<String, Object?>?)?['value'];
  }

  /// A PNG of the visible page — what the person in front of the window would see, for a
  /// log, a report, or a look at the challenge that will not clear.
  Future<Uint8List> screenshot() async {
    final shot = await _call('Page.captureScreenshot', {'format': 'png'});
    return base64.decode(shot['data'] as String? ?? '');
  }

  /// Sets headers sent with every request this tab makes from now on.
  Future<void> headers(Map<String, String> headers) => _call('Network.setExtraHTTPHeaders', {'headers': headers});

  /// Closes the tab. Safe twice.
  Future<void> close() async {
    if (!_alive) return;
    _alive = false;
    _client._pages.remove(this);
    _client._free.remove(this);
    await _events?.cancel();
    await _client._sessions.remove(_tab.session)?.close();
    try {
      await _client._call('Target.closeTarget', {'targetId': _tab.target});
    } catch (_) {}
  }

  // ---- internals -------------------------------------------------------------------------

  Future<Map<String, Object?>> _call(String method, [Map<String, Object?>? params, Duration? timeout]) {
    if (!_alive) throw ClientException('The page is closed', _url);
    return _client._call(method, params, _tab, timeout);
  }

  Future<int?> _node(String selector) async {
    try {
      final doc = await _call('DOM.getDocument', {'depth': 0});
      final root = (doc['root'] as Map<String, Object?>?)?['nodeId'];
      final found = await _call('DOM.querySelector', {'nodeId': root, 'selector': selector});
      final node = found['nodeId'] as int? ?? 0;
      return node == 0 ? null : node;
    } catch (_) {
      return null;
    }
  }

  void _listen() {
    _events = _client._sessions[_tab.session]?.stream.listen((event) {
      switch (event.method) {
        case 'Network.responseReceived':
          final params = event.params;
          if (params['type'] != 'Document') return;
          // A challenge renders inside an iframe; only the main frame is this page.
          if (_frame.isNotEmpty && params['frameId'] != _frame) return;
          _document = params['response'] as Map<String, Object?>?;
        case 'Page.frameNavigated':
          final frame = event.params['frame'] as Map<String, Object?>?;
          if (frame == null || (_frame.isNotEmpty && frame['id'] != _frame)) return;
          if (frame['url'] case final String moved) _url = Uri.tryParse(moved) ?? _url;
        case 'Page.lifecycleEvent':
          if (event.params['name'] != _want) return;
          final waiter = _waiter;
          if (waiter != null && !waiter.isCompleted) waiter.complete();
      }
    });
  }

  /// Arms the lifecycle wait *before* navigating, so a page that loads faster than the call
  /// returns is not waited for forever.
  void _arm(String event) {
    _want = event;
    _waiter = Completer<void>();
  }

  void _disarm() {
    _want = '';
    _waiter = null;
  }

  /// Waits for the armed lifecycle event, and gives up quietly: a page that never fires
  /// `load` still has a DOM worth reading.
  Future<void> _settle() async {
    final waiter = _waiter;
    if (waiter == null) return;
    try {
      // The field is what the listener completes, so it stays set until the wait is over.
      await waiter.future.timeout(_client._timeout, onTimeout: () {});
    } finally {
      if (identical(_waiter, waiter)) _disarm();
    }
  }

  /// Whether this looks like an interstitial rather than the page that was asked for.
  bool _interstitial(Response res) {
    final status = res.statusCode;
    if (status != 403 && status != 503 && status != 429) return false;
    final body = res.text;
    return body.length < 80000 &&
        (body.contains('cf-browser-verification') ||
            body.contains('challenge-form') ||
            body.contains('__cf_chl') ||
            body.contains('cf-turnstile') ||
            body.contains('Just a moment') ||
            body.contains('Checking your browser'));
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
