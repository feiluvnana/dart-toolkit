import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import 'native.dart';

/// Launches or attaches to Chrome over the native DevTools engine.
///
/// ```dart
/// final chrome = await Chrome.launch();
/// final page = await chrome.open('https://example.com');
/// print(await page.html());
/// await page.shot().pipe(File('shot.png'));
/// await chrome.close();
/// ```
///
/// Every call below runs through `dart_toolkit_chrome` (ABI 1); without the
/// library it is an [UnsupportedError] (r50: no Dart fallback). The blocking
/// CDP calls run synchronously on the calling isolate; the stop byte the ABI
/// carries is reserved for a worker-isolate cancel recipe (a hung render is
/// bounded by its timeout, and `close()` always reaps the tree).
abstract final class Chrome {
  /// Launches a fresh Chrome and connects to it. A temp `--user-data-dir` is
  /// made (deleted by [Browser.close]); pass [profile] to reuse one (kept).
  static Future<Browser> launch({
    String? executable,
    bool headless = true,
    List<String> args = const [],
    bool visible = false,
    String? profile,
  }) async {
    final exe = executable ?? _findChrome();
    if (exe == null) throw const ChromeException('No Chrome or Edge executable found');
    final dir = profile ?? (await io.Directory.systemTemp.createTemp('tk_chrome_profile_')).path;
    final owned = profile == null;
    final portOut = Lib2Chrome.alloc(2).cast<ffi.Uint16>();
    try {
      final handle = Lib2Chrome.withText(exe, (ep, el) {
        return Lib2Chrome.withText(dir, (dp, dl) {
          return Lib2Chrome.withBytes(utf8.encode(args.join('\x00')), (ap, al) {
            return _ChromeNative.launch(ep, el, (headless && !visible) ? 1 : 0, dp, dl, owned ? 1 : 0, ap, al, portOut);
          });
        });
      });
      if (handle == ffi.nullptr) throw ChromeException('Cannot launch Chrome: ${Lib2Chrome.lastError()}');
      return Browser._(handle, 'http://127.0.0.1:${portOut.value}');
    } finally {
      Lib2Chrome.free(portOut.cast(), 2);
    }
  }

  /// Attaches to an already-running Chrome with a debugging [port].
  static Future<Browser> connect({String port = '9222', String host = '127.0.0.1'}) async {
    final handle = Lib2Chrome.withText(host, (hp, hl) => _ChromeNative.attach(hp, hl, int.parse(port)));
    if (handle == ffi.nullptr) throw ChromeException('Cannot attach to Chrome: ${Lib2Chrome.lastError()}');
    return Browser._(handle, 'http://$host:$port');
  }

  /// The browser executable: `DART_TOOLKIT_CHROME` first (PLAN.md §9), then the
  /// usual installs (Chrome, then Edge).
  static String? _findChrome() {
    final env = io.Platform.environment;
    final candidates = <String>[
      if (env['DART_TOOLKIT_CHROME'] != null) env['DART_TOOLKIT_CHROME']!,
      if (env['CHROME_PATH'] != null) env['CHROME_PATH']!,
      if (io.Platform.isWindows) ...[
        '${env['ProgramFiles']}\\Google\\Chrome\\Application\\chrome.exe',
        '${env['ProgramFiles(x86)']}\\Google\\Chrome\\Application\\chrome.exe',
        '${env['LOCALAPPDATA']}\\Google\\Chrome\\Application\\chrome.exe',
        '${env['ProgramFiles']}\\Microsoft\\Edge\\Application\\msedge.exe',
        '${env['ProgramFiles(x86)']}\\Microsoft\\Edge\\Application\\msedge.exe',
        if (env['LOCALAPPDATA'] != null) '${env['LOCALAPPDATA']}\\Microsoft\\Edge\\Application\\msedge.exe',
      ],
      if (io.Platform.isMacOS) ...[
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
      ],
      if (io.Platform.isLinux) ...['/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser'],
    ];
    for (final c in candidates) {
      if (io.File(c).existsSync()) return c;
    }
    return null;
  }
}

/// A connected browser instance: a resource — [close] it.
final class Browser implements ffi.Finalizable {
  ffi.Pointer<ffi.Void> _handle;

  /// The DevTools HTTP endpoint, e.g. `http://127.0.0.1:9222`.
  final String endpoint;

  static final _finalizer = ffi.NativeFinalizer(
    Lib2Chrome.require().lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>('tk_cdp_release').cast(),
  );

  Browser._(this._handle, this.endpoint) {
    _finalizer.attach(this, _handle, detach: this);
  }

  /// Metadata about the browser.
  Future<Map<String, dynamic>> version() async {
    final res = await _httpGet('$endpoint/json/version');
    return jsonDecode(res) as Map<String, dynamic>;
  }

