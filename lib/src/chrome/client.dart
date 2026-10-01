part of '../../chrome.dart';

/// How far [ChromeClient] waits before it reads a page, in order of patience.
///
/// {@category Networking}
enum ChromeWait {
  /// `DOMContentLoaded`: enough for content that is in the served HTML.
  dom,

  /// The `load` event.
  load,

  /// `load`, then half a second with no request started or finished: for content fetched
  /// after load.
  idle;

  String get _lifecycle => switch (this) {
    ChromeWait.dom => 'DOMContentLoaded',
    ChromeWait.load => 'load',
    ChromeWait.idle => 'networkIdle',
  };
}

/// A kind of thing a page loads, for [ChromePage.block].
///
/// {@category Networking}
enum Resource {
  image(['Image']),
  font(['Font']),
  media(['Media']),
  stylesheet(['Stylesheet']),
  script(['Script']),
  xhr(['XHR', 'Fetch']);

  /// The DevTools resource types.
  final List<String> _types;

  const Resource(this._types);

  /// Images, fonts and media: most of a page's bytes and none of its text.
  static const heavy = {Resource.image, Resource.font, Resource.media};
}

/// What the pages in a [ChromeClient] think they are running on.
///
/// ```dart
/// final chrome = await ChromeClient.launch(device: Device.phone);
/// final german = await ChromeClient.launch(device: Device(locale: 'de-DE', timezone: 'Europe/Berlin'));
/// ```
///
/// [userAgent] is also what a raw request through the client sends, so pages and files tell
/// the host one story.
///
/// {@category Networking}
final class Device {
  final int width;
  final int height;

  /// `devicePixelRatio`.
  final double scale;

  /// A touch device with a mobile viewport.
  final bool mobile;

  /// Chrome's own unless set.
  final String? userAgent;

  /// `de-DE`: sets both `accept-language` and `navigator.language`.
  final String? locale;

  /// `Europe/Berlin`.
  final String? timezone;

  const Device({
    this.width = 1280,
    this.height = 800,
    this.scale = 1,
    this.mobile = false,
    this.userAgent,
    this.locale,
    this.timezone,
  });

  /// A browser window; the default.
  static const desktop = Device();

  /// A recent iPhone, user-agent included, so hosts serve the mobile site.
  static const phone = Device(
    width: 393,
    height: 852,
    scale: 3,
    mobile: true,
    userAgent:
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 '
        '(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1',
  );
}

/// Hides the marks `--remote-debugging-port` leaves, before the page's first line in every
/// document. `navigator.webdriver` itself needs `--disable-blink-features=AutomationControlled`:
/// it is set before any script could run.
const _stealthScript = '''
Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
if (!window.chrome) window.chrome = {runtime: {}, loadTimes: () => {}, csi: () => {}};
if (navigator.plugins && navigator.plugins.length === 0) {
  Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]});
}
if (navigator.languages && navigator.languages.length === 0) {
  Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
}
const query = window.navigator.permissions && window.navigator.permissions.query;
if (query) {
  window.navigator.permissions.query = (p) =>
    p && p.name === 'notifications'
      ? Promise.resolve({state: Notification.permission})
      : query.call(window.navigator.permissions, p);
}
''';

/// A [Client] that renders every page in the installed Chrome and answers with the DOM after
/// the page's scripts ran, over the DevTools protocol.
///
/// ```dart
/// final browser = await ChromeClient.launch(block: Resource.heavy, device: Device.phone);
/// await Http.scope(client: browser, () async {
///   await for (final item in url.scrape<Item>()
///       .onRequest((ctx) => ctx.request[ChromeClient.waitFor] = '.results .item')
///       .onResponse(parse)
///       .rights) print(item);
/// });
/// ```
///
/// Only a GET without `range` is rendered; anything else, or a [Request.raw] request (every
/// download sets it), goes to the plain client underneath with the browser's cookies and
/// user-agent.
///
/// A page is never lost: an expired wait or an uncleared interstitial returns the DOM as it
/// stands, and [open] hands over a tab to keep working:
///
/// ```dart
/// final page = await browser.open('https://example.com/login'.url);
/// await page.fill('#user', 'me');
/// await page.click('button[type=submit]');
/// await page.waitFor('.dashboard');
/// final file = await page.waitForDownload(() => page.click('.statement'));
/// await page.close();
/// ```
///
/// {@category Networking}
final class ChromeClient implements Client {
  /// Waits until a CSS selector matches before the page is read; one that never matches
  /// returns the page as it stands.
  static const waitFor = RequestKey<String>('chrome.wait-for');

