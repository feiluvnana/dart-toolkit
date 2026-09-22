part of '../../http.dart';

/// How far [ChromeClient] waits before it reads a page.
///
/// {@category Networking}
enum ChromeWait {
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
/// final browser = await ChromeClient.launch();
/// await Http.scope(client: browser, () async {
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
///   ctx.request[ChromeClient.waitFor] = '.results .item';
///   ctx.request[ChromeClient.script] = 'window.scrollTo(0, document.body.scrollHeight)';
/// })
/// ```
///
/// Only a GET without a `range` is rendered. Everything else — a POST, a resumable
/// download, an asset — goes to the plain HTTP client underneath, carrying the browser's
/// cookies for the host, so a crawl that renders its pages still downloads its files at
/// the speed of a socket. [Request.raw] forces one request down that path, and every download
/// sets it, so a file downloaded through this client is the file and not a rendering of it.
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
final class ChromeClient implements Client {
  /// Waits until a CSS selector matches before the page is read: `request[waitFor] = '.item'`.
  ///
  /// A selector that never matches is not an error — the page comes back as it stands.
  static const waitFor = RequestKey<String>('chrome.wait-for');

  /// How long to wait before reading a page; [ChromeWait.load] unless the client was built
  /// with another default.
  static const waitUntil = RequestKey<ChromeWait>('chrome.wait-until');

  /// JavaScript to run once the wait is over and before the DOM is read. It may evaluate to
  /// a promise — an `async` IIFE that scrolls and waits is the usual shape.
  static const script = RequestKey<String>('chrome.script');

  /// How long this request may sit on an interstitial, overriding the client's `challenge:`.
  static const challenge = RequestKey<Duration>('chrome.challenge');

  final WebSocket _socket;
  final Client _assets;
  final bool _ownsAssets;
  final Process? _process;
  final Directory? _profile;
  final Duration _timeout;
  final Duration _challenge;
  final ChromeWait _wait;
  final String? _userAgent;
  final Semaphore _permits;
  final Queue<ChromePage> _free = Queue();
  final Set<ChromePage> _pages = {};
  final Map<int, Completer<Map<String, Object?>>> _calls = {};
  final Map<String, StreamController<_Cdp>> _sessions = {};

  var _nextId = 0;
  var _closed = false;
  String? _agent;