  /// Opens [url] in a new tab and answers the connected [Page].
  Future<Page> open(String url, {Duration timeout = const Duration(seconds: 30)}) async {
    final out = Lib2Chrome.alloc(8).cast<ffi.Pointer<ffi.Void>>();
    try {
      final rc = Lib2Chrome.withText(
        url,
        (p, n) => _ChromeNative.open(_handle, p, n, timeout.inMilliseconds, ffi.nullptr, out),
      );
      if (rc < 0) throw ChromeException('Cannot open $url: ${Lib2Chrome.lastError()}');
      return Page._(out.value, endpoint);
    } finally {
      Lib2Chrome.free(out.cast(), 8);
    }
  }

  /// Opens a blank tab.
  Future<Page> newTab({String about = 'about:blank'}) => open(about);

  /// Opens a blank tab.
  @Deprecated('use newTab instead')
  Future<Page> newPage() => newTab();

  /// The open pages.
  Future<List<Page>> pages() async {
    final res = await _httpGet('$endpoint/json/list');
    final list = jsonDecode(res) as List<dynamic>;
    final pages = <Page>[];
    for (final item in list.cast<Map<String, dynamic>>()) {
      final ws = item['webSocketDebuggerUrl'] as String?;
      final id = item['id'] as String?;
      if (item['type'] == 'page' && ws != null && id != null) {
        final handle = Lib2Chrome.withText(ws, (wp, wl) {
          return Lib2Chrome.withText(id, (ip, il) {
            return Lib2Chrome.withText(endpoint, (ep, el) => _ChromeNative.attachPage(wp, wl, ip, il, ep, el));
          });
        });
        if (handle != ffi.nullptr) pages.add(Page._(handle, endpoint));
      }
    }
    return pages;
  }

  /// Whether the browser process still lives (never true after [close]).
  Future<bool> get alive async => _handle != ffi.nullptr && _ChromeNative.alive(_handle) == 1;

  /// Closes the browser: the whole tree dies (never an orphan), the temp
  /// profile is deleted. Idempotent.
  Future<void> close() async {
    final h = _handle;
    if (h == ffi.nullptr) return;
    _handle = ffi.nullptr;
    _finalizer.detach(this);
    _ChromeNative.free(h);
  }
}

/// A single tab, driven through the native CDP engine.
final class Page implements ffi.Finalizable {
  ffi.Pointer<ffi.Void> _handle;

  /// The browser endpoint this tab belongs to.
  final String endpoint;

  static final _finalizer = ffi.NativeFinalizer(
    Lib2Chrome.require()
        .lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>('tk_cdp_release_page')
        .cast(),
  );

  Page._(this._handle, this.endpoint) {
    _finalizer.attach(this, _handle, detach: this);
  }

  /// Navigates to [url] and waits for the load event.
  Future<void> goto(String url, {Duration timeout = const Duration(seconds: 30)}) async {
    final rc = Lib2Chrome.withText(
      url,
      (p, n) => _ChromeNative.navigate(_handle, p, n, timeout.inMilliseconds, ffi.nullptr),
    );
    if (rc < 0) throw ChromeException('Cannot go to $url: ${Lib2Chrome.lastError()}');
  }

  /// The page title.
  Future<String> title() async => (await eval('document.title')).toString();

  /// The full HTML of the document: `Html.parse(await page.html())`.
  Future<String> html() async => (await eval('document.documentElement.outerHTML')).toString();

  /// The full HTML of the document.
  @Deprecated('use html instead')
  Future<String> content() => html();

  /// Evaluates [expression] and answers its value.
  Future<dynamic> eval(String expression) async {
    final raw = Lib2Chrome.withText(
      expression,
      (p, n) => Lib2Chrome.take('evaluate JavaScript', (o, l) => _ChromeNative.eval(_handle, p, n, o, l)),
    );
    return jsonDecode(utf8.decode(raw));
  }

  /// Clicks the first element matching [selector] with real mouse events at
  /// its center (scrolled into view first).
  Future<void> click(String selector) async {
    final rc = Lib2Chrome.withText(selector, (p, n) => _ChromeNative.click(_handle, p, n));
    if (rc < 0) throw ChromeException('Cannot click $selector: ${Lib2Chrome.lastError()}');
  }

  /// Types [text] into the first element matching [selector] (focused first,
  /// so framework hooks fire).
  Future<void> type(String selector, String text) async {
    final rc = Lib2Chrome.withText(selector, (sp, sn) {
      return Lib2Chrome.withText(text, (tp, tn) => _ChromeNative.type(_handle, sp, sn, tp, tn));
    });
    if (rc < 0) throw ChromeException('Cannot type into $selector: ${Lib2Chrome.lastError()}');
  }

  /// Sets the value of the first input matching [selector] and fires `input`.
  Future<void> fill(String selector, String value) => eval(
    '(() => { const el = document.querySelector(${jsonEncode(selector)});'
    ' el.value = ${jsonEncode(value)};'
    " el.dispatchEvent(new Event('input', { bubbles: true })); })()",
  );

  /// Waits until [selector] matches or [timeout] elapses.
  Future<void> wait(String selector, {Duration timeout = const Duration(seconds: 10)}) async {
    final rc = Lib2Chrome.withText(
      selector,
      (p, n) => _ChromeNative.wait(_handle, p, n, timeout.inMilliseconds, ffi.nullptr),
    );
    if (rc < 0) throw ChromeException('Timed out waiting for $selector: ${Lib2Chrome.lastError()}');
  }

