part of '../../chrome.dart';

/// How far a render waits before it reads a page, in order of patience.
///
/// {@category Networking}
enum Wait {
  /// `DOMContentLoaded`: enough for content that is in the served HTML.
  dom,

  /// The `load` event.
  load,

  /// `load`, then half a second with no request started or finished: for content fetched after
  /// load.
  idle;

  String get _lifecycle => switch (this) {
    Wait.dom => 'DOMContentLoaded',
    Wait.load => 'load',
    Wait.idle => 'networkIdle',
  };
}

/// A kind of thing a page loads, for `block:`.
///
/// {@category Networking}
enum Resource {
  image(['Image']),
  font(['Font']),
  media(['Media']),
  stylesheet(['Stylesheet']),
  script(['Script']),
  xhr(['XHR', 'Fetch']),

  /// Anything from another site than the page's: analytics, ads, trackers, embeds, so
  /// [Wait.idle] is not held open by a beacon. A site is the host's last two labels, or three
  /// under a two-letter country code's `co.`/`com.`/`net.`/`org.`/`ac.`/`gov.`/`edu.`/`ne.`/
  /// `or.`/`go.` (`bbc.co.uk`): an approximation of the public-suffix list. The page's own
  /// document is never refused; another site's frame is, a captcha's included.
  offsite([]);

  /// The DevTools resource types.
  final List<String> _types;

  const Resource(this._types);

  /// Images, fonts and media: most of a page's bytes and none of its text.
  static const heavy = {Resource.image, Resource.font, Resource.media};
}

/// [host]'s site, for [Resource.offsite]: see there.
String _registrable(String host) {
  host = host.toLowerCase();
  if (host.isEmpty || InternetAddress.tryParse(host) != null) return host;
  final labels = host.split('.');
  if (labels.length < 3) return host;
  final top = labels.last;
  final keep = top.length == 2 && _secondLevels.contains(labels[labels.length - 2]) ? 3 : 2;
  return labels.sublist(labels.length - keep).join('.');
}

const _secondLevels = {'co', 'com', 'net', 'org', 'ac', 'gov', 'edu', 'ne', 'or', 'go'};

/// What the pages of a [Chrome] think they are running on.
///
/// ```dart
/// final chrome = await Chrome.launch(device: Device.phone);
/// final german = await Chrome.launch(device: Device(locale: 'de-DE', timezone: 'Europe/Berlin'));
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

/// How Chrome is started: the setting value of [Chrome.launch] and [Chrome.connect].
///
/// {@category Networking}
final class Browser {
  /// The Chrome to run; else `DART_TOOLKIT_CHROME`, else the first Chrome, Chromium or Edge
  /// installed in the usual places.
  final String? executable;

  /// Where the profile (cookies, logins) is kept: a folder store's folder. Without one, or with
  /// a memory store, a launched browser's profile is temporary, erased on close.
  final Store? store;

  final bool headless;

  /// More command-line flags; a `--disable-features=` is merged with the ones Chrome is started
  /// with.
  final List<String> args;

  /// Hides the marks automation leaves (`navigator.webdriver`, a headless user agent).
  final bool stealth;

  const Browser({this.executable, this.store, this.headless = true, this.args = const [], this.stealth = true});
}

/// How a page is read: a default on the client (`Chrome.launch(render:)`), overridden per
/// request with [Chrome.render] and per [Page.goto]. A field left `null` is the client's, and
/// the client's own `null`s are the defaults below.
///
/// ```dart
/// final r = Request('GET', url)..[Chrome.render] = Render(waitFor: '.results', wait: Wait.dom);
/// ```
///
/// {@category Networking}
final class Render {
  /// How far the page loads before it is read: [Wait.load].
  final Wait? wait;

  /// A CSS selector to wait for after loading; one that never matches is a [TimeoutException].
  final String? waitFor;

  /// JavaScript run after the waits and before the page is read; a promise is awaited.
  final String? script;

  /// How long an interstitial (a 403, 429 or 503 with a challenge's markers) is given to clear
  /// before it is the answer: 20 s. A visible browser gives a person that long to click it. It
  /// never counts against [timeout] or the scope's timeout.
  final Duration? challenge;

  /// What the page refuses to load; the client's `block:` when `null`.
  final Set<Resource>? block;