  /// How long to wait before reading a page, overriding the client's `wait:`.
  static const waitUntil = RequestKey<ChromeWait>('chrome.wait-until');

  /// JavaScript run after the wait and before the DOM is read; a promise is awaited.
  static const script = RequestKey<String>('chrome.script');

  /// How long this request may sit on an interstitial, overriding the client's `challenge:`.
  static const challenge = RequestKey<Duration>('chrome.challenge');

  /// What this page refuses to load, overriding the client's `block:`.
  static const block = RequestKey<Set<Resource>>('chrome.block');

  final WebSocket _socket;
  final Client _assets;
  final bool _ownsAssets;
  final Process? _process;

  /// Erased on [close]: a launched browser's temp directory (profile unless given, and
  /// downloads), or a joined browser's download directory.
  Directory? _scratch;

  /// Where Chrome writes downloads before [ChromePage.waitForDownload] moves them.
  late final Future<Directory> _landing = _process != null
      ? Future.value(Directory('${_scratch!.path}/downloads'))
      : Directory.systemTemp.createTemp('dart_toolkit_downloads_').then((made) => _scratch = made);

  /// Open download waits on a joined browser; see [_downloads].
  var _waits = 0;

  /// Downloads a wait has claimed, so two waits never take the same one.
  final Set<String> _claimed = {};
  final Duration _timeout;
  final Duration _challenge;
  final ChromeWait _wait;
  final Device _device;
  final Uri? _proxy;
  final bool _stealth;
  final Set<Resource> _block;
  final Semaphore _permits;
  final Queue<ChromePage> _free = Queue();
  final Set<ChromePage> _pages = {};
  final Map<int, Completer<Map<String, Object?>>> _calls = {};
  final Map<String, StreamController<_Cdp>> _sessions = {};

  /// Browser-level events (downloads), which belong to no tab.
  final StreamController<_Cdp> _browser = StreamController<_Cdp>.broadcast();

  var _nextId = 0;
  var _closed = false;

  /// The socket went away under this client.
  var _gone = false;
  String? _agent;

  ChromeClient._(
    this._socket, {
    required Client? assets,
    required Duration timeout,
    required Duration challenge,
    required ChromeWait wait,
    required int tabs,
    required Device device,
    required Uri? proxy,
    required bool stealth,
    required Set<Resource> block,
    Process? process,
    Directory? scratch,
  }) : _assets = assets ?? IoClient(proxy: proxy),
       _ownsAssets = assets == null,
       _timeout = timeout,
       _challenge = challenge,
       _wait = wait,
       _device = device,
       _proxy = proxy,
       _stealth = stealth,
       _block = block,
       _process = process,
       _scratch = scratch,
       _permits = Semaphore(tabs) {
    _socket.listen(_dispatch, onDone: _lost, onError: (Object _) => _lost());
  }

  /// Whether this client was closed or its browser has gone.
  bool get isClosed => _closed || _gone;

