import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/traits.dart';
import 'native.dart';

export '../core/errors.dart';
export '../core/pipe.dart';
export '../core/traits.dart';

/// A browser, launched on the first [open].
///
/// ```dart
/// final chrome = Chrome();
/// final page = await chrome.open('https://example.com');
/// Cli.print(await page.title());
/// final doc = await page.html();
/// await page.screenshot().pipe(File('shot.png'));
/// await chrome.close();
/// ```
///
/// `Chrome()` launches on the first [open]; `Chrome(port: 9222)` attaches to
/// a running one. [close] kills the whole tree and drops the temp profile.
/// `page.pdf()` prints to PDF.
///
/// Every call below runs through `dart_toolkit_chrome` (ABI 1); without the
/// library it is an [UnsupportedError] (rule 42: no Dart fallback). The blocking
/// CDP calls run synchronously on the calling isolate; a hung render is
/// bounded by its timeout, and [close] always reaps the tree.
final class Chrome implements ffi.Finalizable {
  /// Attaches to a running Chrome at 127.0.0.1:[port] instead of launching.
  final int? port;

  /// The browser executable (found when null).
  final String? executable;

  /// Whether to show the browser window.
  final bool visible;

  /// Reuses a profile directory (a temp one is made and dropped otherwise).
  final String? profile;

  /// Extra browser arguments.
  final List<String> args;

  Future<_Launched>? _started;

  static final _finalizer = ffi.NativeFinalizer(
    require().lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>('tk_cdp_release').cast(),
  );

  Chrome({this.port, this.executable, this.visible = false, this.profile, this.args = const []});

  Future<_Launched> get _handle => _started ??= _start();

  /// Launches (or attaches, for [port]) on first use.
  Future<_Launched> _start() async {
    if (port != null) {
      final handle = withText('127.0.0.1', (hp, hl) => _ChromeNative.attach(hp, hl, port!));
      if (handle == ffi.nullptr) {
        throw NativeException('attach to Chrome at 127.0.0.1:$port', lastError());
      }
      final launched = _Launched(handle, 'http://127.0.0.1:$port', null);
      _finalizer.attach(this, handle, detach: this);
      return launched;
    }
    final exe = executable ?? _findChrome();
    if (exe == null) throw const MissingException('Chrome or Edge executable');
    final dir = profile ?? (await io.Directory.systemTemp.createTemp('tk_chrome_profile_')).path;
    final owned = profile == null;
    final portOut = alloc(2).cast<ffi.Uint16>();
    try {
      final handle = withText(exe, (ep, el) {
        return withText(dir, (dp, dl) {
          return withBytes(utf8.encode(args.join('\x00')), (ap, al) {
            return _ChromeNative.launch(ep, el, visible ? 0 : 1, dp, dl, owned ? 1 : 0, ap, al, portOut);
          });
        });
      });
      if (handle == ffi.nullptr) throw NativeException('launch Chrome', lastError());
      final launched = _Launched(handle, 'http://127.0.0.1:${portOut.value}', owned ? dir : null);
      _finalizer.attach(this, handle, detach: this);
      return launched;
    } finally {
      free(portOut.cast(), 2);
    }
  }

  /// Opens [url] in a new tab and answers the connected [Page].
  /// Launches/attaches on first call.
  Future<Page> open(String url, {Duration timeout = const Duration(seconds: 30)}) async {
    final l = await _handle;
    final out = alloc(8).cast<ffi.Pointer<ffi.Void>>();
    try {
      final rc = withText(url, (p, n) => _ChromeNative.open(l.handle, p, n, timeout.inMilliseconds, ffi.nullptr, out));
      if (rc < 0) throw NativeException('open $url', lastError());
      return Page._(out.value, l.endpoint);
    } finally {
      free(out.cast(), 8);
    }
  }

  /// The open pages.
  Future<List<Page>> pages() async {
    final l = await _handle;
    final res = await _httpGet('${l.endpoint}/json/list');
    final list = jsonDecode(res) as List<dynamic>;
    final pages = <Page>[];
    for (final item in list.cast<Map<String, dynamic>>()) {
      final ws = item['webSocketDebuggerUrl'] as String?;
      final id = item['id'] as String?;
      if (item['type'] == 'page' && ws != null && id != null) {
        final handle = withText(ws, (wp, wl) {
          return withText(id, (ip, il) {
            return withText(l.endpoint, (ep, el) => _ChromeNative.attachPage(wp, wl, ip, il, ep, el));
          });
        });
        if (handle != ffi.nullptr) pages.add(Page._(handle, l.endpoint));
      }
    }
    return pages;
  }

  /// Whether the browser process still lives (never true before the first
  /// [open], nor after [close]).
  Future<bool> alive() async {
    final started = _started;
    if (started == null) return false;
    _Launched? l;
    try {
      l = await started;
    } catch (_) {
      return false;
    }
    return l.handle != ffi.nullptr && _ChromeNative.alive(l.handle) == 1;
  }

  /// Closes the browser: the whole tree dies (never an orphan), the temp
  /// profile is deleted. Idempotent; a relaunch happens on the next [open].
  Future<void> close() async {
    final started = _started;
    _started = null;
    if (started == null) return;
    _Launched? l;
    try {
      l = await started;
    } catch (_) {
      // Never started: there is nothing to free.
      return;
    }
    final h = l.handle;
    if (h == ffi.nullptr) return;
    l.handle = ffi.nullptr;
    _finalizer.detach(this);
    _ChromeNative.free(h);
  }

