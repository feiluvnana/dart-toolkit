part of '../../chrome.dart';

/// How far [ChromeClient] waits before it reads a page, in order of patience.
///
/// {@category Networking}
enum ChromeWait {
  /// The markup has parsed — `DOMContentLoaded`. The earliest a selector can match, and
  /// enough for a page whose content is in the HTML it was served.
  dom,

  /// The document and its subresources have loaded — the `load` event.
  load,

  /// `load`, and then half a second in which no request started or finished. What a page
  /// that fetches its content after loading needs.
  idle;

  /// The lifecycle event Chrome calls this.
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

  /// What the DevTools protocol calls it; `xhr` is two names there for one idea here.
  final List<String> _types;

  const Resource(this._types);

  /// Everything a page can be read without: images, fonts and media.
  ///
  /// The three that are most of a page's bytes and none of its text, so a crawl that blocks
  /// them reads exactly the same thing in a fraction of the time. Not stylesheets or scripts,
  /// which is the line: a page that cannot run its scripts is not the page a browser was
  /// opened for in the first place.
  static const heavy = {Resource.image, Resource.font, Resource.media};
}

/// What the pages in a [ChromeClient] think they are running on.
///
/// One argument instead of six, and the two that matter have names: `Device.desktop` is what
/// a browser is unless it is told otherwise, and `Device.phone` is the other site a great
/// many hosts serve — usually a simpler one, with the same data in a tenth of the markup.
///
/// ```dart
/// final chrome = await ChromeClient.launch(device: Device.phone);
/// final german = await ChromeClient.launch(device: Device(locale: 'de-DE', timezone: 'Europe/Berlin'));
/// ```
///
/// [userAgent] is also what a raw request through this client announces, so the pages and the
/// files a crawl fetches tell the host one story rather than two.
///
/// {@category Networking}
final class Device {
  final int width;
  final int height;

  /// `devicePixelRatio` — 3 is a modern phone, 2 a retina laptop.
  final double scale;

  /// Whether the page is told it is a touch device with a mobile viewport.
  final bool mobile;

  /// What to call ourselves; Chrome's own unless this says otherwise.
  final String? userAgent;

  /// `de-DE`, which sets both `accept-language` and `navigator.language`.
  final String? locale;

  /// `Europe/Berlin` — what `new Date()` says inside the page.
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

  /// A browser window, and what a client renders in unless it is given another.
  static const desktop = Device();

  /// A recent iPhone, down to the user-agent — the mobile site, not the desktop one shrunk.
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

/// What a page sees when it looks for the marks of an automated browser.
///
/// Every one of these is something Chrome leaves different under `--remote-debugging-port`
/// and nowhere else, which is exactly what an interstitial checks before it decides whether
/// to show anyone the page. The flag that matters most is not here but on the command line —
/// `--disable-blink-features=AutomationControlled` — because `navigator.webdriver` is set
/// before any script of ours could run; this covers the rest, and runs before the page's own
/// first line in every document the tab loads.
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

/// A [Client] that renders every page in Chrome and answers with the DOM as it stands
/// after the page's own scripts have run.
///
/// It speaks the DevTools protocol over a websocket — no third-party package, and no
/// Chromium download: [launch] finds the browser already installed, [connect] joins the one
/// already running on a debugging port, or starts one that outlives the program.
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
///   ctx.request[ChromeClient.block] = Resource.heavy;
/// })
/// ```
///
/// What the browser is, and what it will not load, are said once at the top instead:
/// [Device] is what the pages think they are running on, `block:` is what no render ever
/// fetches — the largest single thing a rendered crawl can do for itself — and `stealth:`
/// hides the marks an automated Chrome leaves for an interstitial to find.
///
/// ```dart
/// await ChromeClient.launch(block: Resource.heavy, device: Device.phone);
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
/// final file = await page.waitForDownload(() => page.click('.statement'));
/// await page.close();
/// ```
///
/// A tab is worked with the words on [ChromePage]: [ChromePage.click], [ChromePage.fill] and
/// [ChromePage.waitFor] for what is on the screen, [ChromePage.frame] for what is inside an
/// iframe, and the three armed waits — [ChromePage.waitForNavigation],
/// [ChromePage.waitForDownload] and [ChromePage.waitForResponse] — for what a click sets off.
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