  /// Starts a headless Chrome of its own and connects to it.
  ///
  /// [profile] is a user-data directory to keep (cookies, logins); without one the profile
  /// is temporary and erased on [close]. [tabs] is how many pages render at once. [wait] is
  /// the default for requests without [waitUntil]. [challenge] is how long an interstitial
  /// (403/429/503 with Cloudflare's markers) is given to clear before it is returned as is;
  /// with `headless: false` that is a human's chance to click it.
  ///
  /// [proxy] (`http://user:pass@host:8080`, `socks5://…`) also goes to the default [assets]
  /// client, so pages and files take one route. Its credentials are answered over the
  /// protocol, a round trip per request. Chrome bypasses loopback unless
  /// `args: ['--proxy-bypass-list=<-loopback>']`.
  ///
  /// [assets] answers everything that is not a render, and is closed with this client unless
  /// supplied.
  ///
  /// On macOS and Linux the browser dies with the program however it ends, `kill -9`
  /// included; on Windows only [close] stops it. A `--disable-features=` in [args] is merged
  /// with the ones this turns off.
  static Future<ChromeClient> launch({
    String? executable,
    Path? profile,
    bool headless = true,
    int tabs = 4,
    Duration timeout = const Duration(seconds: 30),
    Duration challenge = const Duration(seconds: 20),
    ChromeWait wait = ChromeWait.load,
    Device device = Device.desktop,
    Uri? proxy,
    bool stealth = true,
    Set<Resource> block = const {},
    Client? assets,
    List<String> args = const [],
  }) async {
    final binary = _binary(executable);
    final own = profile == null ? null : Directory(profile.absolute.path);
    await own?.create(recursive: true);
    // One directory per run, so one `rm` (ours, or the reaper's after a crash) takes it all.
    final scratch = await Directory.systemTemp.createTemp('dart_toolkit_chrome_');
    final dir = own ?? Directory('${scratch.path}/profile');
    final landing = Directory('${scratch.path}/downloads');
    await Future.wait([dir.create(), landing.create()]);
    // A stale port file from the last run would be read as this browser's.
    if (own != null) await File('${dir.path}/DevToolsActivePort').delete().catchError((Object _) => File(''));
    // Chrome reads only the last `--disable-features`, so the caller's are merged into ours.
    final disabled = {..._quiet};
    final rest = <String>[];
    for (final arg in args) {
      if (arg.startsWith('--disable-features=')) {
        disabled.addAll(arg.substring('--disable-features='.length).split(',').where((f) => f.isNotEmpty));
      } else {
        rest.add(arg);
      }
    }
    final command = [
      if (headless) '--headless=new',
      '--remote-debugging-port=0',
      '--user-data-dir=${dir.path}',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-networking',
      '--disable-backgrounding-occluded-windows',
      '--disable-renderer-backgrounding',
      '--disable-component-update',
      '--disable-features=${disabled.join(',')}',
      if (stealth) '--disable-blink-features=AutomationControlled',
      if (proxy != null) '--proxy-server=${_server(proxy)}',
      '--hide-scrollbars',
      '--mute-audio',
      ...rest,
      'about:blank',
    ];
    final process = _reaps
        ? await Process.start('/bin/sh', ['-c', _reaper, 'dart_toolkit_chrome', scratch.path, binary, ...command])
        : await Process.start(binary, command);
    // An unread pipe fills and stalls Chrome.
    unawaited(process.stdout.drain<void>().catchError((Object _) {}));
    unawaited(process.stderr.drain<void>().catchError((Object _) {}));
    try {
      final client = ChromeClient._(
        await WebSocket.connect('${await _activePort(dir, process, timeout)}'),
        assets: assets,
        timeout: timeout,
        challenge: challenge,
        wait: wait,
        tabs: tabs,
        device: device,
        proxy: proxy,
        stealth: stealth,
        block: block,
        process: process,
        scratch: scratch,
      );
      await client._point(landing);
      return client;
    } catch (_) {
      await _stop(process);
      await _erase(scratch);
      // Chrome on a taken profile hands off to the holder and exits: say so, not "not ready".
      if (own != null) {
        if (await _heldBy(own) case final holder?) {
          throw ClientException(
            'Chrome will not start on ${own.path}: $holder is already using that profile. '
            'Quit it, wait for the other run to finish, or give this one a profile of its own.',
          );
        }
      }
      rethrow;
    }
  }

