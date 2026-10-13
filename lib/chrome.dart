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
///   `cookieHeader` `click` `fill` `press` `select` `upload` `scroll` `wait`
///   `waitIdle` `screenshot` `pdf` `download`.
/// - [Download] supports `name` (plus [Reader]).
/// Everything else is private.
library;

import 'dart:async';
import 'dart:io' as io;

import 'package:dart_toolkit/html.dart';
import 'package:puppeteer/protocol/browser.dart' as proto;
import 'package:puppeteer/puppeteer.dart' as pp;

export 'core.dart';

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
    final args = <String>[if (proxy != null) '--proxy-server=$proxy'];
    final browser = await pp.puppeteer.launch(
      headless: headless,
      executablePath: executable,
      userDataDir: profile,
      args: args.isEmpty ? null : args,
    );
    return Browser._(browser, owned: true);
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
final class Browser implements Closeable {
  // ignore: prefer_initializing_formals – the public argument stays `owned`.
  Browser._(this._browser, {required bool owned}) : _owned = owned;

  final pp.Browser _browser;

  /// Whether [close] stops the process (launched) or disconnects (connected).
  final bool _owned;

  final _downloads = <String>[];
  var _closed = false;

  /// Open a new tab and wait for the load event. Tab setup goes here, before
  /// the first request: [headers] are extra request headers for everything
  /// the tab loads, [block] aborts requests by resource type (`'image'`,
  /// `'font'`, `'media'`, `'stylesheet'`), [width]/[height] set the viewport.
  /// Dialogs are always dismissed.
  Future<Page> open(String url, {Map<String, String>? headers, List<String>? block, int? width, int? height}) async {
    final page = await _browser.newPage();
    final wrap = Page._(page, this);
    try {
      if (width != null || height != null) {
        await page.setViewport(pp.DeviceViewport(width: width ?? 1280, height: height ?? 1024));
      }
      if (headers != null) {
        await page.setExtraHTTPHeaders(headers);
      }
      if (block != null) {
        await _block(page, wrap, block);
      }
      await page.goto(url, wait: pp.Until.load);
    } catch (_) {
      // Don't leak the tab when setup or navigation fails.
      try {
        await wrap.close();
      } catch (_) {}
      rethrow;
    }
    return wrap;
  }

  /// Every open tab, popups included.
  Future<List<Page>> pages() async => [for (final p in await _browser.pages) Page._(p, this)];