  /// What this page refuses to load, overriding the client's `block:`:
  /// `request[ChromeClient.block] = Resource.heavy`.
  static const block = RequestKey<Set<Resource>>('chrome.block');

  final WebSocket _socket;
  final Client _assets;
  final bool _ownsAssets;
  final Process? _process;

  /// What this client made and erases on [close]: a launched browser's temporary directory —
  /// the profile, unless one was given, and the downloads — or, for a browser it joined, the
  /// directory its downloads land in.
  Directory? _scratch;

  /// Where Chrome writes a download before [ChromePage.waitForDownload] moves it to its `to:`:
  /// `downloads` in a launched browser's [_scratch], else a directory made the first time.
  late final Future<Directory> _landing = _process != null
      ? Future.value(Directory('${_scratch!.path}/downloads'))
      : Directory.systemTemp.createTemp('dart_toolkit_downloads_').then((made) => _scratch = made);

  /// How many download waits are open, on a browser this client did not start; see
  /// [_downloads].
  var _waits = 0;

  /// The downloads a wait has claimed, so two waits open at once never take the same one.
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

  /// Events the browser itself sends, which belong to no tab: a download beginning, and its
  /// progress. A page listens here for its own, matching on the frame that started them.
  final StreamController<_Cdp> _browser = StreamController<_Cdp>.broadcast();

  var _nextId = 0;
  var _closed = false;

  /// Whether the socket went away under this client — the browser crashed, or was quit.
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

  /// Whether this client has been closed, or its browser has gone — quit, crashed or killed.
  bool get isClosed => _closed || _gone;