  /// Joins the Chrome on [port], starting one that outlives this program if there is none:
  /// one browser and one profile across runs, for sites behind a login.
  ///
  /// ```dart
  /// final chrome = await ChromeClient.connect();   // run 1: starts Chrome, log in by hand
  /// await Http.scope(client: chrome, () async { … });
  /// await chrome.close();                          // the browser stays up
  /// ```
  ///
  /// [profile] defaults to `~/.dart_toolkit/chrome`, and [headless] to `false` so a person can
  /// log in. [profile], [headless], [executable], [args] and [proxy] only apply when starting
  /// one; [proxy] still reaches the plain client either way. [close] closes this client's
  /// tabs and never the browser.
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
    Device device = Device.desktop,
    Uri? proxy,
    bool stealth = true,
    Set<Resource> block = const {},
    Client? assets,
    List<String> args = const [],
  }) async {
    var endpoint = await _devtools(host, port);
    if (endpoint == null) {
      final binary = _binary(executable);
      final dir = profile ?? Path.home / '.dart_toolkit' / 'chrome';
      await Directory(dir).create(recursive: true);
      await Process.start(binary, [
        if (headless) '--headless=new',
        '--remote-debugging-port=$port',
        '--user-data-dir=$dir',
        '--no-first-run',
        '--no-default-browser-check',
        if (stealth) '--disable-blink-features=AutomationControlled',
        if (proxy != null) '--proxy-server=${_server(proxy)}',
        ...args,
        'about:blank',
      ], mode: ProcessStartMode.detached);
      // Polled, not `DevToolsActivePort`: that file is stale from the last run until rewritten.
      final deadline = DateTime.now().add(timeout);
      while ((endpoint = await _devtools(host, port)) == null) {
        if (DateTime.now().isAfter(deadline)) {
          throw ClientException('Chrome did not open a debugging port on $host:$port within ${timeout.inSeconds}s');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return ChromeClient._(
      await WebSocket.connect('$endpoint'),
      assets: assets,
      timeout: timeout,
      challenge: challenge,
      wait: wait,
      tabs: tabs,
      device: device,
      proxy: proxy,
      stealth: stealth,
      block: block,
    );
  }

  /// A tab of the caller's own until [ChromePage.close], outside [send]'s pool so holding it
  /// never starves a crawl; navigated to [url] when given.
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
    if (_gone) throw ClientException('The browser disconnected', request.url);
    if (Request.raw(request) == true || request.method != 'GET' || request.headers.containsKey('range')) {
      return _assets.send(await _withCookies(request));
    }
    final permit = await _permits.acquire();
    ChromePage? page;
    try {
      page = _free.isNotEmpty ? _free.removeFirst() : await _tab();
      // Credentials never go in extra headers, which reach every third-party subresource: a
      // cookie is set for this URL, and an `authorization` is added to same-origin requests.
      final extra = <String, String>{};
      final grant = <String, String>{};
      String? cookie;
      for (final MapEntry(:key, :value) in request.headers.entries) {
        final name = key.toLowerCase();
        if (_unsafe.contains(name)) continue;
        if (name == 'cookie') {
          cookie = value;
        } else if (_credential.contains(name)) {
          grant[name] = value;
        } else {
          extra[name] = value;
        }
      }
      await page.headers(extra);
      if (cookie != null) await page._plant(cookie, request.url);
      page._grant = grant.isEmpty ? null : (origin: _origin(request.url), headers: grant);
      await page.block(block(request) ?? _block);
      // With a waitFor or a script the DOM is read once, after them.
      final selector = waitFor(request);
      final source = script(request);
      final directed = selector != null || source != null;
      final res = await page._goto(
        request.url,
        read: !directed,
        until: waitUntil(request) ?? _wait,
        challenge: challenge(request) ?? _challenge,
        request: request,
      );
      if (selector != null) await page.waitFor(selector);
      if (source != null) await page.eval(source, awaitPromise: true);
      return _streamed(directed ? await page.response(request) : res!, request);
    } finally {
      // Back to the pool however it went: it may hold a challenge someone is solving.
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

  /// Closes this client's tabs and the connection and, for [launch], the browser, erasing
  /// what this client made. A joined browser's downloads are handed back to its own setting.
  @override
  Future<void> close() async {
    if (_closed) return;
    if (_process == null && _waits > 0 && !_gone) await _point(null);
    for (final page in _pages.toList()) {
      await page.close();
    }
    _pages.clear();
    _free.clear();
    if (_process != null && !_gone) {
      await _call('Browser.close').catchError((Object _) => const <String, Object?>{});
    }
    _closed = true;
    await _socket.close().catchError((Object _) => null);
    _abort();
    if (_ownsAssets) await _assets.close();
    if (_process case final process?) await _stop(process);
    if (_scratch case final scratch?) await _erase(scratch);
  }

  /// The download directory. A launched browser points there once; `setDownloadBehavior` is
  /// browser-wide, so a joined one only while a wait is open (see [_released]).
  Future<Directory> _downloads() async {
    final landing = await _landing;
    if (_process == null && _waits++ == 0) {
      try {
        await _point(landing);
      } catch (_) {
        _waits--;
        rethrow;
      }
    }
    return landing;
  }

  /// Points downloads at [landing], named by guid so a wait knows the file before it exists;
  /// `null` restores the browser's own setting.
  Future<void> _point(Directory? landing) => _call(
    'Browser.setDownloadBehavior',
    landing == null
        ? {'behavior': 'default'}
        : {'behavior': 'allowAndName', 'downloadPath': landing.path, 'eventsEnabled': true},
  ).then((_) {}, onError: (Object e) => landing == null ? null : throw e);

  /// Cancels download [guid] and erases its partial.
  Future<void> _abandon(String guid, Path landing) async {
    await _call('Browser.cancelDownload', {'guid': guid}).catchError((Object _) => const <String, Object?>{});
    for (final partial in [landing / guid, landing / '$guid.crdownload']) {
      try {
        await partial.delete();
      } catch (_) {}
    }
  }

  Future<void> _released() async {
    if (_process == null && --_waits == 0 && !_closed && !_gone) await _point(null);
  }

  // ---- tabs ------------------------------------------------------------------------------

  Future<ChromePage> _tab() async {
    final created = await _call('Target.createTarget', {'url': 'about:blank'});
    final target = created['targetId'] as String;
    final attached = await _call('Target.attachToTarget', {'targetId': target, 'flatten': true});
    final tab = _Tab(target, attached['sessionId'] as String);
    _sessions[tab.session] = StreamController<_Cdp>.broadcast();
    final page = ChromePage._(this, tab);
    _pages.add(page);
    await _call('Page.enable', null, tab);
    await _call('Network.enable', null, tab);
    await _call('Page.setLifecycleEventsEnabled', {'enabled': true}, tab);
    await _dress(tab);
    page._listen();
    await page.block(_block);
    final tree = await _call('Page.getFrameTree', null, tab);
    page._frame = ((tree['frameTree'] as Map?)?['frame'] as Map?)?['id'] as String? ?? '';
    return page;
  }

  /// Applies [_device] and stealth to a new tab. Locale and timezone are tried, not required:
  /// some Chromium builds lack them.
  Future<void> _dress(_Tab tab) async {
    final device = _device;
    await _call('Emulation.setDeviceMetricsOverride', {
      'width': device.width,
      'height': device.height,
      'deviceScaleFactor': device.scale,
      'mobile': device.mobile,
    }, tab);
    if (device.mobile) {
      await _call('Emulation.setTouchEmulationEnabled', {'enabled': true, 'maxTouchPoints': 5}, tab);
    }
    if (_stealth || device.userAgent != null || device.locale != null) {
      await _call('Emulation.setUserAgentOverride', {
        'userAgent': device.userAgent ?? await _browserAgent() ?? '',
        'acceptLanguage': ?device.locale,
      }, tab);
    }
    for (final (method, params) in [
      if (device.locale case final locale?) ('Emulation.setLocaleOverride', {'locale': locale}),
      if (device.timezone case final zone?) ('Emulation.setTimezoneOverride', {'timezoneId': zone}),
    ]) {
      try {
        await _call(method, params, tab);
      } catch (_) {}
    }
    if (_stealth) await _call('Page.addScriptToEvaluateOnNewDocument', {'source': _stealthScript}, tab);
  }

  /// Gives a raw [request] the browser's user-agent and its cookies for the URL.
  Future<Request> _withCookies(Request request) async {
    if (!request.headers.containsKey('user-agent')) {
      if (await _browserAgent() case final agent?) request.headers['user-agent'] = agent;
    }
    if (request.headers.containsKey('cookie')) return request;
    try {
      // Through a tab Chrome matches the jar to the URL; `Network` needs a tab, so with none
      // the whole jar is read and matched here.
      final tab = _pages.firstOrNull;
      final found = tab != null
          ? await _call('Network.getCookies', {
              'urls': ['${request.url}'],
            }, tab._tab)
          : await _call('Storage.getCookies');
      final jar = [
        for (final c in (found['cookies'] as List? ?? const []).cast<Map<String, Object?>>())
          if (tab != null || _sendsTo(c, request.url)) '${c['name']}=${c['value']}',
      ];
      if (jar.isNotEmpty) request.headers['cookie'] = jar.join('; ');
    } catch (_) {}
    return request;
  }

  /// The [Device.userAgent] override, else Chrome's (asked once).
  Future<String?> _browserAgent() async {
    if (_device.userAgent ?? _agent case final known?) return known;
    try {
      final ua = (await _call('Browser.getVersion'))['userAgent'] as String?;
      return _agent = _stealth ? ua?.replaceFirst('HeadlessChrome', 'Chrome') : ua;
    } catch (_) {
      return null;
    }
  }

  // ---- the protocol ----------------------------------------------------------------------

  Future<Map<String, Object?>> _call(String method, [Map<String, Object?>? params, _Tab? tab, Duration? timeout]) {
    // Returned, not thrown, so `_call(…).catchError` in an event handler catches it.
    if (_gone) return Future.error(const ClientException('The browser disconnected'));
    if (_closed && method != 'Target.closeTarget') {
      return Future.error(const ClientException('The browser client is closed'));
    }
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
    final event = _Cdp(message['method'] as String? ?? '', (message['params'] as Map<String, Object?>?) ?? const {});
    if (message['sessionId'] case final String id) {
      final session = _sessions[id];
      if (session != null && !session.isClosed) session.add(event);
    } else if (!_browser.isClosed) {
      _browser.add(event);
    }
  }

  /// The socket closed without [close]: later calls fail at once instead of timing out.
  void _lost() {
    if (!_closed) _gone = true;
    _abort();
  }

  void _abort() {
    for (final completer in _calls.values.toList()) {
      if (!completer.isCompleted) completer.completeError(const ClientException('The browser disconnected'));
    }
    _calls.clear();
    for (final session in _sessions.values) {
      unawaited(session.close());
    }
    _sessions.clear();
    if (!_browser.isClosed) unawaited(_browser.close());
  }
}