  /// Waits until [selector] matches or [timeout] elapses.
  @Deprecated('use wait instead')
  Future<void> waitFor(String selector, {Duration timeout = const Duration(seconds: 10)}) =>
      wait(selector, timeout: timeout);

  /// Captures a PNG screenshot (`full` captures past the viewport). Pipe it:
  /// `await page.shot().pipe(File('shot.png'))`.
  Future<Uint8List> shot({bool full = false}) {
    return Future.value(
      Lib2Chrome.take('capture screenshot', (o, l) => _ChromeNative.shot(_handle, full ? 1 : 0, ffi.nullptr, o, l)),
    );
  }

  /// Captures a PNG screenshot.
  @Deprecated('use shot instead')
  Future<Uint8List> screenshot({bool fullPage = false}) => shot(full: fullPage);

  /// Prints the page to PDF (`landscape` when set). Pipe it:
  /// `await page.pdf().pipe(File('page.pdf'))`.
  Future<Uint8List> pdf({bool landscape = false}) {
    return Future.value(Lib2Chrome.take('print to PDF', (o, l) => _ChromeNative.pdf(_handle, landscape ? 1 : 0, o, l)));
  }

  /// Sends a raw DevTools command ([params] is a JSON object, empty for none)
  /// and answers the result object: the escape hatch under the verbs above.
  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) async {
    final raw = Lib2Chrome.withText(method, (mp, ml) {
      return Lib2Chrome.withText(jsonEncode(params ?? {}), (pp, pl) {
        return Lib2Chrome.take('send $method', (o, l) => _ChromeNative.send(_handle, mp, ml, pp, pl, o, l));
      });
    });
    return (jsonDecode(utf8.decode(raw)) as Map).cast<String, dynamic>();
  }

  /// Closes the tab. Idempotent.
  Future<void> close() async {
    final h = _handle;
    if (h == ffi.nullptr) return;
    _handle = ffi.nullptr;
    _finalizer.detach(this);
    _ChromeNative.closePage(h);
  }
}

/// The native `tk_cdp_*` calls behind [Browser] and [Page].
abstract final class _ChromeNative {
  static ffi.DynamicLibrary get _lib => Lib2Chrome.require();

  static final launch = _lib
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint8,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint8,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint16>,
        ),
        ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint16>,
        )
      >('tk_cdp_launch');

  static final attach = _lib
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr, ffi.Uint16),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>, int, int)
      >('tk_cdp_attach');

  static final open = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint64,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Pointer<ffi.Void>>,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Pointer<ffi.Void>>,
        )
      >('tk_cdp_open');

  static final navigate = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint64,
          ffi.Pointer<ffi.Void>,
        ),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int, int, ffi.Pointer<ffi.Void>)
      >('tk_cdp_navigate');

  static final eval = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
          ffi.Pointer<ffi.IntPtr>,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
          ffi.Pointer<ffi.IntPtr>,
        )
      >('tk_cdp_eval');

  static final wait = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint64,
          ffi.Pointer<ffi.Void>,
        ),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int, int, ffi.Pointer<ffi.Void>)
      >('tk_cdp_wait');

  static final click = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int)
      >('tk_cdp_click');

  static final type = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
        ),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int)
      >('tk_cdp_type');

  static final shot = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Uint8,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
          ffi.Pointer<ffi.IntPtr>,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          int,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
          ffi.Pointer<ffi.IntPtr>,
        )
      >('tk_cdp_shot');

  static final pdf = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Uint8,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
          ffi.Pointer<ffi.IntPtr>,
        ),
        int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.IntPtr>)
      >('tk_cdp_pdf');

  static final send = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
          ffi.Pointer<ffi.IntPtr>,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
          ffi.Pointer<ffi.IntPtr>,
        )
      >('tk_cdp_send');

  static final attachPage = _lib
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
        ),
        ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
        )
      >('tk_cdp_attach_page');

  static final alive = _lib
      .lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>), int Function(ffi.Pointer<ffi.Void>)>('tk_cdp_alive');

  static void free(ffi.Pointer<ffi.Void> handle) {
    if (_free(handle) < 0) throw ChromeException('Cannot close Chrome: ${Lib2Chrome.lastError()}');
  }

  static final _free = _lib
      .lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>), int Function(ffi.Pointer<ffi.Void>)>('tk_cdp_free');

  static void closePage(ffi.Pointer<ffi.Void> handle) {
    if (_closePage(handle) < 0) throw ChromeException('Cannot close page: ${Lib2Chrome.lastError()}');
  }

  static final _closePage = _lib
      .lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>), int Function(ffi.Pointer<ffi.Void>)>(
        'tk_cdp_close_page',
      );
}

Future<String> _httpGet(String url) async {
  final client = io.HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await utf8.decodeStream(response).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) throw ChromeException('Chrome answered ${response.statusCode} for $url');
    return body;
  } finally {
    client.close(force: true);
  }
}