  /// Starts a headless Chrome of its own and connects to it.
  ///
  /// [profile] is a user-data directory to keep, which makes this a browser that remembers —
  /// the same cookies and the same login on every run, as [connect]'s does — while the process
  /// still dies with the client. Without one the profile is temporary and erased on [close],
  /// which is what makes a plain `launch` a browser that has never been anywhere.
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
  /// [proxy] sends everything through one — `http://user:pass@host:8080`, or a `socks5://`.
  /// Credentials cannot travel on a command line, so Chrome asks for them and this answers
  /// over the protocol; that costs a round trip per request, and only for a client that named
  /// an authenticated proxy. **The default [assets] client is given the same proxy**, because
  /// the pages and the files of one crawl going by different routes is the thing a host
  /// notices. Chrome bypasses the loopback for a proxy unless
  /// `args: ['--proxy-bypass-list=<-loopback>']` says otherwise.
  ///
  /// [assets] answers everything that is not a page render, and is closed with this client
  /// unless it was supplied. One supplied here is used as it is, proxy and all.
  ///
  /// **The browser dies with the program**, not only with [close]. On macOS and Linux it is
  /// started under a small `sh` that holds the other end of a pipe from this process; when
  /// this process ends by any means — a return, an exception, `exit`, `kill -9` — the pipe
  /// closes, and the shell stops Chrome and erases what [launch] made. So a script need not
  /// wrap its browser in `try`/`finally` for the sake of a crash. On Windows only [close]
  /// stops it, as before.
  ///
  /// A fresh profile fetches nothing it is not asked for: the component updater and the
  /// optimization-guide models are off, which is ~40 MB a profile would otherwise download in
  /// its first minute. A `--disable-features=` in [args] is added to the ones this turns off
  /// rather than replacing them.
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
    // A profile of its own is a browser that remembers: the same cookies, the same login, run
    // after run. Without one it is a temporary directory, which is what makes a plain `launch`
    // a browser that has never been anywhere.
    final own = profile == null ? null : Directory(profile.absolute.path);
    await own?.create(recursive: true);
    // Everything this run makes goes in one directory, so one `rm` — this client's, or the
    // reaper's after a crash — takes all of it: the profile unless one was given, and the
    // downloads, which land here and never in the working directory.
    final scratch = await Directory.systemTemp.createTemp('dart_toolkit_chrome_');
    final dir = own ?? Directory('${scratch.path}/profile');
    final landing = Directory('${scratch.path}/downloads');
    await Future.wait([dir.create(), landing.create()]);
    // A stale port file from the last run would be read as this browser's.
    if (own != null) await File('${dir.path}/DevToolsActivePort').delete().catchError((Object _) => File(''));
    // One `--disable-features`, because Chrome reads only the last: a caller's own is merged
    // into this list instead of silently replacing it.
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
    // Nothing is read from Chrome's output, and a pipe nobody reads fills and stalls it.
    unawaited(process.stdout.drain<void>().catchError((Object _) {}));
    unawaited(process.stderr.drain<void>().catchError((Object _) {}));
    try {
      final endpoint = await _activePort(dir, process, timeout);
      final client = ChromeClient._(
        await WebSocket.connect(endpoint.toString()),
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
      // The browser is this client's, so its downloads are pointed here once and for good:
      // whatever it fetches — a click nobody waited for, a component of its own — lands in
      // the directory [close] erases rather than wherever the program was started.
      await client._point(landing);
      return client;
    } catch (_) {
      await _stop(process);
      await _erase(scratch);
      // A profile can only be open in one browser at a time: a second Chrome told to use one
      // that is taken hands its command line to the first and exits at once, which arrives
      // here as a browser that was never ready. Saying only that sends the reader looking at
      // the wrong thing — the proxy, the binary, the timeout — so say which it is.
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

  /// Joins the Chrome on [port], and starts one that outlives this program if there is
  /// none — the client for a script that is run again and again.
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
  /// The second run finds that Chrome on the port and joins it in milliseconds, with
  /// the cookies and the logged-in session still there. [close] never kills it, whichever
  /// run started it; the person owns the browser, and quits it when they are done with it.
  ///
  /// [profile] is the user-data directory that makes it the same browser next time,
  /// `~/.dart_toolkit/chrome` unless another is named. Because that profile persists, this
  /// is [headless]-`false` by default: a browser you can see is one you can log into.
  ///
  /// A Chrome already running on [port] is joined as it is — [profile], [headless],
  /// [executable], [args] and [proxy] describe how to *start* one and are ignored when none
  /// is needed. A [proxy] still reaches the plain client underneath either way, so a run that
  /// joins an existing browser downloads through the proxy and renders around it; when that
  /// matters, quit the browser first or give it a [profile] of its own.
  ///
  /// The browser outlives [close], which only lets go of it: the tabs this client opened are
  /// closed, nothing else is.
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
      // Detached: the browser is meant to outlive this program, so it must not be a child
      // that dies with it. Nothing is read from its stdio, and the port is the handle.
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
      // The port is polled rather than `DevToolsActivePort` read: the file is stale from the
      // last run until Chrome rewrites it, and here the port is known because it was given.
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
    if (_gone) throw ClientException('The browser disconnected', request.url);
    if (Request.raw(request) == true || request.method != 'GET' || request.headers.containsKey('range')) {
      return _assets.send(await _withCookies(request));
    }
    final permit = await _permits.acquire();
    ChromePage? page;
    try {
      page = _free.isNotEmpty ? _free.removeFirst() : await _tab();
      // Credentials never go in the tab's extra headers, which Chrome sends with every request
      // the page makes — to every third-party host an `<img>` or a script points at. A cookie
      // is given to the browser for this URL alone, and an `authorization` is added to the
      // requests that go back to this origin and to nothing else: the rule [Request._hop]
      // keeps for a redirect, kept for a page's subresources too.
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
      // Both directives may be set, and both change what the DOM says, so the page is read
      // once, after the last of them has run — and not on arrival as well.
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

  /// Closes every tab this client opened, the connection, and — for [launch] — the browser,
  /// erasing what this client made: a temporary profile, and every download no wait claimed.
  ///
  /// On a browser this client did not start, the downloads are handed back to the browser's
  /// own setting, so the person's next download goes where theirs always did.
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

  /// The directory downloads land in, pointed at for as long as a wait needs it.
  ///
  /// A launched browser was pointed there once, at launch. One this client joined belongs to
  /// someone, and `Browser.setDownloadBehavior` is browser-wide, so it is pointed here only
  /// while a wait is open and handed back when the last one ends; see [_released].
  Future<Directory> _downloads() async {
    final landing = await _landing;
    if (_process == null && _waits++ == 0) {
      try {
        await _point(landing);
      } catch (_) {
        // Not pointed, so not counted: the wait that asked never reaches its `_released`.
        _waits--;
        rethrow;
      }
    }
    return landing;
  }

  /// Points the browser's downloads at [landing], named by their ids so a wait knows the file
  /// before it exists — or, with `null`, back at the browser's own setting.
  Future<void> _point(Directory? landing) => _call(
    'Browser.setDownloadBehavior',
    landing == null
        ? {'behavior': 'default'}
        : {'behavior': 'allowAndName', 'downloadPath': landing.path, 'eventsEnabled': true},
  ).then((_) {}, onError: (Object e) => landing == null ? null : throw e);

  /// Gives up on download [guid]: Chrome stops fetching it, and its partial is erased.
  Future<void> _abandon(String guid, Path landing) async {
    await _call('Browser.cancelDownload', {'guid': guid}).catchError((Object _) => const <String, Object?>{});
    for (final partial in [landing / guid, landing / '$guid.crdownload']) {
      try {
        await partial.delete();
      } catch (_) {}
    }
  }

  /// A wait is over; the last one on a joined browser gives its downloads back.
  Future<void> _released() async {
    if (_process == null && --_waits == 0 && !_closed && !_gone) await _point(null);
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
    await _dress(tab);
    page._listen();
    await page.block(_block);
    final tree = await _call('Page.getFrameTree', null, tab);
    page._frame = switch (tree['frameTree']) {
      final Map<String, Object?> root => (root['frame'] as Map<String, Object?>?)?['id'] as String? ?? '',
      _ => '',
    };
    return page;
  }

  /// Tells a new tab what it is running on, and hides what it is being run by.
  ///
  /// The locale and timezone overrides are tried rather than required: a Chromium build
  /// without them is still a browser, and a page that is told the wrong timezone is a smaller
  /// problem than a client that will not start.
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
      // Through a tab, Chrome matches its jar against the URL itself — domain, path, `Secure` —
      // so only what this request carries crosses the socket, not every cookie a long-lived
      // profile holds. `Network` is a tab's domain; with no tab open, the whole jar is read.
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

  /// This browser's user-agent — the override it was built with, else what Chrome reports,
  /// asked once and kept.
  Future<String?> _browserAgent() async {
    if (_device.userAgent case final override?) return override;
    if (_agent != null) return _agent;
    try {
      final version = await _call('Browser.getVersion');
      var ua = version['userAgent'] as String?;
      if (_stealth && ua != null) ua = ua.replaceFirst('HeadlessChrome', 'Chrome');
      return _agent = ua;
    } catch (_) {
      return null;
    }
  }

  // ---- the protocol ----------------------------------------------------------------------

  Future<Map<String, Object?>> _call(String method, [Map<String, Object?>? params, _Tab? tab, Duration? timeout]) {
    // Returned rather than thrown, so a `_call(…).catchError` in an event handler catches it.
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
    // An event with no session is the browser's own rather than any tab's.
    if (message['sessionId'] case final String id) {
      final session = _sessions[id];
      if (session != null && !session.isClosed) session.add(event);
    } else if (!_browser.isClosed) {
      _browser.add(event);
    }
  }

  /// The socket closed without [close]: the browser quit, crashed or was killed. Every call
  /// after this fails at once rather than waiting out its timeout on a socket that is gone.
  void _lost() {
    if (!_closed) _gone = true;
    _abort();
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
    if (!_browser.isClosed) unawaited(_browser.close());
  }
}