  /// How long each wait of a render may take (the load, [waitFor], the [script]): 30 s, and a
  /// [TimeoutException] past it. The challenge has its own time.
  final Duration? timeout;

  const Render({this.wait, this.waitFor, this.script, this.challenge, this.block, this.timeout});

  /// This, with [over]'s fields where it sets them.
  Render _under(Render? over) => over == null
      ? this
      : Render(
          wait: over.wait ?? wait,
          waitFor: over.waitFor ?? waitFor,
          script: over.script ?? script,
          challenge: over.challenge ?? challenge,
          block: over.block ?? block,
          timeout: over.timeout ?? timeout,
        );

  Wait get _wait => wait ?? Wait.load;
  Duration get _challenge => challenge ?? const Duration(seconds: 20);
  Duration get _timeout => timeout ?? const Duration(seconds: 30);

  void _check() {
    if (challenge case final c? when c < Duration.zero) {
      throw ArgumentError.value(c, 'challenge', 'Invalid challenge, expected zero or more');
    }
    if (timeout case final t? when t <= Duration.zero) {
      throw ArgumentError.value(t, 'timeout', 'Invalid timeout, expected more than zero');
    }
  }
}

/// A protocol call the browser refused, or a browser that went away: a [ClientException] naming
/// the [method] (`''` for the connection itself).
///
/// {@category Networking}
final class ChromeException extends ClientException {
  /// The DevTools method called, or `''`.
  final String method;

  /// The protocol's error code, when it gave one.
  final int? code;

  /// Whether the browser is gone: closed, crashed, or its connection lost.
  final bool detached;

  const ChromeException(String message, {this.method = '', this.code, this.detached = false, Uri? uri})
    : super(message, uri);

  static const _gone = ChromeException('The browser disconnected', detached: true);
  static const _closed = ChromeException('The browser client is closed', detached: true);
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

/// At most [_free] holders at once, served in turn; a cancel while waiting takes none.
final class _Permits {
  int _free;
  final _waiting = Queue<Completer<void>>();

  _Permits(this._free);

  Future<void Function()> acquire() async {
    final token = Cancel.token;
    token?.check();
    if (_free > 0) {
      _free--;
    } else {
      final turn = Completer<void>();
      _waiting.add(turn);
      final unhear = token?.onCancel(() {
        if (_waiting.remove(turn)) turn.completeError(CancelledException.of(token));
      });
      try {
        await turn.future;
      } finally {
        unhear?.call();
      }
    }
    var given = false;
    return () {
      if (given) return;
      given = true;
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _free++;
      }
    };
  }
}

/// The installed Chrome as a [Client]: every GET is rendered and answered with the DOM after
/// the page's scripts ran, over the DevTools protocol; [open] hands over a [Page] to drive.
///
/// ```dart
/// final chrome = await Chrome.launch(render: Render(wait: Wait.dom), block: Resource.heavy);
/// await Http.scope(client: chrome, () async {
///   final html = await url.get().html;                       // rendered
/// });
/// final page = await chrome.open(login);
/// await page.fill('#user', 'me');
/// await page.expectNavigation(() => page.click('button[type=submit]'));
/// await chrome.close();
/// ```
///
/// Only a GET without `range` is rendered; anything else, and a [Request.raw] request (every
/// download sets it), goes to plain HTTP with the browser's cookies and user-agent. A render
/// waits for a tab (at most `concurrency` at once) and for a challenge to clear without the
/// scope's timeout counting either.
///
/// {@category Networking}
final class Chrome implements Client {
  /// How one request is rendered, over the client's [Render]: `request[Chrome.render] = …`.
  static const render = RequestKey<Render>('chrome.render');

  final WebSocket _socket;
  final IoClient _assets;
  final Process? _process;

  /// Erased on [close]: a launched browser's temporary folder (profile unless kept, and
  /// downloads), or a joined browser's download folder.
  Directory? _scratch;

  /// Where Chrome writes downloads before [Page.expectDownload] moves them.
  late final Future<Directory> _landing = _process != null
      ? Future.value(Directory(_join(_scratch!.path, 'downloads')))
      : Directory.systemTemp.createTemp('dart_toolkit_downloads_').then((made) => _scratch = made);

  /// Open download waits on a joined browser; see [_downloads].
  var _waits = 0;

