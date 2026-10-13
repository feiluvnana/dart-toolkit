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
/// Public surface is exactly: [Chrome], [Browser], [Page], [Download].
/// - `Chrome.launch/connect()` open a browser.
/// - [Browser] supports `open` `pages`.
/// - [Page] supports `goto` `back` `reload` `url` `html` `text` `eval`
///   `cookies` `click` `fill` `press` `select` `upload` `scroll` `wait`
///   `waitIdle` `screenshot` `pdf` `download`.
/// - [Download] supports `name` (plus [Reader]).
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/json.dart';
import 'package:path/path.dart' as p;
import 'package:puppeteer/protocol/browser.dart' as proto;
import 'package:puppeteer/puppeteer.dart' as pp;

export 'core.dart';
export 'html.dart';

/// Default bound on browser waits and actions.
const Duration _defaultTimeout = Duration(seconds: 30);

/// Entry point: launch or attach a browser.
abstract final class Chrome {
  /// Launch Chromium. Downloads it into the user cache on first use, unless
  /// [executable] names a Chrome or Chromium binary. [profile] keeps cookies
  /// and logins between runs; without it, every launch starts fresh in a
  /// temp profile deleted on [close]. [proxy] routes every request
  /// (`http://host:port`, `socks5://host:port`). Throws when the browser
  /// can't start.
  static Future<Browser> launch({bool headless = true, String? executable, String? profile, String? proxy}) async {
    var exe = executable;
    exe ??= await _cachedExecutable();
    final args = <String>[if (proxy != null) '--proxy-server=$proxy'];
    final browser = await pp.puppeteer.launch(
      headless: headless,
      executablePath: exe,
      userDataDir: profile,
      args: args.isEmpty ? null : args,
    );
    return Browser._(browser, owned: true);
  }

  /// The machine-wide Chromium under `<user cache>/dart_toolkit/chrome`
  /// (one download per machine, not one per project). Downloads it on first
  /// use.
  static Future<String> _cachedExecutable() async {
    final cache = p.join(_userCache(), 'dart_toolkit', 'chrome');
    final info = await pp.downloadChrome(cachePath: cache);
    return info.executablePath;
  }

  /// The OS user cache directory.
  static String _userCache() {
    final env = io.Platform.environment;
    if (io.Platform.isMacOS) {
      final home = env['HOME'];
      if (home != null && home.isNotEmpty) {
        return p.join(home, 'Library', 'Caches');
      }
    } else if (io.Platform.isWindows) {
      final local = env['LOCALAPPDATA'];
      if (local != null && local.isNotEmpty) return local;
    } else {
      final xdg = env['XDG_CACHE_HOME'];
      if (xdg != null && xdg.isNotEmpty) return xdg;
      final home = env['HOME'];
      if (home != null && home.isNotEmpty) {
        return p.join(home, '.cache');
      }
    }
    return io.Directory.systemTemp.path;
  }

  /// Attach to a running browser (`http://localhost:9222` or a `ws://` URL).
  /// Its [close] disconnects and leaves that browser running.
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
final class Browser implements Closeable {
  // ignore: prefer_initializing_formals – the public argument stays `owned`.
  Browser._(this._browser, {required bool owned}) : _owned = owned {
    if (owned) {
      _live.add(this);
      _watchSignals();
    }
  }

  final pp.Browser _browser;

  /// Whether [close] stops the process (launched) or disconnects (connected).
  final bool _owned;

  /// One cached [Page] wrapper per engine target: every `pages()` call for
  /// the same tab returns the same wrapper, so its dialog/traffic
  /// subscriptions are installed once, never leaked per call.
  final _wrappers = Expando<Page>();
  final _known = <Page>[];

  /// One shared download folder per browser; concurrent downloads are told
  /// apart by their DevTools `guid`, so they never clash.
  String? _downloadDir;
  var _closed = false;

  /// Serializes download begins so concurrent `download()` calls don't share
  /// one `onDownloadWillBegin.first`.
  Future<void> _dlPrev = Future.value();

  static final _live = <Browser>{};
  static bool _watching = false;