  /// The browser executable: `DART_TOOLKIT_CHROME` first, then the
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

/// A launched or attached browser: its native handle, DevTools endpoint, and
/// the temp profile it owns (null when reused or attached).
final class _Launched {
  ffi.Pointer<ffi.Void> handle;
  final String endpoint;
  final String? ownedProfile;

  _Launched(this.handle, this.endpoint, this.ownedProfile);
}

/// A single tab, driven through the native CDP engine. A [Source] over its
/// HTML, so `page.html()` gives a `Doc` and `page.text()` the markup.
final class Page implements ffi.Finalizable, Source {
  ffi.Pointer<ffi.Void> _handle;

  /// The browser endpoint this tab belongs to.
  final String endpoint;

  static final _finalizer = ffi.NativeFinalizer(
    require().lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>('tk_cdp_release_page').cast(),
  );

  Page._(this._handle, this.endpoint) {
    _finalizer.attach(this, _handle, detach: this);
  }

  /// This page's HTML as a [Reader]; [from] must be 0.
  @override
  Future<Reader> reader({int from = 0}) async {
    if (from != 0) throw ArgumentError.value(from, 'from', 'Only 0: a page cannot seek');
    final markup = (await eval('document.documentElement.outerHTML')).toString();
    return _PageReader(utf8.encode(markup));
  }

  /// The page markup length is not known up front.
  @override
  int? get lengthHint => null;

  /// Navigates to [url] and waits for the load event.
  Future<void> navigate(String url, {Duration timeout = const Duration(seconds: 30)}) async {
    final rc = withText(url, (p, n) => _ChromeNative.navigate(_handle, p, n, timeout.inMilliseconds, ffi.nullptr));
    if (rc < 0) throw NativeException('navigate to $url', lastError());
  }

  /// The page title.
  Future<String> title() async => (await eval('document.title')).toString();

  /// Evaluates [expression] and answers its value.
  Future<dynamic> eval(String expression) async {
    final raw = withText(
      expression,
      (p, n) => take('evaluate JavaScript', (o, l) => _ChromeNative.eval(_handle, p, n, o, l)),
    );
    return jsonDecode(utf8.decode(raw));
  }

  /// Clicks the first element matching [selector] with real mouse events at
  /// its center (scrolled into view first).
  Future<void> click(String selector) async {
    final rc = withText(selector, (p, n) => _ChromeNative.click(_handle, p, n));
    if (rc < 0) throw NativeException('click $selector', lastError());
  }

  /// Types [text] into the first element matching [selector] (focused first,
  /// so framework hooks fire).
  Future<void> type(String selector, String text) async {
    final rc = withText(selector, (sp, sn) {
      return withText(text, (tp, tn) => _ChromeNative.type(_handle, sp, sn, tp, tn));
    });
    if (rc < 0) throw NativeException('type into $selector', lastError());
  }

  /// Waits until [selector] matches or [timeout] elapses.
  Future<void> wait(String selector, {Duration timeout = const Duration(seconds: 30)}) async {
    final rc = withText(selector, (p, n) => _ChromeNative.wait(_handle, p, n, timeout.inMilliseconds, ffi.nullptr));
    if (rc < 0) throw NativeException('wait for $selector', lastError());
  }

  /// Captures a PNG screenshot (`full` captures past the viewport). Pipe it:
  /// `await page.screenshot().pipe(File('shot.png'))`.
  Future<Uint8List> screenshot({bool full = false}) {
    return Future.value(
      take('capture screenshot', (o, l) => _ChromeNative.shot(_handle, full ? 1 : 0, ffi.nullptr, o, l)),
    );
  }

  /// Prints the page to PDF (`landscape` when set). Pipe it:
  /// `await page.pdf().pipe(File('page.pdf'))`.
  Future<Uint8List> pdf({bool landscape = false}) {
    return Future.value(take('print to PDF', (o, l) => _ChromeNative.pdf(_handle, landscape ? 1 : 0, o, l)));
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

/// A [Reader] over bytes in hand (a page's markup).
final class _PageReader implements Reader {
  final Uint8List _bytes;
  int _pos = 0;

  _PageReader(this._bytes);

  @override
  Future<int> read(Uint8List buf) async {
    if (_pos >= _bytes.length) return 0;
    final n = buf.length < _bytes.length - _pos ? buf.length : _bytes.length - _pos;
    buf.setRange(0, n, _bytes, _pos);
    _pos += n;
    return n;
  }

  @override
  Future<void> close() async {}
}

/// The native `tk_cdp_*` calls behind [Chrome] and [Page].
abstract final class _ChromeNative {
  static ffi.DynamicLibrary get _lib => require();

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
    if (_free(handle) < 0) throw NativeException('close Chrome', lastError());
  }

  static final _free = _lib
      .lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>), int Function(ffi.Pointer<ffi.Void>)>('tk_cdp_free');

  static void closePage(ffi.Pointer<ffi.Void> handle) {
    if (_closePage(handle) < 0) throw NativeException('close page', lastError());
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
    if (response.statusCode != 200) throw NativeException('read Chrome $url', 'answered ${response.statusCode}');
    return body;
  } finally {
    client.close(force: true);
  }
}