  /// Downloads a wait has claimed, so two waits never take the same one.
  final Set<String> _claimed = {};

  /// The client's [Render], every field set.
  final Render _render;
  final Device _device;

  /// Each proxy's user and password, percent-decoded, by `host:port`.
  final Map<String, (String, Secret)> _logins;
  final bool _stealth;
  final Set<Resource> _block;
  final _Permits _permits;
  final Queue<Page> _free = Queue();
  final Set<Page> _pages = {};

  /// Calls awaiting an answer, with the method each one called, for its error.
  final Map<int, (Completer<Map<String, Object?>>, String)> _calls = {};
  final Map<String, StreamController<_Cdp>> _sessions = {};

  /// Browser-level events (downloads), which belong to no tab.
  final StreamController<_Cdp> _browser = StreamController<_Cdp>.broadcast();

  var _nextId = 0;
  var _closed = false;

  /// The socket went away under this client.
  var _gone = false;
  String? _agent;

  /// `navigator.userAgentData` for Chrome's own agent: an override without it empties `brands`.
  Map<String, Object?>? _metadata;

  Chrome._(
    this._socket, {
    required Render render,
    required int concurrency,
    required Device device,
    required List<Uri> proxies,
    required bool stealth,
    required Set<Resource> block,
    Process? process,
    Directory? scratch,
  }) : _assets = IoClient(proxies: proxies),
       _render = const Render(
         wait: Wait.load,
         challenge: Duration(seconds: 20),
         timeout: Duration(seconds: 30),
       )._under(render),
       _device = device,
       _logins = {for (final p in proxies) '${p.host.toLowerCase()}:${p.port}': ?HttpBridge.login(p)},
       _stealth = stealth,
       _block = block,
       _process = process,
       _scratch = scratch,
       _permits = _Permits(concurrency) {
    _socket.listen(_dispatch, onDone: _lost, onError: (Object _) => _lost());
    HttpBridge.agents[this] = _browserAgent;
  }

  static void _checkSettings(Render render, int concurrency, List<Uri> proxies) {
    render._check();
    if (concurrency < 1) {
      throw ArgumentError.value(concurrency, 'concurrency', 'Invalid concurrency, expected at least 1');
    }
    // A proxy no client speaks fails here, before a browser starts.
    proxies.forEach(HttpBridge.isSocks);
  }

  /// The login for the proxy [challenge] (a `Fetch.authRequired` challenge) comes from.
  (String, Secret)? _loginFor(Object? challenge) {
    final origin = Uri.tryParse('${(challenge as Map?)?['origin'] ?? ''}');
    final login = origin == null ? null : _logins['${origin.host.toLowerCase()}:${origin.port}'];
    return login ?? (_logins.length == 1 ? _logins.values.single : null);
  }

  /// Whether this client was closed or its browser has gone.
  bool get isClosed => _closed || _gone;