  static void _watchSignals() {
    if (_watching) return;
    _watching = true;
    void watch(io.ProcessSignal signal, int code, {required bool sigint}) {
      try {
        signal.watch().listen((_) async {
          if (sigint) {
            // Raw terminal (TUI active): SIGINT is a key, not termination.
            try {
              if (!io.stdin.echoMode) return;
            } catch (_) {}
          }
          for (final b in List<Browser>.of(_live)) {
            try {
              await b.close();
            } catch (_) {}
          }
          if (sigint) {
            // Cooked Ctrl-C once behaved as termination; keep that.
            io.exit(130);
          } else {
            io.exit(code);
          }
        });
      } catch (_) {}
    }

    watch(io.ProcessSignal.sigint, 130, sigint: true);
    if (!io.Platform.isWindows) {
      try {
        watch(io.ProcessSignal.sigterm, 143, sigint: false);
      } catch (_) {}
      try {
        watch(io.ProcessSignal.sighup, 129, sigint: false);
      } catch (_) {}
    }
  }

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
  /// the tab loads (`user-agent` also sets the UA string), [block] aborts
  /// requests by resource type (`'image'`, `'font'`, `'media'`,
  /// `'stylesheet'`), [width]/[height] set the viewport.
  /// [timeout] bounds the navigation. Dialogs are always dismissed.
  Future<Page> open(String url, {Map<String, String>? headers, List<String>? block, int? width, int? height, Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    final page = await _browser.newPage();
    final wrap = _wrap(page);
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
        throw TimeoutException('tab never loaded for $limit: $url', limit);
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

  /// Close every tab and the process it launched (or disconnect a connected
  /// browser, leaving it running). Removes downloaded copies. Idempotent.
  @override
  Future<void> close() async {
    if (_closed) return;
    try {
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
      } else {
        _browser.disconnect();
      }
    } catch (_) {
      // Throw allows a retry: don't mark closed until it succeeded.
      rethrow;
    }
    _closed = true;
    _known.clear();
    _live.remove(this);
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
        throw ArgumentError.value(
          block,
          'block',
          'unknown resource type "$b" (image, font, media, stylesheet)',
        );
      }
      blocked.add(lower);
    }
    await page.setRequestInterception(true);
    wrap._blockSub = page.onRequest.listen((req) async {
      try {
        final type = req.resourceType?.toJson().toLowerCase();
        if (type != null && blocked.contains(type)) {
          await req.abort();
          // Aborted requests may never emit finished/failed: balance the
          // waitIdle count here (guarded, so a later event is a no-op).
          if (wrap._inflight > 0) wrap._inflight--;
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
final class Page implements Closeable {
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

  /// Requests in flight (for [waitIdle]): +1 on request, −1 on
  /// finished/failed.
  var _inflight = 0;
  var _closed = false;

  void _dismiss() {
    _dialogSub = _page.onDialog.listen((dialog) async {
      try {
        await dialog.dismiss();
      } catch (_) {}
    }, onError: (_) {});
  }

  void _trackTraffic() {
    bool countable(String? url) {
      if (url == null) return true;
      final lower = url.toLowerCase();
      // No network to go idle: data URLs, websockets, SSE streams.
      if (lower.startsWith('data:') ||
          lower.startsWith('ws:') ||
          lower.startsWith('wss:')) {
        return false;
      }
      return true;
    }

    _trafficSubs.addAll([
      _page.onRequest.listen((req) {
        try {
          // ignore: avoid_dynamic_calls
          final url = (req as dynamic).url as String?;
          if (!countable(url)) return;
        } catch (_) {}
        _inflight++;
      }, onError: (_) {}),
      _page.onResponse.listen((_) {}, onError: (_) {}),
      _page.onRequestFinished.listen((_) {
        if (_inflight > 0) _inflight--;
      }, onError: (_) {}),
      _page.onRequestFailed.listen((_) {
        if (_inflight > 0) _inflight--;
      }, onError: (_) {}),
    ]);
  }

  /// Re-navigate this tab; waits for the load event. Returns this page.
  Future<Page> goto(String url, {Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    try {
      await _page.goto(url, wait: pp.Until.load, timeout: limit).timeout(limit);
    } on TimeoutException {
      throw TimeoutException('navigation timed out for $limit: $url', limit);
    }
    return this;
  }

  /// Go back; waits for the load event. Returns this page.
  Future<Page> back({Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    try {
      await _page.goBack(wait: pp.Until.load, timeout: limit).timeout(limit);
    } on TimeoutException {
      throw TimeoutException('navigation timed out for $limit: ${await url()}', limit);
    }
    return this;
  }

  /// Reload; waits for the load event. Returns this page.
  Future<Page> reload({Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    try {
      await _page.reload(wait: pp.Until.load, timeout: limit).timeout(limit);
    } on TimeoutException {
      throw TimeoutException('navigation timed out for $limit: ${await url()}', limit);
    }
    return this;
  }

  /// The current URL.
  Future<String> url() async => _page.url ?? '';

  /// The rendered DOM as [Elements], with the page's URL as the base.
  /// Chain into it: `page.html().$('a')`.
  Future<Elements> html() async => Html.parse(await _page.content ?? '', baseUrl: await url());

  /// The page's `innerText`.
  Future<String> text() async => (await _page.evaluate<String?>('document.documentElement.innerText')) ?? '';

  /// Evaluate [js], awaiting it if it is a promise, reading the result
  /// with the `Json.value<T>()` rules (`null` for `null`, `undefined`, or
  /// a result that is not a `T`, so `??` gives the default; collections
  /// read as `List<Object?>`/`Map<String, Object?>`).
  Future<T?> eval<T>(String js) async {
    final v = await _page.evaluate<dynamic>(js);
    if (v == null) return null;
    // Route through Json so numbers, lists and maps read with the same
    // coercions as everywhere else (integral doubles as int and double,
    // per-element collection checks).
    try {
      return Json.parse(jsonEncode(v)).value<T>();
    } catch (_) {
      return null;
    }
  }

  /// The `Cookie` header value for the current URL, ready for [Http],
  /// or `null` when there are no cookies. Names/values with `;`, `=`,
  /// space or `"` are quoted.
  Future<String?> cookies() async {
    String part(String name, String value) {
      if (name.contains(RegExp(r'[;=\s"]')) ||
          value.contains(RegExp(r'[;=\s"]'))) {
        String q(String s) => '"${s.replaceAll('"', '\\"')}"';
        return '${q(name)}=${q(value)}';
      }
      return '$name=$value';
    }

    final cookies = await _page.cookies(urls: [await url()]);
    if (cookies.isEmpty) return null;
    return cookies.map((c) => part(c.name, c.value)).join('; ');
  }

  /// Click the first match of [selector], waiting until it is actionable
  /// (up to [timeout]). Returns this page.
  Future<Page> click(String selector, {Duration? timeout}) async {
    await _actionable(selector, timeout: timeout);
    await _page.click(selector);
    return this;
  }

  /// Replace the field's value keystroke by keystroke (firing `input` and
  /// `change`), waiting until it is actionable. Always clears first, so an
  /// empty [value] empties the field. Returns this page.
  Future<Page> fill(String selector, String value, {Duration? timeout}) async {
    await _actionable(selector, timeout: timeout);
    await _page.focus(selector);
    await _page.evaluate<void>(
      '(s) => { const el = document.querySelector(s);'
      ' if (el) { el.focus(); el.value = "";'
      ' el.dispatchEvent(new Event("input", {bubbles: true})); } }',
      args: [selector],
    );
    if (value.isNotEmpty) {
      await _page.type(selector, value);
    }
    await _page.evaluate<void>(
      '(s) => { const el = document.querySelector(s);'
      ' if (el) el.dispatchEvent(new Event("change", {bubbles: true})); }',
      args: [selector],
    );
    return this;
  }

  /// Send a key or a chord, with the key names shared with `Screen.pressed`
  /// (`'enter'`, `'tab'`, `'down'`, `'ctrl+a'`; a single printable
  /// character is typed; `'wheelup'`/`'wheeldown'` scroll). An unknown name
  /// is an [ArgumentError].
  /// Returns this page.
  Future<Page> press(String key) async {
    final lower = key.toLowerCase();
    if (lower == 'wheelup' || lower == 'wheeldown') {
      final dy = lower == 'wheelup' ? -400 : 400;
      try {
        await _page.evaluate<void>(
          '(dy) => window.scrollBy(0, dy)',
          args: [dy],
        );
      } catch (_) {}
      return this;
    }
    if (key == '+') {
      await _page.keyboard.type('+');
      return this;
    }
    final parts = key.split('+');
    if (parts.length == 1) {
      final single = _resolveKey(parts[0], key);
      if (single != null) {
        await _page.keyboard.press(single);
      } else if (parts[0].length == 1) {
        await _page.keyboard.type(parts[0]);
      } else {
        throw ArgumentError.value(key, 'key', 'unknown key: $key');
      }
      return this;
    }
    final mods = <pp.Key>[];
    for (var i = 0; i < parts.length - 1; i++) {
      mods.add(_modifier(parts[i], key));
    }
    for (final m in mods) {
      await _page.keyboard.down(m);
    }
    try {
      final main = parts.last;
      final named = _resolveKey(main, key);
      if (named != null) {
        await _page.keyboard.press(named);
      } else if (main.length == 1) {
        await _page.keyboard.type(main);
      } else {
        throw ArgumentError.value(key, 'key', 'unknown key: $key');
      }
    } finally {
      for (final m in mods.reversed) {
        await _page.keyboard.up(m);
      }
    }
    return this;
  }

  /// A key name to the engine key, or null when it is not a named key.
  /// Case-insensitive (`'Enter'`, `'esc'` work). Single characters are
  /// never named: the caller types them.
  static pp.Key? _resolveKey(String name, String key) {
    if (name.length == 1) return null;
    final lower = name.toLowerCase();
    if (lower == 'esc') return pp.Key.escape;
    if (lower == 'space') return pp.Key.space;
    return _key(lower);
  }

  /// Pick the `<option>` by its value, waiting until actionable.
  /// Throws [TimeoutException] when the option is missing. Returns this page.
  Future<Page> select(String selector, String value, {Duration? timeout}) async {
    await _actionable(selector, timeout: timeout);
    final picked = await _page.select(selector, [value]);
    if (!picked.contains(value)) {
      throw TimeoutException(
        'no option "$value" in $selector',
        timeout ?? _defaultTimeout,
      );
    }
    return this;
  }

  /// Set a file input from a [Reader]. A `File` keeps its name; any other
  /// reader is staged under the name `upload`. File inputs are usually
  /// hidden, so this waits for *attached*, not visible. Staged copies are
  /// retained until this tab closes (the browser reads them at submit).
  /// Fires `input`/`change` so frameworks see the files. Returns this page.
  Future<Page> upload(String selector, Reader file, {Duration? timeout}) async {
    final staged = await _stage(file);
    final tmp = staged.tmpDir;
    if (tmp != null) _stagedDirs.add(tmp);
    try {
      final handle = await _attached(selector, timeout: timeout);
      await handle.uploadFile([staged.file]);
      // Like fill: frameworks listen for input/change, not just the file list.
      try {
        await _page.evaluate<void>(
          '(s) => { const el = document.querySelector(s);'
          ' if (el) { el.dispatchEvent(new Event("input", {bubbles: true}));'
          ' el.dispatchEvent(new Event("change", {bubbles: true})); } }',
          args: [selector],
        );
      } catch (_) {}
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

  /// Without a selector, go to the bottom of the page (what infinite lists
  /// need); with one, bring that element into view, waiting until it is
  /// attached first. Returns this page.
  Future<Page> scroll([String? selector, Duration? timeout]) async {
    if (selector == null) {
      await _page.evaluate<void>('window.scrollTo(0, document.body.scrollHeight)');
      return this;
    }
    await _actionable(selector, timeout: timeout);
    try {
      await (await _page.$(selector)).scrollIntoViewIfNeeded();
    } catch (e) {
      throw StateError('no element to scroll: $selector ($e)');
    }
    return this;
  }

  /// Wait until [selector] is visible. Returns this page.
  Future<Page> wait(String selector, {Duration? timeout}) async {
    await _visible(selector, timeout: timeout);
    return this;
  }

  /// Wait until there has been no request in flight for 500 ms.
  /// Returns this page.
  Future<Page> waitIdle({Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    final deadline = DateTime.now().add(limit);
    var quietSince = DateTime.now();
    for (;;) {
      if (_inflight > 0) {
        quietSince = DateTime.now();
      } else if (DateTime.now().difference(quietSince) >=
          const Duration(milliseconds: 500)) {
        return this;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('network never idle for $limit: ${await url()}', limit);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// A PNG of the viewport (or the whole page with [fullPage]), captured
  /// when read.
  Reader screenshot({bool fullPage = false}) => _ShotReader(() => _page.screenshot(fullPage: fullPage));

  /// The page printed, captured when read.
  Reader pdf() => _ShotReader(() async {
    final bytes = await _page.pdf();
    if (bytes == null) {
      throw StateError('pdf failed: ${await url()}');
    }
    return bytes;
  });

  /// Click [selector] and wait for the download it starts to finish.
  /// Returns a [Download]: a [Reader] of the file plus the name the site
  /// suggested. Downloads share one folder per browser and are told apart
  /// by their DevTools `guid`, so concurrent downloads don't clash. Begins
  /// are serialized; the whole call shares one [timeout] deadline. The
  /// browser's copies are removed when the browser closes.
  Future<Download> download(String selector, {Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    final deadline = DateTime.now().add(limit);
    Duration remaining() => deadline.difference(DateTime.now());
    // Wait for the trigger first: on a missing selector this throws before
    // any download future exists that could fail unhandled later.
    await _actionable(selector, timeout: timeout);
    // Serialize begins: only one willBegin.first at a time.
    final prev = _browser._dlPrev;
    final gate = Completer<void>();
    _browser._dlPrev = gate.future;
    try {
      await prev;
    } catch (_) {}
    final dir = await _browser._downloads();
    await _page.devTools.browser.setDownloadBehavior('allow', downloadPath: dir, eventsEnabled: true);
    final willBegin = _page.devTools.browser.onDownloadWillBegin.first.timeout(
      remaining().isNegative ? Duration.zero : remaining(),
      onTimeout: () => throw TimeoutException('no download from $selector for $limit', limit),
    );
    // Guard the future until it is awaited below: without this, a click
    // that starts no download surfaces an unhandled TimeoutException.
    unawaited(willBegin.then((_) {}, onError: (_) {}));
    await _page.click(selector);
    late final proto.DownloadWillBeginEvent begun;
    try {
      begun = await willBegin;
    } finally {
      gate.complete();
    }
    try {
      final terminal = _page.devTools.browser.onDownloadProgress
          .where((e) => e.guid == begun.guid)
          .firstWhere((e) =>
              e.state == proto.DownloadProgressEventState.completed ||
              e.state == proto.DownloadProgressEventState.canceled)
          .timeout(
            remaining().isNegative ? Duration.zero : remaining(),
            onTimeout: () => throw TimeoutException('download never finished: ${begun.suggestedFilename}', limit),
          );
      // Same guard: a download that never completes must not fail
      // unhandled after this call already threw elsewhere.
      unawaited(terminal.then((_) {}, onError: (_) {}));
      final finished = await terminal;
      if (finished.state != proto.DownloadProgressEventState.completed) {
        throw StateError(
            'download ${finished.state.name}: ${begun.suggestedFilename}');
      }
      final path = finished.filePath ?? '$dir/${begun.suggestedFilename}';
      final left = remaining();
      final file = await _stableFile(
          path, left.isNegative ? Duration.zero : left, begun.suggestedFilename);
      return Download._(file, begun.suggestedFilename);
    } catch (_) {
      rethrow;
    }
  }

  /// Close this tab. Idempotent.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Prune from the browser's known wrappers so they don't retain stale subs.
    try {
      _browser._known.remove(this);
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

  Future<pp.ElementHandle> _attached(String selector, {Duration? timeout}) async {
    await _checkSelector(selector);
    final limit = timeout ?? _defaultTimeout;
    try {
      final handle = await _page.waitForSelector(selector, timeout: limit).timeout(limit);
      if (handle == null) {
        throw TimeoutException('no attached $selector for $limit', limit);
      }
      return handle;
    } on TimeoutException catch (e) {
      throw TimeoutException('no attached $selector for $limit ($e)', limit);
    } catch (e) {
      throw TimeoutException('no attached $selector for $limit ($e)', limit);
    }
  }

  Future<pp.ElementHandle> _visible(String selector, {Duration? timeout}) async {
    await _checkSelector(selector);
    final limit = timeout ?? _defaultTimeout;
    try {
      final handle = await _page.waitForSelector(selector, visible: true, timeout: limit).timeout(limit);
      if (handle == null) {
        throw TimeoutException('no visible $selector for $limit', limit);
      }
      return handle;
    } on TimeoutException catch (e) {
      throw TimeoutException('no visible $selector for $limit ($e)', limit);
    } catch (e) {
      throw TimeoutException('no visible $selector for $limit ($e)', limit);
    }
  }

  /// Throw [FormatException] fast for a selector the engine rejects;
  /// otherwise waiting would burn the full timeout.
  Future<void> _checkSelector(String selector) async {
    bool ok = true;
    try {
      await _page.evaluate<bool>(
        '(s) => { try { document.querySelector(s); return true; }'
        ' catch (_) { return false; } }',
        args: [selector],
      ).then((v) => ok = v);
    } catch (_) {
      ok = true;
    }
    if (!ok) {
      throw FormatException("invalid selector '$selector'");
    }
  }

  Future<void> _actionable(String selector, {Duration? timeout}) async {
    // One deadline for the whole action: visibility plus enabled, so a
    // call never takes up to 2x timeout.
    final limit = timeout ?? _defaultTimeout;
    final deadline = DateTime.now().add(limit);
    Duration remaining() => deadline.difference(DateTime.now());
    var left = remaining();
    if (left <= Duration.zero) {
      throw TimeoutException('no actionable $selector for $limit', limit);
    }
    await _visible(selector, timeout: left);
    for (;;) {
      final enabled = await _page.evaluate<bool>(
        '(s) => { const el = document.querySelector(s);'
        ' return !!el && !el.disabled'
        ' && el.getAttribute("aria-disabled") !== "true"; }',
        args: [selector],
      );
      if (enabled) return;
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('no actionable $selector for $limit', limit);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<_Staged> _stage(Reader file) async {
    String name = 'upload';
    try {
      // ignore: avoid_dynamic_calls
      final n = (file as dynamic).name() as String?;
      if (n != null && n.isNotEmpty) {
        final base = n.split(RegExp(r'[\\/]')).last;
        if (base.isNotEmpty) name = base;
      }
    } catch (_) {}
    String? keep;
    try {
      // ignore: avoid_dynamic_calls
      keep = (file as dynamic).path() as String?;
    } catch (_) {}
    if (keep != null) {
      return _Staged(io.File(keep), keep: true, tmpDir: null);
    }
    final tmp = await io.Directory.systemTemp.createTemp('dart_toolkit_up');
    final staged = io.File('${tmp.path}/$name');
    try {
      await file.to(_FileWriter(staged));
    } catch (_) {
      // Don't leak the staging dir when the reader fails mid-write.
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
    return _Staged(staged, keep: false, tmpDir: tmp);
  }

  static Future<io.File> _stableFile(String path, Duration limit, String name) async {
    final deadline = DateTime.now().add(limit);
    var last = -2;
    while (DateTime.now().isBefore(deadline)) {
      final f = io.File(path);
      if (await f.exists()) {
        final size = await f.length();
        if (size == last && size >= 0) return f;
        last = size;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('download never finished: $name', limit);
  }

  static pp.Key? _key(String name) => switch (name) {
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
    'shift' => pp.Key.shift,
    'control' => pp.Key.control,
    'ctrl' => pp.Key.control,
    'alt' => pp.Key.alt,
    'meta' => pp.Key.meta,
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
    ' ' => pp.Key.space,
    _ => null,
  };

  static pp.Key _modifier(String name, String key) {
    final lower = name.toLowerCase();
    if (lower == 'ctrl' || lower == 'control') return pp.Key.control;
    if (lower == 'alt') return pp.Key.alt;
    if (lower == 'shift') return pp.Key.shift;
    if (lower == 'meta' || lower == 'cmd' || lower == 'command') {
      return pp.Key.meta;
    }
    throw ArgumentError.value(key, 'key', 'unknown modifier: $name');
  }
}

/// A finished browser download: a [Reader] of the file.
final class Download with Reader {
  Download._(this._file, this._name);

  final io.File _file;
  final String _name;

  /// The file name the site suggested.
  String name() => _name;

  @override
  Stream<List<int>> stream() => _file.openRead();
}

/// Future mirrors (rule 6). The extension name is import-only; never reference it.
extension BrowserFuture on Future<Browser> {
  Future<Page> open(String url, {Map<String, String>? headers, List<String>? block, int? width, int? height, Duration? timeout}) async =>
      (await this).open(url, headers: headers, block: block, width: width, height: height, timeout: timeout);
  Future<List<Page>> pages() async => (await this).pages();
}

/// Future mirrors for [Page].
extension PageFuture on Future<Page> {
  Future<Page> goto(String url, {Duration? timeout}) async => (await this).goto(url, timeout: timeout);
  Future<Page> back({Duration? timeout}) async => (await this).back(timeout: timeout);
  Future<Page> reload({Duration? timeout}) async => (await this).reload(timeout: timeout);
  Future<String> url() async => (await this).url();
  Future<Elements> html() async => (await this).html();
  Future<String> text() async => (await this).text();
  Future<T?> eval<T>(String js) async => (await this).eval<T>(js);
  Future<String?> cookies() async => (await this).cookies();
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
  Future<Page> waitIdle({Duration? timeout}) async => (await this).waitIdle(timeout: timeout);
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
  _Staged(this.file, {required this.keep, required this.tmpDir});

  final io.File file;
  final bool keep;
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
  _FutureShot(this._future, {this.fullPage = false, this.pdf = false});

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

final class _FileWriter implements Writer {
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