  ChromeClient._(
    this._socket, {
    required Client assets,
    required bool ownsAssets,
    required Duration timeout,
    required Duration challenge,
    required ChromeWait wait,
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
  static Future<ChromeClient> launch({
    String? executable,
    bool headless = true,
    int tabs = 4,
    Duration timeout = const Duration(seconds: 30),
    Duration challenge = const Duration(seconds: 20),
    ChromeWait wait = ChromeWait.load,
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
      return ChromeClient._(
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
  static Future<ChromeClient> attach({
    int port = 9222,
    String host = '127.0.0.1',
    int tabs = 4,
    Duration timeout = const Duration(seconds: 30),
    Duration challenge = const Duration(seconds: 20),
    ChromeWait wait = ChromeWait.load,
    String? userAgent,
    Client? assets,
  }) async {
    final endpoint = await _devtools(host, port);
    if (endpoint == null) {
      throw ClientException('No Chrome is listening on $host:$port. ${_howToStart(port)}');
    }
    return ChromeClient._(
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

  /// Attaches to the Chrome on [port], and starts one that outlives this program if there
  /// is none — the client for a script that is run again and again.
  ///
  /// [launch] is a fresh browser every time: a temporary profile, no cookies, and the
  /// process dies with the client. That is right for a crawl and wrong for everything that
  /// depends on *being someone* — a site behind a login, a session a human authenticated
  /// once by hand. This keeps one browser and one profile across runs instead:
  ///
  /// ```dart
  /// final chrome = await ChromeClient.connect();   // run 1: starts Chrome, logs in by hand
  /// await Http.scope(client: chrome, () async { … });
  /// await chrome.close();                          // the browser stays up
  /// ```
  ///
  /// The second run finds that Chrome on the port and attaches to it in milliseconds, with
  /// the cookies and the logged-in session still there. [close] never kills it, whichever
  /// run started it; the person owns the browser, and quits it when they are done with it.
  ///
  /// [profile] is the user-data directory that makes it the same browser next time,
  /// `~/.dart_toolkit/chrome` unless another is named. Because that profile persists, this
  /// is [headless]-`false` by default: a browser you can see is one you can log into.
  ///
  /// A Chrome already running on [port] is attached to as it is — [profile], [headless],
  /// [executable] and [args] describe how to *start* one and are ignored when none is needed.
  static Future<ChromeClient> connect({
    int port = 9222,
    String host = '127.0.0.1',
    String? executable,
    Path? profile,
    bool headless = false,
    int tabs = 4,
    Duration timeout = const Duration(seconds: 30),
    Duration challenge = const Duration(seconds: 20),
    ChromeWait wait = ChromeWait.load,
    String? userAgent,
    Client? assets,
    List<String> args = const [],
  }) async {
    var endpoint = await _devtools(host, port);
    if (endpoint == null) {
      final binary = executable ?? _chrome();
      if (binary == null) {
        throw const ClientException(
          'No Chrome found. Install Chrome or Chromium, set CHROME_PATH, or pass executable:.',
        );
      }
      final dir = profile ?? Path.home / '.dart_toolkit' / 'chrome';
      await Directory(dir).create(recursive: true);
      // Detached: the browser is meant to outlive this program, so it must not be a child
      // that dies with it. Nothing is read from its stdio, and the port is the handle.
      await Process.start(binary, [
        if (headless) '--headless=new',
        '--remote-debugging-port=$port',
        '--user-data-dir=$dir',
        '--no-first-run',
        '--no-default-browser-check',
        ...args,
        'about:blank',
      ], mode: ProcessStartMode.detached);
      // The port is polled rather than `DevToolsActivePort` read: the file is stale from the
      // last run until Chrome rewrites it, and here the port is known because it was given.
      final deadline = DateTime.now().add(timeout);
      while (endpoint == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        endpoint = await _devtools(host, port);
      }
      if (endpoint == null) {
        throw ClientException('Chrome did not open a debugging port on $host:$port within ${timeout.inSeconds}s');
      }
    }
    return ChromeClient._(
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
  /// The caller owns it until [ChromePage.close]; it is outside the pool [send] draws on,
  /// so holding one open — while a human solves a captcha, while a script clicks through a
  /// form — never starves a crawl. [url] is navigated to when given.
  Future<ChromePage> open([Uri? url, ChromeWait? until]) async {
    final page = await _tab();
    if (url != null) await page.goto(url, until: until);
    return page;
  }

  /// [open], then [action], then closes the tab whatever [action] did.
  Future<T> page<T>(Uri url, FutureOr<T> Function(ChromePage page) action, {ChromeWait? until}) async {
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
    if (Request.raw(request) == true || request.method != 'GET' || request.headers.containsKey('range')) {
      return _assets.send(await _withCookies(request));
    }
    final permit = await _permits.acquire();
    ChromePage? page;
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

  Future<ChromePage> _tab() async {
    final created = await _call('Target.createTarget', {'url': 'about:blank'});
    final attached = await _call('Target.attachToTarget', {'targetId': created['targetId'] as String, 'flatten': true});
    final tab = _Tab(created['targetId'] as String, attached['sessionId'] as String);
    _sessions[tab.session] = StreamController<_Cdp>.broadcast();
    final page = ChromePage._(this, tab);
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

  /// Makes [request] look like it came from this browser, for the plain client that will
  /// send it: the cookies Chrome holds for the URL, and Chrome's own user-agent.
  ///
  /// A raw request is the other half of a rendered crawl — the asset, the download — and a
  /// host that sees the pages arrive from Chrome and the files arrive from something that
  /// names no browser at all has been told two different stories. The rendered side drops a
  /// caller's `user-agent` on purpose; this side answers with the browser's real one.
  Future<Request> _withCookies(Request request) async {
    if (!request.headers.containsKey('user-agent')) {
      if (await _browserAgent() case final agent?) request.headers['user-agent'] = agent;
    }
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

  /// This browser's user-agent — the override it was built with, else what Chrome reports,
  /// asked once and kept.
  Future<String?> _browserAgent() async {
    if (_userAgent case final override?) return override;
    if (_agent != null) return _agent;
    try {
      final version = await _call('Browser.getVersion');
      return _agent = version['userAgent'] as String?;
    } catch (_) {
      return null;
    }
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
/// A page is what [ChromeClient.open] hands over and what [ChromeClient.send] drives
/// underneath. Its reads never throw on an empty result and its waits never throw on time:
/// [waitFor] answers `false`, [response] answers whatever the DOM says now. What is on the
/// screen is always available, which is the property an interstitial needs.
///
/// {@category Networking}
final class ChromePage {
  final ChromeClient _client;
  final _Tab _tab;

  StreamSubscription<_Cdp>? _events;
  Map<String, Object?>? _document;
  Completer<void>? _waiter;
  String _want = '';
  String _frame = '';
  Uri _url = Uri.parse('about:blank');
  bool _alive = true;

  ChromePage._(this._client, this._tab);

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
  /// [ChromeClient.launch].
  Future<Response> goto(Uri url, {ChromeWait? until, Duration? challenge, Request? request}) async {
    final wait = until ?? _client._wait;
    _arm(wait == ChromeWait.idle ? 'networkIdle' : 'load');
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

  /// The text of the first element [selector] matches, or `null` when nothing matched.
  ///
  /// A read of one value off a live page without building a whole [HtmlDocument] for it —
  /// what a poll for a status line or a price wants between clicks.
  Future<String?> text(String selector) async => switch (await eval(
    '''(() => { const el = document.querySelector(${jsonEncode(selector)}); return el ? el.innerText : null; })()''',
  )) {
    final String found => found,
    _ => null,
  };

  /// The value of [name] on the first element [selector] matches, or `null`.
  ///
  /// The attribute as the DOM resolves it, so `href` and `src` come back absolute.
  Future<String?> attr(String selector, String name) async => switch (await eval('''(() => {
  const el = document.querySelector(${jsonEncode(selector)});
  if (!el) return null;
  const name = ${jsonEncode(name)};
  return el[name] != null && typeof el[name] === 'string' ? el[name] : el.getAttribute(name);
})()''')) {
    final String found => found,
    _ => null,
  };

  /// Whether [selector] matches anything right now.
  Future<bool> has(String selector) async => await eval('!!document.querySelector(${jsonEncode(selector)})') == true;

  /// Chooses [value] in the first `<select>` [selector] matches, firing `change`.
  ///
  /// [value] is matched against each option's `value` and then its text, so a dropdown can
  /// be driven by what the person would read. Answers `false` when the select or the option
  /// was not found.
  Future<bool> select(String selector, String value) async =>
      await eval('''(() => {
  const el = document.querySelector(${jsonEncode(selector)});
  if (!el || !el.options) return false;
  const want = ${jsonEncode(value)};
  const option = [...el.options].find((o) => o.value === want) ??
                 [...el.options].find((o) => o.textContent.trim() === want);
  if (!option) return false;
  el.value = option.value;
  el.dispatchEvent(new Event('input', {bubbles: true}));
  el.dispatchEvent(new Event('change', {bubbles: true}));
  return true;
})()''') ==
      true;

  /// Moves the mouse over the first element [selector] matches — a menu that opens on hover,
  /// a tooltip that loads its content. Answers `false` when nothing matched or it has no box.
  Future<bool> hover(String selector) async {
    final node = await _node(selector);
    if (node == null) return false;
    try {
      await _call('DOM.scrollIntoViewIfNeeded', {'nodeId': node});
      final box = await _call('DOM.getBoxModel', {'nodeId': node});
      final quad = ((box['model'] as Map<String, Object?>?)?['content'] as List?)?.cast<num>();
      if (quad == null || quad.length < 6) return false;
      await _call('Input.dispatchMouseEvent', {
        'type': 'mouseMoved',
        'x': (quad[0] + quad[4]) / 2,
        'y': (quad[1] + quad[5]) / 2,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Runs [action] and waits for the navigation it causes — a click that leaves the page, a
  /// form submitted, a `location` assigned. Answers whether the page settled before [timeout].
  ///
  /// The wait is armed before [action] runs, which is the whole reason this takes the action
  /// instead of being a bare `waitForNavigation()` called after a click. A click is
  /// dispatched and returns immediately, and a fast page can finish loading before the next
  /// line runs; a wait armed afterwards has already missed the event it is waiting for and
  /// sits until its timeout. Like every wait here, expiring is an answer, not an exception.
  ///
  /// ```dart
  /// await page.navigating(() => page.click('a.next'));
  /// print(page.url);
  /// ```
  Future<bool> navigating(FutureOr<void> Function() action, {ChromeWait? until, Duration? timeout}) async {
    final wait = until ?? _client._wait;
    _arm(wait == ChromeWait.idle ? 'networkIdle' : 'load');
    try {
      await action();
    } catch (_) {
      _disarm();
      rethrow;
    }
    return _settle(timeout);
  }

  /// Goes back one entry in this tab's history, and waits. Answers `false` when there is
  /// nothing to go back to.
  Future<bool> back({ChromeWait? until, Duration? timeout}) async {
    final history = await _call('Page.getNavigationHistory');
    final index = history['currentIndex'] as int? ?? 0;
    final entries = (history['entries'] as List? ?? const []).cast<Map<String, Object?>>();
    if (index <= 0 || entries.isEmpty) return false;
    final was = _url;
    final wait = until ?? _client._wait;
    _arm(wait == ChromeWait.idle ? 'networkIdle' : 'load');
    await _call('Page.navigateToHistoryEntry', {'entryId': entries[index - 1]['id']});
    // A page the back/forward cache restores is not loaded again and fires no second `load`,
    // so the lifecycle wait on its own would sit out the whole timeout on the commonest kind
    // of back. The URL moving is the other proof the tab went back, and either one will do.
    final moved = await Future.any([_settle(timeout), _left(was, timeout)]);
    _disarm();
    return moved;
  }

  /// Answers once [url] is no longer [was] — the only signal a bfcache restore gives.
  Future<bool> _left(Uri was, Duration? timeout) async {
    final deadline = DateTime.now().add(timeout ?? _client._timeout);
    while (_alive && DateTime.now().isBefore(deadline)) {
      if (_url != was) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return _url != was;
  }

  /// This tab's cookies — after a login, to hand to something that is not a browser.
  Future<List<Cookie>> cookies() async {
    final all = await _call('Network.getCookies');
    return [
      for (final c in (all['cookies'] as List? ?? const []).cast<Map<String, Object?>>())
        Cookie(c['name'] as String? ?? '', c['value'] as String? ?? '')
          ..domain = c['domain'] as String?
          ..path = c['path'] as String?
          ..secure = c['secure'] == true
          ..httpOnly = c['httpOnly'] == true,
    ];
  }

  /// The page as a PDF, the way Chrome's own "Save as PDF" prints it.
  ///
  /// Headless only — a headful Chrome answers `Printing is not available`, which comes
  /// through as [ClientException].
  Future<Uint8List> pdf({bool background = true, bool landscape = false, double scale = 1}) async {
    final printed = await _call('Page.printToPDF', {
      'printBackground': background,
      'landscape': landscape,
      'scale': scale,
      'transferMode': 'ReturnAsBase64',
    });
    return base64.decode(printed['data'] as String? ?? '');
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
  /// `load` still has a DOM worth reading. Answers whether the event arrived in time.
  Future<bool> _settle([Duration? timeout]) async {
    final waiter = _waiter;
    if (waiter == null) return true;
    var fired = true;
    try {
      // The field is what the listener completes, so it stays set until the wait is over.
      await waiter.future.timeout(timeout ?? _client._timeout, onTimeout: () => fired = false);
    } finally {
      if (identical(_waiter, waiter)) _disarm();
    }
    return fired;
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

/// The browser's websocket endpoint on [host]:[port], or `null` when nothing answers there.
Future<Uri?> _devtools(String host, int port) async {
  final probe = IoClient();
  try {
    final res = await probe.send(Request('GET', Uri.parse('http://$host:$port/json/version'))).then((r) => r.read());
    if (!res.isOk) return null;
    return switch (res.json['webSocketDebuggerUrl'].to<String>()) {
      final debugger? => Uri.tryParse(debugger),
      _ => null,
    };
  } catch (_) {
    // Nothing listening, or something that is not DevTools. Either way there is no browser.
    return null;
  } finally {
    probe.close();
  }
}

/// The command that starts a Chrome [attach] could join, for the message that says so.
String _howToStart(int port) =>
    'Start one with --remote-debugging-port=$port --user-data-dir=<dir>, or use ChromeClient.connect() to start it for you.';

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