  /// Starts a Chrome of its own, as [browser] says, and connects to it; none installed is a
  /// [MissingException]. On macOS and Linux it dies with the program however it ends,
  /// `kill -9` included; on Windows only [close] stops it.
  ///
  /// [render] is how pages are read unless a request says otherwise; [device] what they think
  /// they run on; [concurrency] how many render at once; [block] what every tab refuses to load.
  /// [proxies] (`http://user:pass@host:8080`, `socks5://host:1080`) are taken in turn, a request
  /// each, by the browser and by the plain HTTP under it alike; an HTTP proxy's credentials are
  /// answered over the protocol, while Chrome cannot log in to a SOCKS proxy (the plain HTTP
  /// can). Another scheme is an [ArgumentError].
  ///
  /// ```dart
  /// final chrome = await Chrome.launch(
  ///   browser: Browser(headless: true, store: app / 'chrome'),
  ///   render: Render(wait: Wait.load, challenge: 60.s),
  ///   device: Device.phone, concurrency: 4, proxies: [proxy], block: Resource.heavy);
  /// ```
  static Future<Chrome> launch({
    Browser browser = const Browser(),
    Render render = const Render(),
    Device device = Device.desktop,
    int concurrency = 4,
    List<Uri> proxies = const [],
    Set<Resource> block = const {},
  }) async {
    _checkSettings(render, concurrency, proxies);
    final binary = _binary(browser.executable);
    final kept = browser.store?.folder;
    final own = kept == null ? null : Directory(kept).absolute;
    await own?.create(recursive: true);
    // One folder per run, so one `rm` (ours, or the reaper's after a crash) takes it all.
    final scratch = await Directory.systemTemp.createTemp('dart_toolkit_chrome_');
    final dir = own ?? Directory(_join(scratch.path, 'profile'));
    final landing = Directory(_join(scratch.path, 'downloads'));
    await Future.wait([dir.create(), landing.create()]);
    // A stale port file from the last run would be read as this browser's.
    if (own != null) {
      await File(_join(dir.path, 'DevToolsActivePort')).delete().catchError((Object _) => File('')); // none: fine
    }
    final command = _flags(
      headless: browser.headless,
      port: 0,
      profile: dir.path,
      stealth: browser.stealth,
      proxies: proxies,
      args: browser.args,
    );
    final Process process;
    try {
      process = _reaps
          ? await Process.start('/bin/sh', ['-c', _reaper, 'dart_toolkit_chrome', scratch.path, binary, ...command])
          : await Process.start(binary, command);
      ProcessBridge.assignJob(process.pid);
    } catch (_) {
      await _erase(scratch);
      rethrow;
    }
    // An unread pipe fills and stalls Chrome; draining is best-effort.
    void drain(Stream<List<int>> pipe) => unawaited(pipe.drain<void>().catchError((Object _) {})); // best-effort
    drain(process.stdout);
    drain(process.stderr);
    try {
      final client = Chrome._(
        await WebSocket.connect('${await _activePort(dir, process, const Duration(seconds: 30))}'),
        render: render,
        concurrency: concurrency,
        device: device,
        proxies: proxies,
        stealth: browser.stealth,
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
        if (await _heldBy(own) case final holder?) throw _held(own.path, holder);
      }
      rethrow;
    }
  }

  /// Joins the Chrome listening on [port]: one browser and one profile across runs, for sites
  /// behind a login. With [start], a browser is started there when none answers, with the same
  /// flags [launch] gives one, and outlives this program (its profile `start.store`'s folder,
  /// else `Store.app('dart_toolkit') / 'chrome'`); without it, none answering is a
  /// [MissingException]. [close] closes this client's tabs, never the browser.
  ///
  /// ```dart
  /// final chrome = await Chrome.connect(port: 9222, start: Browser(headless: false)); // log in by hand once
  /// ```
  static Future<Chrome> connect({
    int port = 9222,
    String host = '127.0.0.1',
    Browser? start,
    Render render = const Render(),
    Device device = Device.desktop,
    int concurrency = 4,
    List<Uri> proxies = const [],
    Set<Resource> block = const {},
  }) async {
    _checkSettings(render, concurrency, proxies);
    var endpoint = await _devtools(host, port);
    if (endpoint == null) {
      if (start == null) throw MissingException('Chrome', where: '$host:$port');
      final binary = _binary(start.executable);
      final dir = start.store?.folder ?? (Store.app('dart_toolkit') / 'chrome').folder!;
      await Directory(dir).create(recursive: true);
      if (await _heldBy(Directory(dir)) case final holder?) throw _held(dir, holder);
      final process = await Process.start(
        binary,
        _flags(
          headless: start.headless,
          port: port,
          profile: dir,
          stealth: start.stealth,
          proxies: proxies,
          args: start.args,
        ),
        mode: ProcessStartMode.detached,
      );
      ProcessBridge.assignJob(process.pid);
      // Polled, not `DevToolsActivePort`: that file is stale from the last run until rewritten.
      const limit = Duration(seconds: 30);
      final began = Clock.current.elapsed;
      while ((endpoint = await _devtools(host, port)) == null) {
        if (Clock.current.elapsed - began > limit) throw TimeoutBridge('Chrome start on $host:$port', limit);
        await const Duration(milliseconds: 100).delay();
      }
    }
    return Chrome._(
      await WebSocket.connect('$endpoint'),
      render: render,
      concurrency: concurrency,
      device: device,
      proxies: proxies,
      stealth: start?.stealth ?? true,
      block: block,
    );
  }

