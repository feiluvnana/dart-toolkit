part of '../../http.dart';

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
  bool _started;
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
    required bool started,
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
       _started = started,
       _stealth = stealth,
       _block = block,
       _process = process,
       _scratch = scratch,
       _permits = Semaphore(tabs) {
    _socket.listen(_dispatch, onDone: _lost, onError: (Object _) => _lost());
  }

  /// Whether this client has been closed, or its browser has gone — quit, crashed or killed.
  bool get isClosed => _closed || _gone;

  /// Whether this run started the browser, rather than joining one already up.
  ///
  /// Always true for [launch] and false for [attach]; [connect] is whichever was needed, and
  /// this is the only way to find out which. It is what decides whether the settings that
  /// describe how to *start* a browser — `proxy:`, `headless:`, `args:` — applied at all.
  bool get isNewBrowser => _started;

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
    if (own != null) {
      if (await _heldBy(own) case final holder?) {
        throw ClientException(
          'Chrome will not start on ${own.path}: $holder is already using that profile. '
          'Quit it, wait for the other run to finish, or give this one a profile of its own.',
        );
      }
      await File('${dir.path}/DevToolsActivePort').delete().catchError((Object _) => File(''));
    }
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
        started: true,
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

  /// Connects to a Chrome already running with `--remote-debugging-port=<port>`.
  ///
  /// A [proxy] reaches the plain client underneath and this client's proxy authentication,
  /// but not the browser: a browser already running keeps the route it was started with. To
  /// put the pages through a proxy too, start it with `--proxy-server` or use [launch].
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
    Device device = Device.desktop,
    Uri? proxy,
    bool stealth = true,
    Set<Resource> block = const {},
    Client? assets,
  }) async {
    final endpoint = await _devtools(host, port);
    if (endpoint == null) {
      throw ClientException('No Chrome is listening on $host:$port. ${_howToStart(port)}');
    }
    return ChromeClient._(
      await WebSocket.connect(endpoint.toString()),
      assets: assets,
      timeout: timeout,
      challenge: challenge,
      wait: wait,
      tabs: tabs,
      device: device,
      proxy: proxy,
      started: false,
      stealth: stealth,
      block: block,
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
  /// [executable], [args] and [proxy] describe how to *start* one and are ignored when none
  /// is needed. A [proxy] still reaches the plain client underneath either way, so a run that
  /// joins an existing browser downloads through the proxy and renders around it; when that
  /// matters, quit the browser first or give it a [profile] of its own.
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
    final started = await _devtools(host, port) == null;
    if (started) {
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
      while (await _devtools(host, port) == null) {
        if (DateTime.now().isAfter(deadline)) {
          throw ClientException('Chrome did not open a debugging port on $host:$port within ${timeout.inSeconds}s');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    final client = await attach(
      port: port,
      host: host,
      tabs: tabs,
      timeout: timeout,
      challenge: challenge,
      wait: wait,
      device: device,
      proxy: proxy,
      stealth: stealth,
      block: block,
      assets: assets,
    );
    return client.._started = started;
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
    await _call('Runtime.enable', null, tab);
    await _call('Page.setLifecycleEventsEnabled', {'enabled': true}, tab);
    // A cross-origin iframe runs in a process of its own and is reachable only through a
    // session of its own, which Chrome opens for each one as it appears; see [ChromePage.frame].
    await _call('Target.setAutoAttach', {'autoAttach': true, 'waitForDebuggerOnStart': false, 'flatten': true}, tab);
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
    if (device.userAgent != null || device.locale != null) {
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
      final all = await _call('Storage.getCookies');
      final jar = <String>[
        for (final c in (all['cookies'] as List? ?? const []).cast<Map<String, Object?>>())
          if (_Jar._of(c).sendsTo(request.url)) '${c['name']}=${c['value']}',
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
      return _agent = version['userAgent'] as String?;
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

  /// The page this one is a frame of, or `null` when it is the tab itself.
  final ChromePage? _parent;

  /// Which execution context each frame of this tab evaluates in; filled by the tab's own
  /// page and read by every frame view of it.
  final Map<String, int> _contexts = {};

  StreamSubscription<_Cdp>? _events;
  FutureOr<void> Function(Dialog dialog)? _onDialog;
  Set<Resource>? _blocked;

  /// The credentials the render in progress carries, and the one origin they may go to.
  ({String origin, Map<String, String> headers})? _grant;

  /// What `Fetch.enable` was last told, so a render that changes nothing costs no round trip.
  String? _intercepting;
  Map<String, Object?>? _document;
  Completer<void>? _waiter;
  String _want = '';

  /// The loader of the document this page's frame last committed, the one a wait armed now
  /// must not hear from, and the one it waits for once a navigation has named it. A late
  /// `networkIdle` from the page before is otherwise the new page settling, with no body yet.
  String? _loader;
  String? _stale;
  String? _expect;

  /// The document response of the navigation in progress, even one that commits nothing.
  Map<String, Object?>? _answer;

  /// Out-of-process frames under this tab, by frame id: the session Chrome attached for each,
  /// and the URL it was last at.
  final Map<String, ({String session, String url})> _remotes = {};

  /// Whether this is an out-of-process frame, driven through a session of its own.
  final bool _remote;
  String _frame = '';
  Uri _url = Uri.parse('about:blank');
  bool _alive = true;

  ChromePage._(this._client, this._tab, {ChromePage? parent, bool remote = false}) : _parent = parent, _remote = remote;

  /// The page for the tab itself, which is this one unless this is a frame view.
  ChromePage get _owner => _parent ?? this;

  /// The context a frame's scripts run in; `null` for the tab, whose default context is the
  /// one Chrome evaluates in anyway.
  int? get _context => _parent == null || _remote ? null : _owner._contexts[_frame];

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
    _arm(wait._lifecycle);
    _answer = null;
    // A frame view navigates its frame; without the id, Chrome would move the whole tab.
    final nav = await _call('Page.navigate', {'url': '$url', if (_parent != null && !_remote) 'frameId': _frame});
    if (nav['errorText'] case final String error when error.isNotEmpty) {
      _disarm();
      // A 204 or 205 is an answer that keeps the page where it was, and Chrome reports it as
      // an aborted navigation. It is a response — the server said "nothing to show".
      if (error.contains('ERR_ABORTED')) {
        if (await _empty(url, request) case final answered?) return answered;
      }
      throw ClientException(_readable(error), url);
    }
    if (nav['frameId'] case final String frame when frame.isNotEmpty && _parent == null) _frame = frame;
    if (nav['loaderId'] case final String loader when loader.isNotEmpty) _loader = _expect = loader;
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

  /// The bodiless answer an aborted navigation got, if it got a 204 or 205; the event may
  /// trail the command's reply by a moment.
  Future<Response?> _empty(Uri url, Request? request) async {
    for (var i = 0; i < 25 && _answer == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final answer = _answer;
    final status = (answer?['status'] as num?)?.toInt();
    if (status != 204 && status != 205) return null;
    final headers = Headers();
    if (answer?['headers'] case final Map<String, Object?> raw) {
      raw.forEach((name, value) => headers[name] = '$value');
    }
    return Response.bytes(Uint8List(0), status!, headers: headers, request: request, url: url);
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
    try {
      final (x, y) = _centre(await _box(selector) ?? (throw const ClientException('no box')));
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
      // Off-screen, zero-sized, covered or not there: the DOM's own click still runs the
      // handler of one that is there, and answers false for one that is not.
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
      'contextId': ?_context,
    }, timeout);
    if (result['exceptionDetails'] case final Map<String, Object?> thrown) {
      throw ClientException('Page script failed: ${thrown['text'] ?? thrown}');
    }
    return (result['result'] as Map<String, Object?>?)?['value'];
  }

  /// A PNG: the window as the person in front of it would see it, one element when
  /// [selector] names one, or the whole scrollable document with [full].
  ///
  /// For a log, a report, or a look at the challenge that will not clear. Empty when
  /// [selector] matched nothing or matched something with no box on the page.
  Future<Uint8List> screenshot({String? selector, bool full = false}) async {
    final params = <String, Object?>{'format': 'png'};
    if (selector != null) {
      final quad = await _box(selector);
      if (quad == null) return Uint8List(0);
      params['clip'] = {
        'x': quad[0],
        'y': quad[1],
        'width': quad[2] - quad[0],
        'height': quad[5] - quad[1],
        'scale': 1,
      };
    } else if (full) {
      final metrics = await _call('Page.getLayoutMetrics');
      final size = (metrics['cssContentSize'] ?? metrics['contentSize']) as Map<String, Object?>?;
      params
        ..['captureBeyondViewport'] = true
        ..['clip'] = {'x': 0, 'y': 0, 'width': size?['width'] ?? 0, 'height': size?['height'] ?? 0, 'scale': 1};
    }
    final shot = await _call('Page.captureScreenshot', params);
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
    final quad = await _box(selector);
    if (quad == null) return false;
    final (x, y) = _centre(quad);
    try {
      await _call('Input.dispatchMouseEvent', {'type': 'mouseMoved', 'x': x, 'y': y});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Refuses to load [kinds] in this tab from now on; `block({})` allows everything again.
  ///
  /// The largest single thing a rendered crawl can do for itself. A page whose images, fonts
  /// and media never arrive looks nothing like itself and says exactly the same words, in a
  /// fraction of the bytes and a fraction of the time — `page.block(Resource.heavy)` is that
  /// trade, and the client takes it for every render when it is built with `block:`.
  Future<void> block(Set<Resource> kinds) async {
    _blocked = kinds;
    await _intercept();
  }

  /// Tells Chrome which requests to pause, when that is not what it was last told: every one
  /// for a proxy with credentials — `--proxy-server` cannot carry a password, so it is answered
  /// over the protocol — and for a render with an `authorization`, which is added to its own
  /// origin's requests as they pass; otherwise only the blocked kinds. A round trip a request
  /// is the price of a credential, paid only where there is one.
  Future<void> _intercept() async {
    final authenticating = _client._proxy?.userInfo.isNotEmpty ?? false;
    final everything = authenticating || _grant != null;
    final kinds = _blocked ?? const <Resource>{};
    final want = everything
        ? '*${authenticating ? '+auth' : ''}'
        : (kinds.map((k) => k.name).toList()..sort()).join(',');
    if (want == _intercepting) return;
    _intercepting = want;
    if (want.isEmpty) return _call('Fetch.disable').then((_) {});
    await _call('Fetch.enable', {
      'patterns': everything
          ? [
              {'urlPattern': '*', 'requestStage': 'Request'},
            ]
          : [
              for (final kind in kinds)
                for (final type in kind._types) {'urlPattern': '*', 'resourceType': type, 'requestStage': 'Request'},
            ],
      if (authenticating) 'handleAuthRequests': true,
    });
  }

  /// Gives the browser the cookies in [header] for [url] alone — never as a header every
  /// request of the tab would carry.
  Future<void> _plant(String header, Uri url) async {
    final cookies = [
      for (final pair in header.split(';'))
        if (pair.indexOf('=') case final eq when eq > 0)
          {
            'name': pair.substring(0, eq).trim(),
            'value': pair.substring(eq + 1).trim(),
            'url': '${url.removeFragment()}',
          },
    ];
    if (cookies.isNotEmpty) await _call('Network.setCookies', {'cookies': cookies});
  }

  /// Runs [action] and waits for the download it starts, answering where the file landed.
  ///
  /// The wait is armed before [action] for the reason [waitForNavigation] is: a click that starts a
  /// download returns at once, and a small file can be on disk before the next line runs.
  /// [to] is the directory it is moved into once it is complete, the working directory
  /// unless another is named, and the file keeps the name the site gave it — `name (2).ext`
  /// when a file there already has it, which is never overwritten. A download that
  /// never starts, one that stalls, or one the browser cancels answers `null` rather than
  /// throwing — and leaves nothing behind: a stalled one is cancelled and its partial erased.
  ///
  /// Chrome writes into a directory of the client's own and only a finished file is moved to
  /// [to], so nothing half-written appears there, two waits cannot swap files, and a download
  /// nobody waited for is erased with the client instead of left in the working directory.
  ///
  /// **[timeout] is how long the download may go quiet for, not how long it may take.** A
  /// download is a stream of events rather than one of them, so a deadline on the whole
  /// transfer gives up on big files and slow links for no reason — a book coming down a free
  /// proxy makes steady progress the entire way and would fail a thirty-second total every
  /// time. Silence is the thing worth giving up on, and a transfer that has died goes quiet at
  /// once, so waiting on silence is both more patient and quicker to notice a real failure.
  ///
  /// ```dart
  /// final file = await page.waitForDownload(() => page.click('.download'), to: 'books'.path);
  /// ```
  Future<Path?> waitForDownload(FutureOr<void> Function() action, {Path? to, Duration? timeout}) async {
    final landing = Path((await _client._downloads()).path);
    String? id;
    String? suggested;
    var stirred = DateTime.now();
    final finished = Completer<bool>();
    void done(bool ok) {
      if (!finished.isCompleted) finished.complete(ok);
    }

    final watch = _client._browser.stream.listen((event) {
      switch (event.method) {
        case 'Browser.downloadWillBegin':
          if (id != null) return;
          final guid = event.params['guid'] as String?;
          if (guid == null || _client._claimed.contains(guid)) return;
          // This page's own, or one from a tab no page here owns — a `target=_blank` link
          // downloads from the tab it opens — but never another page's.
          final from = event.params['frameId'];
          if (_frame.isNotEmpty && from != _frame && _client._pages.any((p) => p != _owner && p._frame == from)) return;
          _client._claimed.add(guid);
          id = guid;
          suggested = event.params['suggestedFilename'] as String?;
          stirred = DateTime.now();
        case 'Browser.downloadProgress':
          if (event.params['guid'] != id) return;
          // Every one of these is proof the transfer is alive, whatever it says.
          stirred = DateTime.now();
          if (event.params['state'] case 'completed') done(true);
          if (event.params['state'] case 'canceled') done(false);
      }
    });
    try {
      await action();
      if (!await _untilQuiet(finished, () => stirred, timeout ?? _client._timeout)) {
        if (id case final guid?) await _client._abandon(guid, landing);
        return null;
      }
      final into = (to ?? Path.current).absolute;
      await into.mkdir();
      final wanted = await _unused(into, _fileName(suggested ?? id!));
      await (landing / id!).move(wanted.path);
      return wanted;
    } finally {
      await watch.cancel();
      if (id case final guid?) _client._claimed.remove(guid);
      await _client._released();
    }
  }

  /// Runs [action] and answers the first response whose URL contains [match].
  ///
  /// The JSON behind the page rather than the page: a click that fires an XHR, and the XHR's
  /// own body instead of the DOM it eventually becomes. Armed before [action], like every
  /// wait here, and `null` when nothing matched before [timeout] or the body was gone by the
  /// time it was asked for.
  ///
  /// ```dart
  /// final page2 = await page.waitForResponse('/api/items', () => page.click('.next'));
  /// for (final item in page2!.json['items']) { ... }
  /// ```
  Future<Response?> waitForResponse(String match, FutureOr<void> Function() action, {Duration? timeout}) async {
    String? id;
    Map<String, Object?>? answered;
    final finished = Completer<void>();
    final watch = _client._sessions[_tab.session]?.stream.listen((event) {
      switch (event.method) {
        case 'Network.responseReceived':
          if (id != null) return;
          final res = event.params['response'] as Map<String, Object?>?;
          if (res == null || !'${res['url']}'.contains(match)) return;
          id = event.params['requestId'] as String?;
          answered = res;
        case 'Network.loadingFinished':
          if (event.params['requestId'] == id && !finished.isCompleted) finished.complete();
      }
    });
    try {
      // The action's own failure is the caller's, as it is for [waitForNavigation].
      await action();
      await finished.future.timeout(timeout ?? _client._timeout, onTimeout: () {});
      final res = answered;
      if (res == null) return null;
      try {
        final body = await _call('Network.getResponseBody', {'requestId': id});
        final raw = body['body'] as String? ?? '';
        final headers = Headers();
        if (res['headers'] case final Map<String, Object?> sent) {
          sent.forEach((name, value) => headers[name] = '$value');
        }
        return Response.bytes(
          body['base64Encoded'] == true ? base64.decode(raw) : utf8.encode(raw),
          (res['status'] as num?)?.toInt() ?? 200,
          headers: headers,
          url: Uri.tryParse('${res['url']}'),
        );
      } catch (_) {
        // The body was evicted from the network cache, or the tab moved on while it was asked
        // for. Either way there is nothing to answer with, and nothing has gone wrong.
        return null;
      }
    } finally {
      await watch?.cancel();
    }
  }

  /// Puts [files] into the first file input [selector] matches, as a person choosing them
  /// would. Answers `false` when nothing matched.
  Future<bool> upload(String selector, List<Path> files) async {
    final node = await _node(selector);
    if (node == null) return false;
    await _call('DOM.setFileInputFiles', {
      'nodeId': node,
      'files': [for (final file in files) file.absolute.path],
    });
    return true;
  }

  /// Loads this tab's URL again, and waits. Answers whether it settled before [timeout].
  Future<bool> reload({ChromeWait? until, Duration? timeout}) async {
    _arm((until ?? _client._wait)._lifecycle);
    await _call('Page.reload');
    return _settle(timeout);
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
  /// await page.waitForNavigation(() => page.click('a.next'));
  /// print(page.url);
  /// ```
  Future<bool> waitForNavigation(FutureOr<void> Function() action, {ChromeWait? until, Duration? timeout}) async {
    final wait = until ?? _client._wait;
    _arm(wait._lifecycle);
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
  Future<bool> back({ChromeWait? until, Duration? timeout}) => _history(-1, until, timeout);

  /// Goes forward one entry, and waits. Answers `false` when there is nothing ahead.
  Future<bool> forward({ChromeWait? until, Duration? timeout}) => _history(1, until, timeout);

  Future<bool> _history(int step, ChromeWait? until, Duration? timeout) async {
    final history = await _call('Page.getNavigationHistory');
    final index = (history['currentIndex'] as int? ?? 0) + step;
    final entries = (history['entries'] as List? ?? const []).cast<Map<String, Object?>>();
    if (index < 0 || index >= entries.length) return false;
    final was = _url;
    _arm((until ?? _client._wait)._lifecycle);
    await _call('Page.navigateToHistoryEntry', {'entryId': entries[index]['id']});
    // A page the back/forward cache restores is not loaded again and fires no second `load`,
    // so the lifecycle wait on its own would sit out the whole timeout on the commonest kind
    // of back. The URL moving is the other proof the tab went, and either one will do.
    final moved = await Future.any([_settle(timeout), _left(was, timeout)]);
    _disarm();
    return moved;
  }

  /// Waits for [finished], giving up only once [last] has stood still for [idle].
  ///
  /// The wait a download needs: it ends when the download does, or when nothing has happened
  /// for long enough that nothing is going to. A transfer that is merely slow keeps moving
  /// [last] and is waited out however long it takes.
  static Future<bool> _untilQuiet(Completer<bool> finished, DateTime Function() last, Duration idle) async {
    while (!finished.isCompleted) {
      if (DateTime.now().difference(last()) >= idle) return false;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return finished.future;
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

  /// This browser's cookies, and the way to give it some.
  ///
  /// `page.cookies()` reads them — after a login, to hand to something that is not a browser.
  /// `page.cookies(saved)` puts [saved] in first, which is how a session a person logged into
  /// by hand once becomes the session every run after it has. A cookie that names no domain
  /// is attached to the page the tab is on. Cookies belong to the browser rather than to the
  /// tab, so what one tab is given, every tab has.
  Future<List<Cookie>> cookies([List<Cookie>? restore]) async {
    if (restore != null && restore.isNotEmpty) {
      await _call('Network.setCookies', {
        'cookies': [
          for (final c in restore)
            <String, Object?>{
              'name': c.name,
              'value': c.value,
              'domain': ?c.domain,
              'path': ?c.path,
              'secure': c.secure,
              'httpOnly': c.httpOnly,
              if (c.expires case final expiry?) 'expires': expiry.millisecondsSinceEpoch / 1000,
              if (c.domain == null) 'url': '$_url',
            },
        ],
      });
    }
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

  /// What to do when the page opens a dialog; answers the function that undoes the
  /// registration, and `onDialog(null)` forgets it.
  ///
  /// The handler answers with [Dialog.accept] or [Dialog.dismiss]. One that answers with
  /// neither — or that throws — leaves the default, so a handler that only wants to *read*
  /// the message need not remember to close it.
  ///
  /// ```dart
  /// page.onDialog((d) => d.accept(d.type == 'prompt' ? 'yes' : null));
  /// ```
  void Function() onDialog(FutureOr<void> Function(Dialog dialog)? handler) {
    _onDialog = handler;
    return () {
      if (identical(_onDialog, handler)) _onDialog = null;
    };
  }

  /// Answers a dialog, whatever the handler did with it.
  ///
  /// It must be answered. Chrome holds the renderer on an open dialog, so a tab that ignores
  /// one is a tab that will never load, evaluate or close again — and this client's tabs go
  /// back into a pool, so one page's `alert()` would take the crawl's tab with it. Without a
  /// handler the answer is a dismissal, which is what a page with nobody in front of it gets;
  /// `beforeunload` is the exception, because dismissing that one cancels the navigation that
  /// raised it.
  Future<void> _dialog(Map<String, Object?> params) async {
    final dialog = Dialog._(
      this,
      params['type'] as String? ?? 'alert',
      params['message'] as String? ?? '',
      params['defaultPrompt'] as String? ?? '',
    );
    try {
      await _onDialog?.call(dialog);
    } catch (_) {}
    await (dialog.type == 'beforeunload' ? dialog.accept() : dialog.dismiss());
  }

  /// The iframe whose URL or `name` contains [match], as a page of its own.
  ///
  /// Everything on [ChromePage] then works inside it — `text`, `click`, `fill`, `waitFor`,
  /// `eval`, `goto` — because what comes back *is* a [ChromePage]. That is the whole reason
  /// this is one method and not a second vocabulary: a checkout form, a comment widget and a
  /// captcha box each live in a frame, none of them can be reached with a selector from the
  /// document around them, and none of them needs a word of its own to be worked with.
  ///
  /// ```dart
  /// final form = await page.frame('checkout');
  /// await form!.fill('#card', '4242…');
  /// await form.click('button[type=submit]');
  /// ```
  ///
  /// Answers `null` when nothing matches. What comes back is a view of part of this tab, so
  /// closing it closes nothing; close the page it came from.
  Future<ChromePage?> frame(String match) async {
    final owner = _owner;
    final tree = await owner._call('Page.getFrameTree');
    var found = _descend((tree['frameTree'] as Map<String, Object?>?) ?? const {}, match, root: true);
    // A cross-origin frame is not in the tree; it is found by its URL, or by the `name` on
    // the `<iframe>` that holds it.
    found ??= await owner._remoteMatching(match);
    if (found == null) return null;
    final (id, at) = found;
    final page = switch (owner._remotes[id]) {
      // Out of process: its own session, whose default context is that frame's document.
      final remote? => ChromePage._(_client, _Tab(id, remote.session), parent: owner, remote: true),
      null => ChromePage._(_client, _tab, parent: owner),
    };
    page
      .._frame = id
      .._url = Uri.tryParse(at) ?? _url;
    if (page._remote) {
      for (final method in ['Page.enable', 'Runtime.enable', 'Network.enable']) {
        await page._call(method);
      }
      await page._call('Page.setLifecycleEventsEnabled', {'enabled': true});
    }
    page._listen();
    return page;
  }

  /// The out-of-process frame whose URL or `<iframe name>` contains [match], as its id and URL.
  Future<(String, String)?> _remoteMatching(String match) async {
    for (final MapEntry(:key, :value) in _remotes.entries) {
      if (value.url.contains(match)) return (key, value.url);
      try {
        final holder = await _call('DOM.getFrameOwner', {'frameId': key});
        final node = await _call('DOM.describeNode', {'backendNodeId': holder['backendNodeId']});
        final attributes = ((node['node'] as Map<String, Object?>?)?['attributes'] as List?) ?? const [];
        for (var i = 0; i + 1 < attributes.length; i += 2) {
          final name = '${attributes[i + 1]}';
          if (attributes[i] == 'name' && name.isNotEmpty && name.contains(match)) return (key, value.url);
        }
      } catch (_) {}
    }
    return null;
  }

  /// The first frame under [node] whose URL or name contains [match], as its id and its URL.
  /// The tree is rooted at the page itself, which is never a match for one of its own frames.
  static (String, String)? _descend(Map<String, Object?> node, String match, {bool root = false}) {
    if (!root) {
      if (node['frame'] case final Map<String, Object?> frame) {
        final url = '${frame['url'] ?? ''}';
        final name = '${frame['name'] ?? ''}';
        if (url.contains(match) || (name.isNotEmpty && name.contains(match))) {
          return (frame['id'] as String? ?? '', url);
        }
      }
    }
    for (final child in (node['childFrames'] as List? ?? const []).cast<Map<String, Object?>>()) {
      if (_descend(child, match) case final hit?) return hit;
    }
    return null;
  }

  /// Closes the tab. Safe twice, and on a [frame] view it closes nothing, because a view of
  /// part of a tab does not own the tab.
  Future<void> close() async {
    if (!_alive) return;
    _alive = false;
    if (_parent != null) return _events?.cancel().then((_) {});
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
    if (!_alive) return Future.error(ClientException('The page is closed', _url));
    return _client._call(method, params, _tab, timeout);
  }

  /// The middle of a content box.
  static (num, num) _centre(List<num> quad) => ((quad[0] + quad[4]) / 2, (quad[1] + quad[5]) / 2);

  /// The content box of the first element [selector] matches, scrolled into view, or `null`
  /// when nothing matches or it has no box.
  Future<List<num>?> _box(String selector) async {
    final node = await _node(selector);
    if (node == null) return null;
    try {
      await _call('DOM.scrollIntoViewIfNeeded', {'nodeId': node});
      final box = await _call('DOM.getBoxModel', {'nodeId': node});
      final quad = ((box['model'] as Map<String, Object?>?)?['content'] as List?)?.cast<num>();
      return quad == null || quad.length < 6 ? null : quad;
    } catch (_) {
      return null;
    }
  }

  Future<int?> _node(String selector) async {
    try {
      final doc = await _call('DOM.getDocument', {'depth': 0});
      Object? root = (doc['root'] as Map<String, Object?>?)?['nodeId'];
      if (_parent != null && !_remote) {
        // A frame's nodes are not in the document around it; the way in is the `<iframe>`
        // element that owns the frame, and the document hanging off it.
        final owner = await _call('DOM.getFrameOwner', {'frameId': _frame});
        final described = await _call('DOM.describeNode', {'backendNodeId': owner['backendNodeId'], 'depth': 1});
        root = ((described['node'] as Map<String, Object?>?)?['contentDocument'] as Map<String, Object?>?)?['nodeId'];
        if (root == null) return null;
      }
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
        case 'Runtime.executionContextCreated':
          final context = event.params['context'] as Map<String, Object?>?;
          final about = context?['auxData'] as Map<String, Object?>?;
          if (about?['frameId'] case final String frame) {
            _owner._contexts[frame] = (context!['id'] as num).toInt();
          }
        case 'Runtime.executionContextsCleared':
          _owner._contexts.clear();
        case 'Network.responseReceived':
          final params = event.params;
          if (params['type'] != 'Document') return;
          // A challenge renders inside an iframe; only the main frame is this page.
          if (_frame.isNotEmpty && params['frameId'] != _frame) return;
          final answer = params['response'] as Map<String, Object?>?;
          _answer = answer;
          // A 204 leaves the document where it was, and its status is not that document's.
          if (answer?['status'] case 204 || 205) return;
          _document = answer;
        case 'Page.frameNavigated':
          final frame = event.params['frame'] as Map<String, Object?>?;
          if (frame == null) return;
          if (_owner._remotes[frame['id']] case final remote? when frame['url'] is String) {
            _owner._remotes[frame['id'] as String] = (session: remote.session, url: frame['url'] as String);
          }
          if (_frame.isNotEmpty && frame['id'] != _frame) return;
          if (frame['url'] case final String moved) _url = Uri.tryParse(moved) ?? _url;
          if (frame['loaderId'] case final String loader) _loader = loader;
        case 'Page.navigatedWithinDocument':
          // `pushState`, `replaceState` and a `#hash` move the URL without a document, so no
          // lifecycle event follows; the move itself is the navigation a wait was armed for.
          if (_frame.isNotEmpty && event.params['frameId'] != _frame) return;
          if (event.params['url'] case final String moved) _url = Uri.tryParse(moved) ?? _url;
          final waiter = _waiter;
          if (_expect == null && waiter != null && !waiter.isCompleted) waiter.complete();
        case 'Target.attachedToTarget' when _parent == null:
          final info = event.params['targetInfo'] as Map<String, Object?>?;
          final session = event.params['sessionId'];
          if (info?['type'] != 'iframe' || session is! String) return;
          _client._sessions[session] ??= StreamController<_Cdp>.broadcast();
          _remotes[info!['targetId'] as String] = (session: session, url: '${info['url'] ?? ''}');
        case 'Target.detachedFromTarget' when _parent == null:
          final session = event.params['sessionId'];
          _remotes.removeWhere((_, remote) => remote.session == session);
          unawaited(_client._sessions.remove(session)?.close());
        case 'Fetch.requestPaused' when _parent == null:
          // With an authenticating proxy everything pauses here, so what is refused is decided
          // by the kind rather than by having arrived: a paused request this page does not
          // block is sent on its way.
          final kind = '${event.params['resourceType']}';
          final refused = (_blocked ?? const <Resource>{}).any((r) => r._types.contains(kind));
          // A render's credentials go back to its own origin, as they would on a redirect, and
          // to no one else. `headers` replaces the request's rather than adding to them, so
          // they are the ones the request already had, and the grant on top of any it lacks.
          final paused = event.params['request'] as Map<String, Object?>?;
          final grant = _grant;
          final own = !refused && grant != null && _origin(Uri.tryParse('${paused?['url']}')) == grant.origin;
          unawaited(
            _call(refused ? 'Fetch.failRequest' : 'Fetch.continueRequest', {
              'requestId': event.params['requestId'],
              if (refused) 'errorReason': 'BlockedByClient',
              if (own) 'headers': _granted(paused?['headers'], grant.headers),
            }).catchError((Object _) => const <String, Object?>{}),
          );
        case 'Fetch.authRequired' when _parent == null:
          final proxy = _client._proxy;
          final colon = proxy?.userInfo.indexOf(':') ?? -1;
          unawaited(
            _call('Fetch.continueWithAuth', {
              'requestId': event.params['requestId'],
              'authChallengeResponse': proxy == null || proxy.userInfo.isEmpty
                  ? {'response': 'CancelAuth'}
                  : {
                      'response': 'ProvideCredentials',
                      'username': colon == -1 ? proxy.userInfo : proxy.userInfo.substring(0, colon),
                      'password': colon == -1 ? '' : proxy.userInfo.substring(colon + 1),
                    },
            }).catchError((Object _) => const <String, Object?>{}),
          );
        case 'Page.javascriptDialogOpening' when _parent == null:
          unawaited(_dialog(event.params));
        case 'Page.lifecycleEvent':
          if (event.params['name'] != _want) return;
          // A subframe finishing loading is not this page finishing loading, and a page whose
          // frames load first would otherwise settle before it had.
          if (_frame.isNotEmpty && event.params['frameId'] != _frame) return;
          // Nor is the document before this one finishing late.
          final loader = event.params['loaderId'];
          if (_expect != null ? loader != _expect : loader != null && loader == _stale) return;
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
    _stale = _loader;
    _expect = null;
  }

  void _disarm() {
    _want = '';
    _waiter = null;
    _expect = null;
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

/// A dialog the page opened: an `alert`, a `confirm`, a `prompt`, or the `beforeunload` a
/// page raises as it is being left.
///
/// See [ChromePage.onDialog]. Answering twice is answering once; the tab closing under it is
/// not an error.
///
/// {@category Networking}
final class Dialog {
  /// `alert`, `confirm`, `prompt` or `beforeunload`.
  final String type;

  /// What the page put in it.
  final String message;

  /// What a `prompt` was pre-filled with, empty for everything else.
  final String defaultValue;

  final ChromePage _page;
  var _answered = false;

  Dialog._(this._page, this.type, this.message, this.defaultValue);

  /// OK, with [text] as the answer to a `prompt`.
  Future<void> accept([String? text]) => _answer(true, text);

  /// Cancel.
  Future<void> dismiss() => _answer(false, null);

  Future<void> _answer(bool accept, String? text) async {
    if (_answered) return;
    _answered = true;
    try {
      await _page._call('Page.handleJavaScriptDialog', {'accept': accept, 'promptText': ?text});
    } catch (_) {
      // The tab went away under it, and a dialog on a closed tab holds nothing up.
    }
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

/// The request headers a paused request goes on with: its own, and [grant] where it named none.
List<Map<String, String>> _granted(Object? had, Map<String, String> grant) {
  final merged = Headers({
    if (had case final Map<String, Object?> own)
      for (final MapEntry(:key, :value) in own.entries) key: '$value',
  });
  grant.forEach((name, value) => merged.putIfAbsent(name, () => value));
  return [
    for (final MapEntry(:key, :value) in merged.entries) {'name': key, 'value': value},
  ];
}

/// Scheme, host and port: what a browser means by *the same site* for a credential.
String _origin(Uri? url) => url == null ? '' : '${url.scheme}://${url.host.toLowerCase()}:${url.port}';

/// [name] in [dir], or `name (2).ext`, `name (3).ext`… — the first that is not taken, so a
/// download never lands on a file that is already there.
Future<Path> _unused(Path dir, String name) async {
  final dot = name.indexOf('.', 1);
  final (stem, ext) = dot == -1 ? (name, '') : (name.substring(0, dot), name.substring(dot));
  var candidate = dir / name;
  for (
    var n = 2;
    await FileSystemEntity.type(candidate.path, followLinks: false) != FileSystemEntityType.notFound;
    n++
  ) {
    candidate = dir / '$stem ($n)$ext';
  }
  return candidate;
}

/// What a site's suggested name becomes on disk: the last segment of it, and never `..`.
///
/// Chrome sanitises the name it suggests; this is the second lock on the door, because the
/// name is the one part of the destination a remote host chooses.
String _fileName(String suggested) {
  final slash = suggested.lastIndexOf('/');
  final backslash = suggested.lastIndexOf(r'\');
  final lastSlash = slash > backslash ? slash : backslash;
  final raw = lastSlash == -1 ? suggested : suggested.substring(lastSlash + 1);
  final name = raw.trim();
  return name.isEmpty || name == '.' || name == '..' ? 'download' : name;
}

/// What a fresh profile would otherwise fetch on its own, in its first minute: ~40 MB of
/// optimization-guide models and hints, and translate's and the media router's services.
const _quiet = [
  'Translate',
  'MediaRouter',
  'OptimizationGuideModelDownloading',
  'OptimizationHintsFetching',
  'OptimizationTargetPrediction',
  'OptimizationHints',
];

/// The `sh` a launched Chrome runs under on macOS and Linux, so that it cannot outlive this
/// program: `sh -c _reaper <name> <scratch> <chrome> <args…>`.
///
/// Its stdin is a pipe only this process holds the other end of, so end-of-file on it arrives
/// the moment this process is gone however it went — `kill -9` included, which no exit hook
/// sees. Then: `SIGTERM` to the browser alone, which shuts down in order and writes its
/// cookies (its network process, signalled at the same moment, would die with them
/// unwritten), and `SIGKILL` to its process group five seconds later. However Chrome ends —
/// that, [ChromeClient.close] closing the pipe, a crash — the shell erases `<scratch>` and
/// exits with Chrome's status, which is how [_activePort] sees a browser that died starting.
/// It traps ^C and friends rather than dying of them: they reach this shell too, and a shell
/// killed by one would leave its cleanup undone.
const _reaper = r"""
exec 3<&0 </dev/null >/dev/null 2>&1
trap : INT TERM HUP
set -m
scratch=$1
shift
"$@" 3<&- &
chrome=$!
(
  trap - INT TERM HUP
  cat <&3
  sleep 2
  kill -TERM $chrome
  sleep 5
  kill -KILL -- -$chrome || kill -KILL $chrome
) &
watcher=$!
exec 3<&-
wait $chrome
status=$?
kill -KILL -- -$watcher || kill -KILL $watcher
rm -rf "$scratch"
exit $status
""";

/// Whether a launched Chrome runs under [_reaper]: everywhere there is a POSIX `sh`.
final _reaps = !Platform.isWindows;

/// Stops a launched browser: through its [_reaper] by closing the pipe it waits on — which
/// gives Chrome five seconds before it kills it, so this gives the reaper ten — else by
/// signal; `SIGKILL` either way when it will not go.
Future<void> _stop(Process process) async {
  _reaps ? await process.stdin.close().catchError((Object _) {}) : process.kill();
  await process.exitCode.timeout(
    Duration(seconds: _reaps ? 10 : 5),
    onTimeout: () => process.kill(ProcessSignal.sigkill) ? -9 : 0,
  );
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
    return Uri.tryParse(res.json['webSocketDebuggerUrl'].to<String>());
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

/// [executable], else `CHROME_PATH`, else the first of [_chromes] that is installed.
String _binary(String? executable) {
  if (executable ?? Platform.environment['CHROME_PATH'] case final path? when path.isNotEmpty) return path;
  for (final candidate in _chromes) {
    if (File(candidate).existsSync()) return candidate;
  }
  throw const ClientException('No Chrome found. Install Chrome or Chromium, set CHROME_PATH, or pass executable:.');
}

/// Who holds [profile], as Chrome's own lock records it, or `null` when nothing does.
///
/// The lock is a symlink named `SingletonLock` pointing at `<host>-<pid>`. It is read rather
/// than removed: a lock with a live browser behind it is not this program's to break.
Future<String?> _heldBy(Directory profile) async {
  final lock = Link('${profile.path}/SingletonLock');
  try {
    if (!await lock.exists()) return null;
    final target = await lock.target();
    final pid = int.tryParse(target.split('-').last);
    if (pid != null && !_isPidAlive(pid)) return null;
    return pid == null ? 'another browser' : 'a browser (pid $pid)';
  } catch (_) {
    return 'another browser';
  }
}

bool _isPidAlive(int pid) {
  try {
    return Platform.isWindows ? true : Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
  } catch (_) {
    return false;
  }
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

/// What `--proxy-server` wants: scheme, host and port, and never the credentials — those
/// cannot travel on a command line and are answered over the protocol instead.
String _server(Uri proxy) => '${proxy.scheme}://${proxy.host}:${proxy.port}';

/// `net::ERR_NAME_NOT_RESOLVED` says the same thing with less shouting.
String _readable(String error) =>
    error.startsWith('net::') ? error.substring(5).toLowerCase().replaceAll('_', ' ') : error;
