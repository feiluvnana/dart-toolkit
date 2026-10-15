/// Browser automation. Thin facade over `package:puppeteer`.
///
/// ```dart
/// final browser = await Chrome.launch(profile: '.chrome');
/// final page = await browser.open('https://example.com/login', block: ['image', 'font'])
///     .fill('#user', name).fill('#pass', password).click('button[type=submit]').wait('.dashboard');
/// await (page.screenshot(fullPage: true) > Fs.file('orders.png'));
/// await browser.close();
/// ```
///
/// Public surface is exactly: [Chrome], [Browser], [Page], [Download], [Capture], [BrowserException].
/// - `Chrome.launch/connect()` open a browser.
/// - [Browser] supports `open` `pages`.
/// - [Page] supports `go` `back` `reload` `url` `html` `text` `run`
///   `cookies` `cookie` `responses` `click` `fill` `press` `select` `upload`
///   `scroll` `wait` `idle`
///   `screenshot` `pdf` `download`.
/// - [Download] supports `name` (plus [Reader]).
/// - [Capture] is an XHR/fetch response the page received: `status` `url`
///   `header` (plus [Reader]).
/// - `page.cookies()` is a core [Cookies] jar, ready for `Http.client(cookies:)`.
/// - [BrowserException] is what a tab action throws when the page fails it.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:io' as io;

import 'package:path/path.dart' as p;
import 'package:puppeteer/protocol/browser.dart' as proto;
import 'package:puppeteer/puppeteer.dart' as pp;

import 'html.dart';
import 'json.dart';
import 'src/cache.dart' as cache;
import 'src/cookies.dart' as jar;
import 'src/exit.dart' as exit;
import 'src/glob.dart';
import 'src/keys.dart' as keys;
import 'src/origin.dart' as origin;
import 'src/tabs.dart';

export 'core.dart';
export 'html.dart';

/// Default bound on browser waits and actions.
const Duration _defaultTimeout = Duration(seconds: 30);