  /// A tab of the caller's own until [Page.close], outside the render pool so holding it never
  /// starves a crawl; navigated to [url] as [render] says when it is not `null` (`open(null)` is
  /// a blank tab).
  Future<Page> open(Uri? url, {Render? render}) async {
    final page = await _tab();
    if (url != null) {
      try {
        await page.goto(url, render: render);
      } catch (_) {
        // The caller never gets the tab to close.
        await page.close();
        rethrow;
      }
    }
    return page;
  }

  /// The whole browser's cookies, as Chrome holds them (`x,y` values included): hand them to
  /// `Http.scope(cookies:)` to carry a browser login on at socket speed.
  Future<CookieJar> cookies() async {
    final all = await _call('Storage.getCookies');
    return CookieJar([
      for (final c in (all['cookies'] as List? ?? const []).cast<Map<String, Object?>>())
        if ((c['domain'] as String? ?? '').isNotEmpty)
          HttpCookie(
            c['name'] as String? ?? '',
            c['value'] as String? ?? '',
            domain: c['domain']! as String,
            path: c['path'] as String? ?? '/',
            secure: c['secure'] == true,
            httpOnly: c['httpOnly'] == true,
            expires: switch (c['expires']) {
              final num at when at > 0 => DateTime.fromMillisecondsSinceEpoch((at * 1000).round()),
              _ => null,
            },
          ),
    ]);
  }

  /// Puts [jar]'s cookies into the browser, for every tab: a saved session restored.
  Future<void> setCookies(CookieJar jar) async {
    if (jar.isEmpty) return;
    await _call('Storage.setCookies', {
      'cookies': [
        for (final c in jar)
          <String, Object?>{
            'name': c.name,
            'value': c.value,
            // A host-only cookie is set by URL: a `domain` would widen it to the subdomains.
            if (c.hostOnly)
              'url': '${Uri(scheme: c.secure ? 'https' : 'http', host: c.domain, path: c.path)}'
            else
              'domain': '.${c.domain}',
            'path': c.path,
            'secure': c.secure,
            'httpOnly': c.httpOnly,
            if (c.expires case final expiry?) 'expires': expiry.millisecondsSinceEpoch / 1000,
          },
      ],
    });
  }

  @override
  Future<StreamedResponse> send(Request request) async {
    if (_closed) throw ChromeException._closed;
    if (_gone) throw ChromeException._gone;
    if (Request.raw(request) == true || request.method != 'GET' || request.headers.containsKey('range')) {
      return _assets.send(await _withCookies(request));
    }
    final how = _render._under(Chrome.render(request)).._check();
    // The queue for a tab is not the request's time.
    final permit = await HttpBridge.untimed(_permits.acquire);
    Page? page;
    try {
      page = _free.isNotEmpty ? _free.removeFirst() : await _tab();
      final res = await _rendered(page, request, how);
      return StreamedResponse(
        Stream.value(res.bytes),
        res.statusCode,
        contentLength: res.bytes.length,
        headers: res.headers,
        request: request,
        url: res.url,
      );
    } finally {
      // Back to the pool however it went: it may hold a challenge someone is solving.
      if (page != null) {
        if (page._alive && !_closed) {
          _free.add(page);
        } else {
          await page.close();
        }
      }
      permit();
    }
  }

  /// [request] rendered in [page] as [how] says.
  Future<Response> _rendered(Page page, Request request, Render how) async {
    // Credentials never go in extra headers, which reach every third-party subresource: a
    // cookie is set for this URL, and an `authorization` is added to same-origin requests.
    final extra = <String, String>{};
    final grant = <String, String>{};
    String? cookie;
    String? agent;
    for (final MapEntry(:key, :value) in request.headers.entries) {
      final name = key.toLowerCase();
      if (name == 'user-agent') {
        agent = value;
      } else if (_unsafe.contains(name)) {
        continue;
      } else if (name == 'cookie') {
        cookie = value;
      } else if (HttpBridge.credentials.contains(name)) {
        grant[name] = value;
      } else {
        extra[name] = value;
      }
    }
    await page._extraHeaders(extra);
    // The agent the request names is the one the site sees, so robots and the server agree.
    await page._agent(agent);
    final planted = cookie == null ? const <String>[] : await page._plant(cookie, request.url);
    try {
      page._grant = grant.isEmpty ? null : (origin: _origin(request.url), headers: grant);
      await page.block(how.block ?? _block);
      final res = await page._goto(request.url, how, request: request);
      if (how.waitFor case final selector?) await page.wait(selector, timeout: how._timeout);
      if (how.script case final source?) await page._value(source, timeout: how._timeout);
      return how.waitFor != null || how.script != null ? await page._response(request) : res;
    } finally {
      // A joined browser is someone's own: the cookies a render brought leave with it.
      if (_process == null && planted.isNotEmpty) await page._unplant(planted, request.url);
    }
  }