  /// Close every tab and the process it launched (or disconnect a connected
  /// browser, leaving it running). Removes downloaded copies. Idempotent.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final dir in _downloads) {
      try {
        await io.Directory(dir).delete(recursive: true);
      } catch (_) {}
    }
    if (_owned) {
      await _browser.close();
    } else {
      _browser.disconnect();
    }
  }

  static Future<void> _block(pp.Page page, Page wrap, List<String> block) async {
    final blocked = {for (final b in block) b.toLowerCase()};
    await page.setRequestInterception(true);
    wrap._blockSub = page.onRequest.listen((req) {
      final type = req.resourceType?.toJson().toLowerCase();
      if (type != null && blocked.contains(type)) {
        req.abort();
      } else {
        req.continueRequest();
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
  final _trafficSubs = <StreamSubscription<dynamic>>[];
  DateTime _lastTraffic = DateTime.now();
  var _closed = false;

  void _dismiss() {
    _page.onDialog.listen((dialog) async {
      try {
        await dialog.dismiss();
      } catch (_) {}
    }, onError: (_) {});
  }

  void _trackTraffic() {
    void mark(_) => _lastTraffic = DateTime.now();
    _trafficSubs.addAll([
      _page.onRequest.listen(mark, onError: (_) {}),
      _page.onResponse.listen(mark, onError: (_) {}),
      _page.onRequestFinished.listen(mark, onError: (_) {}),
      _page.onRequestFailed.listen(mark, onError: (_) {}),
    ]);
  }

  /// Re-navigate this tab; waits for the load event. Returns this page.
  Future<Page> goto(String url) async {
    await _page.goto(url, wait: pp.Until.load);
    return this;
  }

  /// Go back; waits for the load event. Returns this page.
  Future<Page> back() async {
    await _page.goBack(wait: pp.Until.load);
    return this;
  }

  /// Reload; waits for the load event. Returns this page.
  Future<Page> reload() async {
    await _page.reload(wait: pp.Until.load);
    return this;
  }

  /// The current URL.
  Future<String> url() async => _page.url ?? '';

  /// The rendered DOM as [Elements], with the page's URL as the base.
  /// Chain into it: `page.html().$('a')`.
  Future<Elements> html() async => Html.parse(await _page.content ?? '', baseUrl: await url());

  /// The page's `innerText`.
  Future<String> text() async => (await _page.evaluate<String?>('document.documentElement.innerText')) ?? '';

  /// Evaluate [js], awaiting it if it is a promise, JSON-decoding the result.
  /// Returns `null` for `null`, `undefined`, or a result that is not a `T`,
  /// so `??` gives the default.
  Future<T?> eval<T>(String js) async {
    final v = await _page.evaluate<dynamic>(js);
    if (v is T) return v;
    return null;
  }

  /// The `Cookie` header value for the current URL, ready for [Http],
  /// or `null` when there are no cookies.
  Future<String?> cookies() async {
    final cookies = await _page.cookies(urls: [await url()]);
    if (cookies.isEmpty) return null;
    return cookies.map((c) => '${c.name}=${c.value}').join('; ');
  }

  /// Click the first match of [selector], waiting until it is actionable
  /// (up to [timeout]). Returns this page.
  Future<Page> click(String selector, {Duration? timeout}) async {
    await _actionable(selector, timeout: timeout);
    await _page.click(selector);
    return this;
  }

  /// Replace the field's value keystroke by keystroke (firing `input` and
  /// `change`), waiting until it is actionable. Returns this page.
  Future<Page> fill(String selector, String value, {Duration? timeout}) async {
    await _actionable(selector, timeout: timeout);
    await _page.focus(selector);
    await _page.evaluate<void>(
      '(s) => { const el = document.querySelector(s);'
      ' if (el) { el.focus();'
      ' try { el.select(); } catch (_) {}'
      ' document.execCommand("selectAll"); } }',
      args: [selector],
    );
    await _page.type(selector, value);
    await _page.evaluate<void>(
      '(s) => { const el = document.querySelector(s);'
      ' if (el) el.dispatchEvent(new Event("change", {bubbles: true})); }',
      args: [selector],
    );
    return this;
  }

  /// Send a key or a chord (`'enter'`, `'tab'`, `'down'`, `'ctrl+a'`).
  /// Returns this page.
  Future<Page> press(String key) async {
    final parts = key.split('+');
    if (parts.length == 1) {
      final single = _key(parts[0]);
      if (single != null) {
        await _page.keyboard.press(single);
      } else {
        await _page.keyboard.type(parts[0]);
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
      final named = _key(main) ?? _charKey(main);
      if (named != null) {
        await _page.keyboard.press(named);
      } else {
        await _page.keyboard.type(main);
      }
    } finally {
      for (final m in mods.reversed) {
        await _page.keyboard.up(m);
      }
    }
    return this;
  }

  /// Pick the `<option>` by its value, waiting until actionable.
  /// Returns this page.
  Future<Page> select(String selector, String value, {Duration? timeout}) async {
    await _actionable(selector, timeout: timeout);
    await _page.select(selector, [value]);
    return this;
  }

  /// Set a file input from a [Reader]. A `File` keeps its name; any other
  /// reader is staged under the name `upload`. Returns this page.
  Future<Page> upload(String selector, Reader file, {Duration? timeout}) async {
    final staged = await _stage(file);
    try {
      final handle = await _visible(selector, timeout: timeout);
      await handle.uploadFile([staged.file]);
    } finally {
      // Staged copies live in a temp dir; remove the dir, not just the file.
      final tmp = staged.tmpDir;
      if (tmp != null) {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    }
    return this;
  }

  /// Without a selector, go to the bottom of the page (what infinite lists
  /// need); with one, bring that element into view. Returns this page.
  Future<Page> scroll([String? selector]) async {
    if (selector == null) {
      await _page.evaluate<void>('window.scrollTo(0, document.body.scrollHeight)');
      return this;
    }
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

  /// Wait until there has been no network traffic for 500 ms.
  /// Returns this page.
  Future<Page> waitIdle({Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    final deadline = DateTime.now().add(limit);
    for (;;) {
      final quiet = DateTime.now().difference(_lastTraffic);
      if (quiet >= const Duration(milliseconds: 500)) return this;
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('network never idle for ${limit.inSeconds}s: ${await url()}', limit);
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
  /// suggested. The browser's copy is removed when the browser closes.
  Future<Download> download(String selector, {Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    final dir = await io.Directory.systemTemp.createTemp('dart_toolkit_download');
    _browser._downloads.add(dir.path);
    await _page.devTools.browser.setDownloadBehavior('allow', downloadPath: dir.path, eventsEnabled: true);
    final willBegin = _page.devTools.browser.onDownloadWillBegin.first.timeout(
      limit,
      onTimeout: () => throw TimeoutException('no download from $selector for ${limit.inSeconds}s', limit),
    );
    await _actionable(selector, timeout: timeout);
    await _page.click(selector);
    final begun = await willBegin;
    final done = _page.devTools.browser.onDownloadProgress
        .where((e) => e.guid == begun.guid && e.state == proto.DownloadProgressEventState.completed)
        .first
        .timeout(
          limit,
          onTimeout: () => throw TimeoutException('download never finished: ${begun.suggestedFilename}', limit),
        );
    final finished = await done;
    final path = finished.filePath ?? '${dir.path}/${begun.suggestedFilename}';
    final file = await _stableFile(path, limit, begun.suggestedFilename);
    return Download._(file, begun.suggestedFilename);
  }

  /// Close this tab. Idempotent.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _blockSub?.cancel();
    for (final sub in _trafficSubs) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    _trafficSubs.clear();
    try {
      await _page.close();
    } catch (_) {
      // Already closed with the browser; dropping must not throw.
    }
  }

  Future<pp.ElementHandle> _visible(String selector, {Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    try {
      final handle = await _page.waitForSelector(selector, visible: true, timeout: limit).timeout(limit);
      if (handle == null) {
        throw TimeoutException('no visible $selector for ${limit.inSeconds}s', limit);
      }
      return handle;
    } on TimeoutException catch (e) {
      throw TimeoutException('no visible $selector for ${limit.inSeconds}s ($e)', limit);
    } catch (e) {
      throw TimeoutException('no visible $selector for ${limit.inSeconds}s ($e)', limit);
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
      throw TimeoutException('no actionable $selector for ${limit.inSeconds}s', limit);
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
        throw TimeoutException('no actionable $selector for ${limit.inSeconds}s', limit);
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

  static pp.Key? _charKey(String name) => _chars[name.toLowerCase()];

  static final _chars = <String, pp.Key>{
    'a': pp.Key.keyA,
    'b': pp.Key.keyB,
    'c': pp.Key.keyC,
    'd': pp.Key.keyD,
    'e': pp.Key.keyE,
    'f': pp.Key.keyF,
    'g': pp.Key.keyG,
    'h': pp.Key.keyH,
    'i': pp.Key.keyI,
    'j': pp.Key.keyJ,
    'k': pp.Key.keyK,
    'l': pp.Key.keyL,
    'm': pp.Key.keyM,
    'n': pp.Key.keyN,
    'o': pp.Key.keyO,
    'p': pp.Key.keyP,
    'q': pp.Key.keyQ,
    'r': pp.Key.keyR,
    's': pp.Key.keyS,
    't': pp.Key.keyT,
    'u': pp.Key.keyU,
    'v': pp.Key.keyV,
    'w': pp.Key.keyW,
    'x': pp.Key.keyX,
    'y': pp.Key.keyY,
    'z': pp.Key.keyZ,
    '0': pp.Key.digit0,
    '1': pp.Key.digit1,
    '2': pp.Key.digit2,
    '3': pp.Key.digit3,
    '4': pp.Key.digit4,
    '5': pp.Key.digit5,
    '6': pp.Key.digit6,
    '7': pp.Key.digit7,
    '8': pp.Key.digit8,
    '9': pp.Key.digit9,
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
  Future<Page> open(String url, {Map<String, String>? headers, List<String>? block, int? width, int? height}) async =>
      (await this).open(url, headers: headers, block: block, width: width, height: height);
  Future<List<Page>> pages() async => (await this).pages();
}

/// Future mirrors for [Page].
extension PageFuture on Future<Page> {
  Future<Page> goto(String url) async => (await this).goto(url);
  Future<Page> back() async => (await this).back();
  Future<Page> reload() async => (await this).reload();
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
  Future<Page> scroll([String? selector]) async => (await this).scroll(selector);
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