/// Entry point: launch or attach a browser.
abstract final class Chrome {
  /// Launch Chromium. Downloads it into the user cache on first use, unless
  /// [path] names a Chrome or Chromium binary. [profile] keeps
  /// cookies and logins between runs; without it, every launch starts fresh
  /// in a temp profile deleted on [Browser.close]. [proxy] routes every request
  /// (`http://host:port`, `socks5://host:port`). Throws when the browser
  /// can't start.
  static Future<Browser> launch({bool headless = true, String? path, String? profile, String? proxy}) async {
    var exe = path;
    exe ??= await _cachedExecutable();
    final args = <String>[if (proxy != null) '--proxy-server=$proxy'];
    final temp = profile == null ? await io.Directory.systemTemp.createTemp('puppeteer_dev_profile-') : null;
    final pp.Browser browser;
    try {
      browser = await pp.puppeteer.launch(
        headless: headless,
        executablePath: exe,
        userDataDir: profile ?? temp!.path,
        args: args.isEmpty ? null : args,
      );
    } catch (_) {
      try {
        await temp?.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
    final pid = browser.process?.pid;
    final dog = pid != null && pid > 1 && !io.Platform.isWindows ? await _watchdog(pid, temp?.path) : null;
    return Browser._(browser, owned: true, dog: dog, temp: temp);
  }

  /// A child that blocks on its stdin, which hits EOF when this VM dies for
  /// any reason (even an uncaught throw), then kills Chromium and removes the
  /// temp profile. The pid and dir are arguments, never interpolated.
  /// POSIX only; Windows has no watchdog yet.
  static Future<io.Process?> _watchdog(int pid, String? dir) async {
    try {
      return await io.Process.start('/bin/sh', [
        '-c',
        'cat >/dev/null; kill -9 "\$1" 2>/dev/null; sleep 1; [ -z "\$2" ] || rm -rf -- "\$2"',
        '_',
        '$pid',
        dir ?? '',
      ]);
    } catch (_) {
      return null;
    }
  }

  /// The machine-wide Chromium under `<user cache>/dart_toolkit/chrome`
  /// (one download per machine, not one per project). Downloads it on first
  /// use.
  static Future<String> _cachedExecutable() async {
    final dir = p.join(cache.userCacheDir(), 'dart_toolkit', 'chrome');
    final info = await pp.downloadChrome(cachePath: dir);
    return info.executablePath;
  }

  /// Attach to a running browser (`http://localhost:9222` or a `ws://` URL).
  /// Its [Browser.close] disconnects and leaves that browser running.
  static Future<Browser> connect(String url) async {
    final browser = url.startsWith('ws://') || url.startsWith('wss://')
        ? await pp.puppeteer.connect(browserWsEndpoint: url)
        : await pp.puppeteer.connect(browserUrl: url);
    return Browser._(browser, owned: false);
  }
}

/// An open browser. Owns its pages; one browser serves many pages.
/// Live owned browsers are tracked process-wide so a SIGTERM/SIGHUP (or a
/// cooked-terminal SIGINT/Ctrl-C) can still close Chromium and delete temp
/// profiles instead of orphaning them. A raw-terminal SIGINT (the TUI's
/// `ctrl+c` key) is left to the app.
final class Browser implements Closeable, TabHost {
  // ignore: prefer_initializing_formals – the public argument stays `owned`.
  Browser._(this._browser, {required bool owned, this._dog, this._temp}) : _owned = owned {
    if (owned) {
      // The single signal owner (src/exit.dart): the first hook installs the
      // watchers, the last removal cancels them so the VM may exit. Fixes
      // the never-exits-after-close hang (a live ProcessSignal.watch keeps
      // the VM alive) and the orphaned-Chromium race (one owner runs hooks
      // in reverse order, awaited and bounded, then exits once).
      _exitToken = exit.onExit(() async {
        try {
          await close();
        } catch (_) {}
      });
    }
  }

  final pp.Browser _browser;

  /// Whether [close] stops the process (launched) or disconnects (connected).
  final bool _owned;

  /// Orphan watchdog (see [Chrome.launch]) and the temp profile it removes.
  final io.Process? _dog;
  final io.Directory? _temp;

  /// Token for the exit hook above; removed in [close].
  Object? _exitToken;

  /// One cached [Page] wrapper per engine target: every `pages()` call for
  /// the same tab returns the same wrapper, so its dialog/traffic
  /// subscriptions are installed once, never leaked per call.
  final _wrappers = Expando<Page>();
  final _known = <Page>[];

  /// Tabs this wrapper opened: a connected browser's [close] closes these
  /// and leaves the host's own tabs alone.
  final _opened = <Page>{};

  /// One shared download folder per browser; concurrent downloads are told
  /// apart by their DevTools `guid`, so they never clash.
  String? _downloadDir;
  var _closed = false;

  /// Serializes download begins so concurrent `download()` calls don't
  /// share one `onDownloadWillBegin.first`.
  Future<void> _dlPrev = Future.value();

  /// Wrap an engine page, reusing the cached wrapper for its target.
  Page _wrap(pp.Page page) {
    final known = _wrappers[page];
    if (known != null) return known;
    final wrap = Page._(page, this);
    _wrappers[page] = wrap;
    _known.add(wrap);
    return wrap;
  }

  /// Open a new tab and wait for the load event. Tab setup goes here, before
  /// the first request: [headers] are extra request headers for everything
  /// the tab loads (`user-agent` also sets the UA string), [block]
  /// aborts requests by resource type (`'image'`, `'font'`, `'media'`,
  /// `'stylesheet'`), [width]/[height] set the viewport.
  /// [timeout] bounds the navigation. Dialogs are always dismissed.
  @override
  Future<Page> open(
    String url, {
    Map<String, String>? headers,
    List<String>? block,
    int? width,
    int? height,
    Duration? timeout,
  }) async {
    final limit = timeout ?? _defaultTimeout;
    final page = await _browser.newPage();
    final wrap = _wrap(page);
    _opened.add(wrap);
    try {
      if (width != null || height != null) {
        await page.setViewport(pp.DeviceViewport(width: width ?? 1280, height: height ?? 1024));
      }
      String? ua;
      Map<String, String>? extra;
      if (headers != null) {
        extra = Map.of(headers);
        for (final k in headers.keys.toList()) {
          if (k.toLowerCase() == 'user-agent') {
            ua = headers[k];
            extra.remove(k);
          }
        }
        if (extra.isEmpty) extra = null;
      }
      if (ua != null) {
        try {
          await page.setUserAgent(ua);
        } catch (_) {}
      }
      if (extra != null) {
        await page.setExtraHTTPHeaders(extra);
      }
      if (block != null && block.isNotEmpty) {
        await _block(page, wrap, block);
      }
      try {
        await page.goto(url, wait: pp.Until.load, timeout: limit).timeout(limit);
      } on TimeoutException {
        throw _Timeout('tab never loaded', limit, url);
      }
    } catch (_) {
      // Don't leak the tab when setup or navigation fails.
      try {
        await wrap.close();
      } catch (_) {}
      rethrow;
    }
    return wrap;
  }

  /// Every open tab, popups included (cached wrappers, one per tab).
  Future<List<Page>> pages() async => [for (final p in await _browser.pages) _wrap(p)];

  /// Close every tab and the process it launched (for a connected browser:
  /// close the tabs [open] made, then disconnect, leaving it running). Removes downloaded copies. Idempotent.
  /// Removes the exit hook; when the last hook goes the signal subscriptions
  /// are cancelled so the script may exit.
  @override
  Future<void> close() async {
    if (_closed) return;
    for (final wrap in List<Page>.of(_known)) {
      try {
        await wrap._detach();
      } catch (_) {}
      for (final dir in wrap._stagedDirs) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
      wrap._stagedDirs.clear();
    }
    final dir = _downloadDir;
    _downloadDir = null;
    if (dir != null) {
      try {
        await io.Directory(dir).delete(recursive: true);
      } catch (_) {}
    }
    if (_owned) {
      await _browser.close();
      // Only after a successful close: a failed one keeps the watchdog,
      // which still kills Chromium when this VM dies. The process is gone
      // by now, so the window for its pid to be reused is microseconds.
      _dog?.kill();
      try {
        await _temp?.delete(recursive: true);
      } catch (_) {}
    } else {
      // Wait for each target's destroyed event before disconnecting: the
      // engine still handles them after disconnect and throws from its
      // closed controller, uncaught.
      final opened = List<Page>.of(_opened);
      final gone = [
        for (final wrap in opened)
          _browser.onTargetDestroyed
              .firstWhere((t) => t == wrap._page.target)
              .timeout(const Duration(seconds: 2), onTimeout: () => wrap._page.target),
      ];
      for (final wrap in opened) {
        await wrap.close();
      }
      try {
        await Future.wait(gone);
      } catch (_) {}
      _browser.disconnect();
    }
    // A throw above allows a retry: only a successful close marks closed.
    _closed = true;
    _known.clear();
    final token = _exitToken;
    _exitToken = null;
    if (token != null) {
      try {
        exit.offExit(token);
      } catch (_) {}
    }
  }

  /// The shared download folder, created on first use.
  Future<String> _downloads() async {
    final existing = _downloadDir;
    if (existing != null) return existing;
    final dir = await io.Directory.systemTemp.createTemp('dart_toolkit_downloads');
    _downloadDir = dir.path;
    return dir.path;
  }

  static const _allowedBlock = {'image', 'font', 'media', 'stylesheet'};

  static Future<void> _block(pp.Page page, Page wrap, List<String> block) async {
    final blocked = <String>{};
    for (final b in block) {
      final lower = b.toLowerCase();
      if (!_allowedBlock.contains(lower)) {
        throw ArgumentError.value(block, 'block', 'unknown resource type "$b" (image, font, media, stylesheet)');
      }
      blocked.add(lower);
    }
    await page.setRequestInterception(true);
    wrap._blockSub = page.onRequest.listen((req) async {
      try {
        final type = req.resourceType?.toJson().toLowerCase();
        if (type != null && blocked.contains(type)) {
          await req.abort();
        } else {
          await req.continueRequest();
        }
      } catch (_) {
        // The tab went away mid-decision; dropping must not throw.
      }
    }, onError: (_) {});
  }
}

/// An open tab. Read it, drive it, wait on it, take content out of it.
final class Page implements Closeable, TabView {
  Page._(this._page, this._browser) {
    _dismiss();
    _trackTraffic();
  }

  final pp.Page _page;
  final Browser _browser;

  StreamSubscription<pp.Request>? _blockSub;
  StreamSubscription<pp.Dialog>? _dialogSub;
  final _trafficSubs = <StreamSubscription<dynamic>>[];

  /// Staged upload dirs (non-File readers): retained until this tab closes,
  /// since the browser reads them at submit, not at `uploadFile`.
  final _stagedDirs = <io.Directory>[];

  /// Requests in flight (for [idle]) and when each started on [_clock]:
  /// added on request, removed on finished/failed. Both sides see the same
  /// URLs (see [_countable]), so `data:`/`ws:` URLs never enter.
  final _inflight = Map<pp.Request, Duration>.identity();

  /// Completed whenever a request ends so [idle] wakes without polling the
  /// wall clock.
  Completer<void>? _idleNotified;

  /// When a request last ended, on [_clock].
  final _clock = Stopwatch()..start();
  var _settledAt = Duration.zero;

  var _closed = false;

  /// Idle when no request has been in flight for this long.
  static const _quietPeriod = Duration(milliseconds: 500);

  /// A request open this long is a long-poll, an event stream or a stream
  /// that may never end: from then on it no longer holds [idle].
  static const _longLived = Duration(seconds: 5);

  void _dismiss() {
    _dialogSub = _page.onDialog.listen((dialog) async {
      try {
        await dialog.dismiss();
      } catch (_) {}
    }, onError: (_) {});
  }

  void _trackTraffic() {
    _trafficSubs.addAll([
      _page.onRequest.listen((req) {
        if (!_countable(req.url)) return;
        _inflight[req] = _clock.elapsed;
      }, onError: (_) {}),
      _page.onRequestFinished.listen(_noteSettled, onError: (_) {}),
      _page.onRequestFailed.listen(_noteSettled, onError: (_) {}),
    ]);
  }

  /// Whether [url] touches the network. `data:` URLs, websockets and `wss:`
  /// never go idle, so neither side of the in-flight count sees them.
  static bool _countable(String url) {
    final lower = url.toLowerCase();
    if (lower.startsWith('data:') || lower.startsWith('ws:') || lower.startsWith('wss:')) {
      return false;
    }
    return true;
  }

  void _noteSettled(pp.Request req) {
    if (_inflight.remove(req) == null) return;
    _settledAt = _clock.elapsed;
    _idleNotified?.complete();
    _idleNotified = null;
  }

  /// Re-navigate this tab; waits for the load event. Returns this page.
  @override
  Future<Page> go(String url, {Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    try {
      await _page.goto(url, wait: pp.Until.load, timeout: limit).timeout(limit);
    } on TimeoutException {
      throw _Timeout('navigation timed out', limit, url);
    }
    return this;
  }

  /// Go back; waits for the load event. Returns this page.
  Future<Page> back({Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    try {
      await _page.goBack(wait: pp.Until.load, timeout: limit).timeout(limit);
    } on TimeoutException {
      throw _Timeout('navigation timed out', limit, await url());
    }
    return this;
  }

  /// Reload; waits for the load event. Returns this page.
  Future<Page> reload({Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    try {
      await _page.reload(wait: pp.Until.load, timeout: limit).timeout(limit);
    } on TimeoutException {
      throw _Timeout('navigation timed out', limit, await url());
    }
    return this;
  }

  /// The current URL.
  @override
  Future<String> url() async => _page.url ?? '';

  /// The rendered DOM as [Elements], with the page's URL as the base.
  /// Chain into it: `page.html().$('a')`.
  Future<Elements> html() async => Html.parse(await _page.content ?? '', base: await url());

  /// The page's `innerText`.
  Future<String> text() async => (await _page.evaluate<String?>('document.documentElement.innerText')) ?? '';

  /// Evaluate [js], awaiting it if it is a promise, reading the result
  /// with the `Json.value<T>()` rules (`null` for `null`, `undefined`, or
  /// a result that is not a `T`, so `??` gives the default; integral numbers
  /// read as both `int` and `double`). Collections read per element through
  /// [Json.asList]/[Json.asMap] on [Json.of]:
  ///
  /// ```dart
  /// final title = await page.run<String>('document.title') ?? '';
  /// final tags = Json.of(await page.run<dynamic>('["a", "b"]')).asList<String>();
  /// ```
  ///
  /// The decoded value is wrapped directly (`Json.of`): no `jsonEncode`
  /// round trip, no transient string.
  @override
  Future<T?> run<T>(String js) async {
    final v = await _page.evaluate<dynamic>(js);
    return Json.of(v).value<T>();
  }

  /// The cookies the current URL would send, as a [Cookies] jar with their
  /// domain, path, expiry and `secure` flag: hand it to
  /// `Http.client(cookies:)`, or persist it with `encode()`.
  Future<Cookies> cookies() async {
    final out = Cookies();
    for (final c in await _page.cookies(urls: [await url()])) {
      jar.addCookie(
        out,
        name: c.name,
        value: c.value,
        domain: c.domain,
        path: c.path,
        secure: c.secure,
        expires: c.expires > 0 ? DateTime.fromMillisecondsSinceEpoch((c.expires * 1000).round()) : null,
      );
    }
    return out;
  }

  /// Wait until the current URL has a cookie [name] (a login that sets
  /// `sessionid`), and return its value. Throws [TimeoutException] after
  /// [timeout], and [BrowserException] when the window is closed meanwhile.
  Future<String> cookie(String name, {Duration? timeout}) {
    final limit = timeout ?? _defaultTimeout;
    return _whileOpen(() async {
      final end = _clock.elapsed + limit;
      while (true) {
        if ((await cookies())[name] case final value?) return value;
        if (_clock.elapsed >= end) throw _Timeout('no cookie "$name"', limit, await url());
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }());
  }

  /// Every XHR/fetch response whose URL matches the glob [pattern]
  /// (`*/graphql/query*`; `*` crosses `/` here), while the stream is
  /// listened to: the exact JSON a single-page app loads, at no extra
  /// request. Ends when the tab closes.
  Stream<Capture> responses(String pattern) {
    final match = glob(pattern, paths: false);
    StreamSubscription<pp.Response>? sub;
    late final StreamController<Capture> out;
    out = StreamController<Capture>(
      onListen: () {
        sub = _page.onResponse.listen((r) {
          final type = r.request.resourceType;
          if ((type == pp.ResourceType.xhr || type == pp.ResourceType.fetch) && match.hasMatch(r.url)) {
            out.add(Capture._(r));
          }
        }, onError: (_) {});
        _closedSignal.then((_) => out.close());
      },
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }

  /// Completes when this tab or its browser goes away.
  late final Future<void> _closedSignal = Future.any([_page.onClose, _browser._browser.disconnected])
      .catchError((_) {});

  /// [work], or [BrowserException] `browser closed` when the window closes first.
  Future<T> _whileOpen<T>(Future<T> work, [String? selector]) {
    work.ignore();
    return Future.any([
      work,
      _closedSignal.then<T>(
        (_) => throw BrowserException(
          selector == null ? 'browser closed' : 'browser closed: wait $selector',
          selector: selector,
        ),
      ),
    ]);
  }

  /// Click the first match of [selector], waiting until it is actionable
  /// (up to [timeout]). The returned handle is clicked directly: no
  /// re-query between the wait and the click. Returns this page.
  Future<Page> click(String selector, {Duration? timeout}) => _act('click', selector, () async {
    await (await _actionable(selector, timeout: timeout)).click();
  });

  /// Replace the field's value keystroke by keystroke (firing `input` and
  /// `change`), waiting until it is actionable. Always clears first, so an
  /// empty [value] empties the field. Returns this page.
  ///
  /// Stays one CDP call per character on purpose: frameworks listen for key
  /// events, and an `insertText`-style bulk set would fire no `keydown`.
  Future<Page> fill(String selector, String value, {Duration? timeout}) => _act('fill', selector, () async {
    final handle = await _actionable(selector, timeout: timeout);
    await handle.focus();
    await handle.evaluate<void>(
      '(el) => { el.value = "";'
      ' el.dispatchEvent(new Event("input", {bubbles: true})); }',
    );
    if (value.isNotEmpty) {
      await handle.type(value);
    }
    await handle.evaluate<void>('(el) => { el.dispatchEvent(new Event("change", {bubbles: true})); }');
  });

  /// Send a key or a chord, with the key names shared with `Console`/`Tui`
  /// (`'enter'`, `'tab'`, `'down'`, `'ctrl+a'`; a single printable
  /// character is typed; `'wheelup'`/`'wheeldown'` scroll). Aliases (`'esc'`,
  /// `'cmd'`, `'control'`) canonicalize to the shared table; an unknown name
  /// is an [ArgumentError], never a silent mis-hit.
  /// Returns this page.
  Future<Page> press(String key) async {
    final lower = key.toLowerCase();
    if (lower == 'wheelup' || lower == 'wheeldown') {
      final dy = lower == 'wheelup' ? -400 : 400;
      return _act('press $key', null, () => _page.evaluate<void>('(dy) => window.scrollBy(0, dy)', args: [dy]));
    }
    // One key-name table (src/keys.dart, shared with console/tui):
    // canonicalize throws ArgumentError on unknown names, before any I/O.
    final canonical = keys.canonicalize(key);
    return _act('press $key', null, () => _press(canonical));
  }

  Future<void> _press(String canonical) async {
    if (canonical == '+') {
      await _page.keyboard.type('+');
      return;
    }
    final parts = canonical.split('+');
    if (parts.length == 1) {
      final single = parts[0];
      if (single.length == 1) {
        await _page.keyboard.type(single);
      } else {
        await _page.keyboard.press(_toKey(single));
      }
      return;
    }
    final mods = <pp.Key>[for (var i = 0; i < parts.length - 1; i++) _toModifier(parts[i])];
    for (final m in mods) {
      await _page.keyboard.down(m);
    }
    try {
      final main = parts.last;
      if (main.length == 1) {
        await _page.keyboard.type(main);
      } else {
        await _page.keyboard.press(_toKey(main));
      }
    } finally {
      for (final m in mods.reversed) {
        await _page.keyboard.up(m);
      }
    }
  }

  /// Pick the `<option>` by its value, waiting until actionable.
  /// Throws [BrowserException] when the option is missing. Returns this page.
  Future<Page> select(String selector, String value, {Duration? timeout}) => _act('select', selector, () async {
    final picked = await (await _actionable(selector, timeout: timeout)).select([value]);
    if (!picked.contains(value)) {
      throw BrowserException('no option "$value" in $selector', selector: selector);
    }
  });

  /// Set a file input from a [Reader]: the name and path come from the
  /// typed `file.origin()` (a `File` keeps its name; any other reader is
  /// staged under its origin name, else `upload`). File inputs are usually
  /// hidden, so this waits for *attached*, not visible. Staged copies are
  /// retained until this tab closes (the browser reads them at submit).
  /// Fires `input`/`change` so frameworks see the files. Returns this page.
  Future<Page> upload(String selector, Reader file, {Duration? timeout}) async {
    final staged = await _stage(file);
    final tmp = staged.tmpDir;
    if (tmp != null) _stagedDirs.add(tmp);
    try {
      await _act('upload', selector, () async {
        final handle = await _attached(selector, timeout: timeout);
        await handle.uploadFile([staged.file]);
        // Like fill: frameworks listen for input/change, not just the file list.
        try {
          await handle.evaluate<void>(
            '(el) => { el.dispatchEvent(new Event("input", {bubbles: true}));'
            ' el.dispatchEvent(new Event("change", {bubbles: true})); }',
          );
        } catch (_) {}
      });
    } catch (_) {
      // Don't leak staging when the upload itself failed.
      if (tmp != null) {
        _stagedDirs.remove(tmp);
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
      rethrow;
    }
    return this;
  }

  /// Bring the first match of [selector] into view, waiting until it is
  /// attached first (throws [TimeoutException] when it never attaches); with
  /// no selector, go to the bottom of the page (what infinite lists need).
  /// Returns this page.
  Future<Page> scroll([String? selector, Duration? timeout]) => _act('scroll', selector, () async {
    if (selector == null) {
      await _page.evaluate<void>('window.scrollTo(0, document.body.scrollHeight)');
    } else {
      await (await _attached(selector, timeout: timeout)).scrollIntoViewIfNeeded();
    }
  });

  /// Run one action's engine calls; returns this page. Our own errors
  /// (timeouts, [ToolkitException]s, [ArgumentError]s) pass through; any
  /// engine failure becomes a [BrowserException] naming the action and
  /// [selector], so no puppeteer type ever reaches the caller.
  Future<Page> _act(String what, String? selector, Future<void> Function() body) async {
    try {
      await body();
    } on TimeoutException {
      rethrow;
    } on ToolkitException {
      rethrow;
    } on ArgumentError {
      rethrow;
    } catch (e) {
      throw BrowserException('$what${selector == null ? '' : ' $selector'}: $e', selector: selector, cause: e);
    }
    return this;
  }

  /// Wait until [selector] is visible. Returns this page.
  /// Throws [BrowserException] `browser closed` when the window closes first.
  Future<Page> wait(String selector, {Duration? timeout}) async {
    await _whileOpen(_visible(selector, timeout: timeout), selector);
    return this;
  }

  /// Wait until there has been no request in flight for 500 ms. A request
  /// open longer than 5 s (a long-poll, an event stream) stops counting, so
  /// a page that keeps one open still settles. Wakes when a request ends or
  /// turns long-lived (a [Stopwatch] measures the quiet period; no
  /// wall-clock polling). Returns this page.
  Future<Page> idle({Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    final start = _clock.elapsed;
    for (;;) {
      final now = _clock.elapsed;
      final left = limit - (now - start);
      var wait = left;
      var busy = false;
      // Quiet since the last request ended, or since the last one still
      // open turned long-lived.
      var since = _settledAt;
      for (final opened in _inflight.values) {
        final lived = opened + _longLived;
        if (lived > now) {
          busy = true;
          if (lived - now < wait) wait = lived - now;
        } else if (lived > since) {
          since = lived;
        }
      }
      final quiet = now - since;
      if (!busy && quiet >= _quietPeriod) return this;
      if (left <= Duration.zero) {
        throw _Timeout('network never idle', limit, await url());
      }
      if (!busy && _quietPeriod - quiet < wait) wait = _quietPeriod - quiet;
      final notified = _idleNotified ??= Completer<void>();
      // A request ending, one turning long-lived, the quiet period end, or
      // the deadline — whichever comes first — re-checks the above.
      await notified.future.timeout(wait, onTimeout: () {});
    }
  }

  /// A PNG of the viewport (or the whole page with [fullPage]), captured
  /// when read.
  Reader screenshot({bool fullPage = false}) => _ShotReader(() => _page.screenshot(fullPage: fullPage));

  /// The page printed, captured when read.
  Reader pdf() => _ShotReader(() async {
    final bytes = await _page.pdf();
    if (bytes == null) {
      throw BrowserException('pdf failed: ${await url()}');
    }
    return bytes;
  });

  /// Click [selector] and wait for the download it starts to finish.
  /// Returns a [Download]: a [Reader] of the file plus the name the site
  /// suggested. Downloads share one folder per browser and are told apart
  /// by their DevTools `guid`, so concurrent downloads don't clash. The
  /// begin event is filtered on this tab's frame, so a download started by
  /// another tab inside the gate is never credited here. Begins are
  /// serialized; the whole call shares one [timeout] deadline. The
  /// browser's copies are removed when the browser closes.
  Future<Download> download(String selector, {Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    // Wait for the trigger first: on a missing selector this throws before
    // any download future exists that could fail unhandled later. The
    // returned handle is clicked directly: no re-query in between.
    final handle = await _actionable(selector, timeout: timeout);
    final elapsed = Stopwatch()..start();
    Duration left() {
      final rest = limit - elapsed.elapsed;
      return rest.isNegative ? Duration.zero : rest;
    }

    final frameId = _page.mainFrame.id;
    // Serialize begins: only one willBegin.first at a time.
    final prev = _browser._dlPrev;
    final gate = Completer<void>();
    _browser._dlPrev = gate.future;
    final String dir;
    final proto.DownloadWillBeginEvent begun;
    try {
      await prev.timeout(left());
      dir = await _browser._downloads();
      await _page.devTools.browser.setDownloadBehavior('allow', downloadPath: dir, eventsEnabled: true);
      // Browser-wide event, so filter on this tab's frame.
      final willBegin = _page.devTools.browser.onDownloadWillBegin
          .where((e) => e.frameId == frameId)
          .first
          .timeout(left(), onTimeout: () => throw _Timeout('no download from $selector', limit));
      // Guard the future until it is awaited below: without this, a click
      // that starts no download surfaces an unhandled TimeoutException.
      unawaited(willBegin.then((_) {}, onError: (_) {}));
      await handle.click();
      begun = await willBegin;
    } finally {
      gate.complete();
    }
    final terminal = _page.devTools.browser.onDownloadProgress
        .where((e) => e.guid == begun.guid)
        .firstWhere(
          (e) =>
              e.state == proto.DownloadProgressEventState.completed ||
              e.state == proto.DownloadProgressEventState.canceled,
        )
        .timeout(left(), onTimeout: () => throw _Timeout('download never finished', limit, begun.suggestedFilename));
    // Same guard: a download that never completes must not fail
    // unhandled after this call already threw elsewhere.
    unawaited(terminal.then((_) {}, onError: (_) {}));
    final finished = await terminal;
    if (finished.state != proto.DownloadProgressEventState.completed) {
      throw BrowserException('download ${finished.state.name}: ${begun.suggestedFilename}');
    }
    // The completed event fires when the file is final: no size polling.
    final path = finished.filePath ?? p.join(dir, begun.suggestedFilename);
    final safe = origin.stripPath(begun.suggestedFilename);
    return Download._(io.File(path), safe.isEmpty ? 'download' : safe);
  }

  /// Close this tab. Idempotent.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Prune from the browser's known wrappers so they don't retain stale subs.
    try {
      _browser._known.remove(this);
      _browser._opened.remove(this);
    } catch (_) {}
    await _detach();
    for (final dir in _stagedDirs) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
    _stagedDirs.clear();
    try {
      await _page.close();
    } catch (_) {
      // Already closed with the browser; dropping must not throw.
    }
  }

  /// Cancel the tab's subscriptions without closing the tab (used by
  /// [Browser.close], which tears the whole browser down at once).
  Future<void> _detach() async {
    final blockSub = _blockSub;
    _blockSub = null;
    try {
      await blockSub?.cancel();
    } catch (_) {}
    if (blockSub != null) {
      try {
        await _page.setRequestInterception(false);
      } catch (_) {}
    }
    try {
      await _dialogSub?.cancel();
    } catch (_) {}
    _dialogSub = null;
    for (final sub in _trafficSubs) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    _trafficSubs.clear();
  }

  Future<pp.ElementHandle> _attached(String selector, {Duration? timeout}) async =>
      _ready(selector, _ReadyMode.attached, timeout: timeout);

  Future<pp.ElementHandle> _visible(String selector, {Duration? timeout}) async =>
      _ready(selector, _ReadyMode.visible, timeout: timeout);

  Future<pp.ElementHandle> _actionable(String selector, {Duration? timeout}) async =>
      _ready(selector, _ReadyMode.actionable, timeout: timeout);

  /// One `waitForFunction` predicate (selector valid, attached, and — unless
  /// [mode] is attached-only — visible and enabled), polled every 50 ms
  /// (`requestAnimationFrame` pauses in a background headful tab), returning the [pp.ElementHandle] the action
  /// then uses: 1–2 CDP round trips per action instead of 4–6, with no
  /// TOCTOU gap between the check and the use. An invalid selector resolves
  /// fast with [ContentException], not a full-timeout wait.
  Future<pp.ElementHandle> _ready(String selector, _ReadyMode mode, {Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    final want = switch (mode) {
      _ReadyMode.attached => 'attached',
      _ReadyMode.visible => 'visible',
      _ReadyMode.actionable => 'action',
    };
    final kind = switch (mode) {
      _ReadyMode.attached => 'attached',
      _ReadyMode.visible => 'visible',
      _ReadyMode.actionable => 'actionable',
    };
    late final pp.JsHandle resolved;
    try {
      resolved = await _page
          .waitForFunction(_readyPredicate, args: [selector, want], timeout: limit, polling: _poll)
          .timeout(limit);
    } on TimeoutException {
      throw _Timeout('no $kind $selector', limit);
    } catch (e) {
      throw BrowserException('$kind $selector: $e', selector: selector, cause: e);
    }
    final element = resolved.asElement;
    if (element != null) return element;
    // The predicate resolves a non-element only for an invalid selector.
    try {
      if (await resolved.jsonValue == _invalidSelector) {
        throw ContentException("invalid selector '$selector'");
      }
    } on FormatException {
      rethrow;
    } catch (_) {}
    throw _Timeout('no $kind $selector', limit);
  }

  /// The-ready predicate: valid selector, attached, visible, enabled.
  /// Returns the element itself (truthy, so the wait resolves with its
  /// handle) or `false`; an invalid selector resolves the sentinel string.
  static const _readyPredicate = '''
(selector, mode) => {
  let el;
  try {
    el = document.querySelector(selector);
  } catch (_) {
    return 'invalid-selector';
  }
  if (!el) return false;
  if (mode === 'attached') return el;
  const rect = el.getBoundingClientRect();
  if (rect.width === 0 || rect.height === 0) return false;
  const style = getComputedStyle(el);
  if (style.visibility === 'hidden' || style.display === 'none') return false;
  if (mode === 'visible') return el;
  if (el.disabled || (el.getAttribute && el.getAttribute('aria-disabled') === 'true')) return false;
  return el;
}
''';

  static final _poll = pp.Polling.interval(const Duration(milliseconds: 50));

  /// Sentinel the predicate resolves when `querySelector` rejects the
  /// selector; kept next to the predicate it must match.
  static const _invalidSelector = 'invalid-selector';

  Future<_Staged> _stage(Reader file) async {
    // Typed origin only: name/path come from Reader.origin(), never probed.
    final o = file.origin();
    var name = o.name();
    if (name != null && name.isNotEmpty) name = origin.stripPath(name);
    if (name == null || name.isEmpty) name = 'upload';
    final keep = o.path();
    if (keep != null) {
      return _Staged(io.File(keep), tmpDir: null);
    }
    final tmp = await io.Directory.systemTemp.createTemp('dart_toolkit_up');
    final staged = io.File(p.join(tmp.path, name));
    try {
      await file.to(_FileWriter(staged));
    } catch (_) {
      // Don't leak the staging dir when the reader fails mid-write.
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
    return _Staged(staged, tmpDir: tmp);
  }

  /// A canonical key name (see `src/keys.dart`) to the engine key.
  /// Canonicalize throws first on unknown names; the throw below is
  /// defensive and unreachable through [press].
  static pp.Key _toKey(String name) => switch (name) {
    'enter' => pp.Key.enter,
    'tab' => pp.Key.tab,
    'escape' => pp.Key.escape,
    'backspace' => pp.Key.backspace,
    'up' => pp.Key.arrowUp,
    'down' => pp.Key.arrowDown,
    'left' => pp.Key.arrowLeft,
    'right' => pp.Key.arrowRight,
    'home' => pp.Key.home,
    'end' => pp.Key.end,
    'pageup' => pp.Key.pageUp,
    'pagedown' => pp.Key.pageDown,
    'delete' => pp.Key.delete,
    'insert' => pp.Key.insert,
    'space' => pp.Key.space,
    'f1' => pp.Key.f1,
    'f2' => pp.Key.f2,
    'f3' => pp.Key.f3,
    'f4' => pp.Key.f4,
    'f5' => pp.Key.f5,
    'f6' => pp.Key.f6,
    'f7' => pp.Key.f7,
    'f8' => pp.Key.f8,
    'f9' => pp.Key.f9,
    'f10' => pp.Key.f10,
    'f11' => pp.Key.f11,
    'f12' => pp.Key.f12,
    _ => throw ArgumentError.value(name, 'key', 'unknown key: $name'),
  };

  /// A canonical chord modifier to the engine key.
  static pp.Key _toModifier(String name) => switch (name) {
    'ctrl' => pp.Key.control,
    'alt' => pp.Key.alt,
    'shift' => pp.Key.shift,
    'meta' => pp.Key.meta,
    _ => throw ArgumentError.value(name, 'key', 'unknown modifier: $name'),
  };
}

/// What [_Page._ready] waits for: attached, visible, or visible + enabled.
enum _ReadyMode { attached, visible, actionable }

/// A finished browser download: a [Reader] of the file.
final class Download with Reader {
  Download._(this._file, this._name);

  final io.File _file;
  final String _name;

  /// The file name the site suggested, made safe like `Response.name()`.
  String name() => _name;

  @override
  Origin origin() => Origin(name: _name, path: _file.path);

  @override
  Stream<List<int>> stream() => _file.openRead();
}

/// An XHR/fetch response the page received ([Page.responses]). The body is
/// requested from the browser as the response arrives, so reading it later
/// still works after the page moves on. Readings use http's names.
final class Capture with Reader {
  Capture._(this._r) : _body = _r.bytes {
    _body.ignore();
  }

  final pp.Response _r;
  final Future<List<int>> _body;

  /// HTTP status.
  int status() => _r.status;

  /// The response URL.
  String url() => _r.url;

  /// Response header [name] (case-insensitive), or null.
  String? header(String name) => _r.headers[name];

  @override
  Origin origin() => Origin(url: _r.url, status: _r.status);

  @override
  Stream<List<int>> stream() => Stream.fromFuture(_body);

  @override
  Future<List<int>> bytes() => _body;
}

/// What a tab action throws when the page itself fails it: a click that
/// misses, a PDF that never renders, a download the site cancels. Extends
/// [StateError], so an existing `on StateError` keeps catching it.
final class BrowserException extends StateError implements ToolkitException {
  BrowserException(super.message, {this.selector, this.cause});

  /// The selector in use, when the failure names one.
  final String? selector;

  @override
  final Object? cause;
}

/// A [TimeoutException] that prints its limit once, for people:
/// `TimeoutException: no actionable #nope after 1 s` (the stock one prints
/// `after 0:00:01.000000` and the message carried it again).
final class _Timeout extends TimeoutException {
  _Timeout(String what, Duration limit, [String? subject])
    : super('$what after ${limit.human()}${subject == null ? '' : ': $subject'}', limit);

  @override
  String toString() => 'TimeoutException: $message';
}

/// Future mirrors (rule 4). The extension name is import-only; never reference it.
extension BrowserFuture on Future<Browser> {
  Future<Page> open(
    String url, {
    Map<String, String>? headers,
    List<String>? block,
    int? width,
    int? height,
    Duration? timeout,
  }) async => (await this).open(url, headers: headers, block: block, width: width, height: height, timeout: timeout);
  Future<List<Page>> pages() async => (await this).pages();
}

/// Future mirrors for [Page].
extension PageFuture on Future<Page> {
  Future<Page> go(String url, {Duration? timeout}) async => (await this).go(url, timeout: timeout);
  Future<Page> back({Duration? timeout}) async => (await this).back(timeout: timeout);
  Future<Page> reload({Duration? timeout}) async => (await this).reload(timeout: timeout);
  Future<String> url() async => (await this).url();
  Future<Elements> html() async => (await this).html();
  Future<String> text() async => (await this).text();
  Future<T?> run<T>(String js) async => (await this).run<T>(js);
  Future<Cookies> cookies() async => (await this).cookies();
  Future<String> cookie(String name, {Duration? timeout}) async => (await this).cookie(name, timeout: timeout);
  Stream<Capture> responses(String pattern) => Stream.fromFuture(this).asyncExpand((p) => p.responses(pattern));
  Future<Page> click(String selector, {Duration? timeout}) async => (await this).click(selector, timeout: timeout);
  Future<Page> fill(String selector, String value, {Duration? timeout}) async =>
      (await this).fill(selector, value, timeout: timeout);
  Future<Page> press(String key) async => (await this).press(key);
  Future<Page> select(String selector, String value, {Duration? timeout}) async =>
      (await this).select(selector, value, timeout: timeout);
  Future<Page> upload(String selector, Reader file, {Duration? timeout}) async =>
      (await this).upload(selector, file, timeout: timeout);
  Future<Page> scroll([String? selector, Duration? timeout]) async => (await this).scroll(selector, timeout);
  Future<Page> wait(String selector, {Duration? timeout}) async => (await this).wait(selector, timeout: timeout);
  Future<Page> idle({Duration? timeout}) async => (await this).idle(timeout: timeout);
  Reader screenshot({bool fullPage = false}) => _FutureShot(this, fullPage: fullPage);
  Reader pdf() => _FutureShot(this, pdf: true);
  Future<Download> download(String selector, {Duration? timeout}) async =>
      (await this).download(selector, timeout: timeout);
}

/// Future mirrors for [Download].
extension DownloadFuture on Future<Download> {
  Future<String> name() async => (await this).name();
}

final class _Staged {
  _Staged(this.file, {required this.tmpDir});

  final io.File file;
  final io.Directory? tmpDir;
}

final class _ShotReader with Reader {
  _ShotReader(this._capture);

  final Future<List<int>> Function() _capture;

  @override
  Stream<List<int>> stream() async* {
    yield await _capture();
  }
}

final class _FutureShot with Reader {
  _FutureShot(this._future, {this.fullPage = false, this.pdf = false}) {
    // A failed open with no reader yet must not surface as an unhandled
    // error; reading still gets it.
    unawaited(_future.then((_) {}, onError: (_) {}));
  }

  final Future<Page> _future;
  final bool fullPage;
  final bool pdf;

  @override
  Stream<List<int>> stream() async* {
    final page = await _future;
    if (pdf) {
      yield* page.pdf().stream();
    } else {
      yield* page.screenshot(fullPage: fullPage).stream();
    }
  }
}

final class _FileWriter with Writer {
  _FileWriter(this._file);

  final io.File _file;

  @override
  Future<void> consume(Stream<List<int>> input) async {
    final sink = _file.openWrite();
    try {
      await sink.addStream(input);
      await sink.close();
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      rethrow;
    }
  }
}