  /// Closes this client's tabs and the connection and, for [launch], the browser, erasing what
  /// this client made. A joined browser's downloads are handed back to its own setting.
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
      await _call('Browser.close').catchError((Object _) => const <String, Object?>{}); // best-effort: stopped next
    }
    _closed = true;
    await _socket.close().catchError((Object _) => null); // best-effort: the browser may be gone
    _abort();
    await _assets.close();
    if (_process case final process?) await _stop(process);
    if (_scratch case final scratch?) await _erase(scratch);
  }

  /// The download folder. A launched browser points there once; `setDownloadBehavior` is
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
        : {
            'behavior': 'allowAndName',
            'downloadPath': Platform.isWindows ? landing.path.replaceAll('/', r'\') : landing.path,
            'eventsEnabled': true,
          },
  ).then((_) {}, onError: (Object e) => landing == null ? null : throw e);

  /// Cancels download [guid] and erases its partial.
  Future<void> _abandon(String guid, String landing) async {
    await _call('Browser.cancelDownload', {'guid': guid}).catchError((Object _) => const <String, Object?>{}); // gone
    for (final partial in [_join(landing, guid), _join(landing, '$guid.crdownload')]) {
      try {
        await File(partial).delete();
      } on FileSystemException catch (_) {} // best-effort: a partial download Chrome still writes
    }
  }

  Future<void> _released() async {
    if (_process == null && --_waits == 0 && !_closed && !_gone) await _point(null);
  }

  // ---- tabs ------------------------------------------------------------------------------

  Future<Page> _tab() async {
    final created = await _call('Target.createTarget', {'url': 'about:blank'});
    final target = created['targetId'] as String;
    final attached = await _call('Target.attachToTarget', {'targetId': target, 'flatten': true});
    final tab = _Tab(target, attached['sessionId'] as String);
    _sessions[tab.session] = StreamController<_Cdp>.broadcast();
    final page = Page._(this, tab);
    _pages.add(page);
    try {
      await _setUp(page, tab);
    } catch (_) {
      await page.close();
      rethrow;
    }
    return page;
  }

  Future<void> _setUp(Page page, _Tab tab) async {
    // Not awaited: it only lets a crash be heard, and calls keep their order.
    unawaited(_call('Inspector.enable', null, tab).then((_) {}, onError: (Object _) {})); // a crash just goes unheard
    await _call('Page.enable', null, tab);
    await _call('Network.enable', null, tab);
    await _call('Page.setLifecycleEventsEnabled', {'enabled': true}, tab);
    // Every tab acts focused: Chrome starts no download from one behind another.
    await _call('Emulation.setFocusEmulationEnabled', {'enabled': true}, tab);
    await _dress(tab);
    page._listen();
    await page.block(_block);
    await _call('Target.setAutoAttach', Page._attach, tab);
    final tree = await _call('Page.getFrameTree', null, tab);
    page._frame = ((tree['frameTree'] as Map?)?['frame'] as Map?)?['id'] as String? ?? '';
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
    if (_stealth || device.userAgent != null || device.locale != null) await _override(tab, null);
    for (final (method, params) in [
      if (device.locale case final locale?) ('Emulation.setLocaleOverride', {'locale': locale}),
      if (device.timezone case final zone?) ('Emulation.setTimezoneOverride', {'timezoneId': zone}),
    ]) {
      try {
        await _call(method, params, tab);
      } on ChromeException catch (e) {
        if (e.detached) rethrow; // an override this Chrome does not support is skipped
      }
    }
    if (_stealth) await _call('Page.addScriptToEvaluateOnNewDocument', {'source': _stealthScript}, tab);
  }

  /// Sets [tab]'s user agent: [agent], else the device's, else Chrome's own (stealthed).
  Future<void> _override(_Tab tab, String? agent) async => _call('Emulation.setUserAgentOverride', {
    'userAgent': agent ?? _device.userAgent ?? await _browserAgent() ?? '',
    'acceptLanguage': ?_device.locale,
    if (agent == null && _device.userAgent == null) 'userAgentMetadata': ?_metadata,
  }, tab);

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
    } on ChromeException catch (e) {
      if (e.detached) rethrow; // otherwise no cookies readable: the request goes without
    }
    return request;
  }

  /// The [Device.userAgent] override, else Chrome's (asked once).
  Future<String?> _browserAgent() async {
    if (_device.userAgent ?? _agent case final known?) return known;
    try {
      final version = await _call('Browser.getVersion');
      final ua = version['userAgent'] as String?;
      if ('${version['product']}'.split('/') case [final product, final full]) {
        final major = full.split('.').first;
        final arm = Platform.version.contains('arm');
        _metadata = {
          'brands': [
            {'brand': 'Chromium', 'version': major},
            {'brand': _stealth ? 'Google Chrome' : product, 'version': major},
            {'brand': 'Not.A/Brand', 'version': '99'},
          ],
          'fullVersion': full,
          'platform': switch (Platform.operatingSystem) {
            'macos' => 'macOS',
            final os => os[0].toUpperCase() + os.substring(1),
          },
          'platformVersion': '',
          'architecture': arm ? 'arm' : 'x86',
          'model': '',
          'mobile': _device.mobile,
          'bitness': '64',
        };
      }
      return _agent = _stealth ? ua?.replaceFirst('HeadlessChrome', 'Chrome') : ua;
    } on ChromeException catch (_) {
      return null; // a browser that will not say: none
    }
  }

  // ---- the protocol ----------------------------------------------------------------------

  Future<Map<String, Object?>> _call(String method, [Map<String, Object?>? params, _Tab? tab, Duration? timeout]) {
    // Returned, not thrown, so `_call(…).catchError` in an event handler catches it.
    if (_gone) return Future.error(ChromeException._gone);
    if (_closed && method != 'Target.closeTarget') return Future.error(ChromeException._closed);
    final id = ++_nextId;
    final completer = Completer<Map<String, Object?>>();
    _calls[id] = (completer, method);
    _socket.add(jsonEncode({'id': id, 'method': method, 'params': ?params, 'sessionId': ?tab?.session}));
    final limit = timeout ?? _render._timeout;
    return completer.future.timeout(
      limit,
      onTimeout: () {
        _calls.remove(id);
        throw TimeoutBridge('Chrome $method', limit);
      },
    );
  }

  void _dispatch(Object? frame) {
    final message = switch (jsonDecode(frame is String ? frame : utf8.decode((frame as List).cast<int>()))) {
      final Map<String, Object?> decoded => decoded,
      _ => <String, Object?>{},
    };
    if (message['id'] case final int id) {
      final (completer, method) = _calls.remove(id) ?? (null, '');
      if (completer == null || completer.isCompleted) return;
      if (message['error'] case final Map<String, Object?> error) {
        return completer.completeError(
          ChromeException(
            '$method: ${error['message'] ?? error}',
            method: method,
            code: (error['code'] as num?)?.toInt(),
          ),
        );
      }
      return completer.complete((message['result'] as Map<String, Object?>?) ?? const {});
    }
    final event = _Cdp(message['method'] as String? ?? '', (message['params'] as Map<String, Object?>?) ?? const {});
    if (message['sessionId'] case final String id) {
      final session = _sessions[id];
      if (session != null && !session.isClosed) session.add(event);
    } else {
      // A tab closed under us (by its own script, or a person) leaves the pool with it.
      if (event.method == 'Target.detachedFromTarget') {
        for (final page in [..._pages]) {
          if (page._tab.session == event.params['sessionId']) unawaited(page.close());
        }
      }
      if (!_browser.isClosed) _browser.add(event);
    }
  }

  /// The socket closed without [close]: later calls fail at once instead of timing out.
  void _lost() {
    if (!_closed) _gone = true;
    _abort();
  }

  void _abort() {
    for (final (completer, _) in _calls.values.toList()) {
      if (!completer.isCompleted) completer.completeError(ChromeException._gone);
    }
    _calls.clear();
    for (final page in _pages) {
      page._complete();
    }
    for (final session in _sessions.values) {
      unawaited(session.close());
    }
    _sessions.clear();
    if (!_browser.isClosed) unawaited(_browser.close());
  }
}
