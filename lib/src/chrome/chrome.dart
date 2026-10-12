import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import '../core/decoding.dart';
import '../core/errors.dart';
import '../core/jobs.dart';
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
/// `page.pdf()` prints to PDF. `page.html()` gives a `Doc`: import `html.dart`
/// for it.
///
/// Every call below runs through `dart_toolkit_chrome` (ABI 2); without the
/// library it is an [UnsupportedError] (rule 42: no Dart fallback). The CDP
/// calls run as jobs on native threads, so the event loop stays free while a
/// render hangs; each is bounded by its timeout, and [close] always reaps the
/// tree. Closing a [Page] fails its in-flight calls with `StateError('closed')`.
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

  /// The launch or attach job in flight, if any: [close] stops it.
  NativeJob? _starting;

  static final _finalizer = ffi.NativeFinalizer(
    require().lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>('tk_cdp_release').cast(),
  );

  Chrome({this.port, this.executable, this.visible = false, this.profile, this.args = const []});

  Future<_Launched> get _handle => _started ??= _start();

  /// Launches (or attaches, for [port]) on first use.
  Future<_Launched> _start() async {
    if (port != null) {
      final slot = alloc(8).cast<ffi.Pointer<ffi.Void>>();
      final NativeJob job;
      try {
        job = startJob(
          'attach to Chrome at 127.0.0.1:$port',
          chromeJobs,
          (done, stop, progress, id) =>
              withText('127.0.0.1', (hp, hl) => _ChromeNative.attach(hp, hl, port!, slot, done, stop, progress, id)),
        );
      } catch (_) {
        free(slot.cast(), 8);
        rethrow;
      }
      _starting = job;
      _finalizer.attach(this, slot.value, detach: this);
      try {
        final endpoint = utf8.decode(await job.future);
        return _Launched(slot.value, endpoint, null);
      } catch (_) {
        _finalizer.detach(this);
        _ChromeNative.releaseBrowser(slot.value);
        rethrow;
      } finally {
        free(slot.cast(), 8);
        _starting = null;
      }
    }
    final exe = executable ?? _findChrome();
    if (exe == null) throw const MissingException('Chrome or Edge executable');
    // Headless hides behind the real user agent: `exe --version` names the
    // version, and the launch carries `--user-agent=` with `HeadlessChrome`
    // replaced by `Chrome`. Visible mode keeps the real UA (no flag). A probe
    // that fails in any way launches without the flag.
    final extra = List<String>.of(args);
    if (!visible) {
      final agent = await _stealthUserAgent(exe);
      if (agent != null) extra.add('--user-agent=$agent');
    }
    final dir = profile ?? (await io.Directory.systemTemp.createTemp('tk_chrome_profile_')).path;
    final owned = profile == null;
    final slot = alloc(8).cast<ffi.Pointer<ffi.Void>>();
    final NativeJob job;
    try {
      job = startJob(
        'launch Chrome',
        chromeJobs,
        (done, stop, progress, id) => withText(exe, (ep, el) {
          return withText(dir, (dp, dl) {
            return withBytes(utf8.encode(extra.join('\x00')), (ap, al) {
              return _ChromeNative.launch(
                ep,
                el,
                visible ? 0 : 1,
                dp,
                dl,
                owned ? 1 : 0,
                ap,
                al,
                slot,
                done,
                stop,
                progress,
                id,
              );
            });
          });
        }),
      );
    } catch (_) {
      free(slot.cast(), 8);
      // A refused queue owns nothing: drop the temp profile it just made, so
      // one bogus executable does not leave profiles behind.
      if (owned) await _dropDir(dir);
      rethrow;
    }
    _starting = job;
    _finalizer.attach(this, slot.value, detach: this);
    try {
      final endpoint = utf8.decode(await job.future);
      return _Launched(slot.value, endpoint, owned ? dir : null);
    } catch (_) {
      _finalizer.detach(this);
      _ChromeNative.releaseBrowser(slot.value);
      // A failed launch owns nothing: the native side already reaped what it
      // spawned and dropped an owned profile; this only covers the leftovers.
      if (owned) await _dropDir(dir);
      rethrow;
    } finally {
      free(slot.cast(), 8);
      _starting = null;
    }
  }

  /// Opens [url] in a new tab and answers the connected [Page].
  /// Launches/attaches on first call.
  Future<Page> open(String url, {Duration timeout = const Duration(seconds: 30)}) async {
    final l = await _handle;
    final slot = alloc(8).cast<ffi.Pointer<ffi.Void>>();
    final NativeJob job;
    try {
      job = startJob(
        'open $url',
        chromeJobs,
        (done, stop, progress, id) => withText(
          url,
          (p, n) => _ChromeNative.open(l.handle, p, n, timeout.inMilliseconds, slot, done, stop, progress, id),
        ),
      );
    } catch (_) {
      free(slot.cast(), 8);
      rethrow;
    }
    final page = Page._(slot.value, l.endpoint);
    free(slot.cast(), 8);
    try {
      await job.future;
      return page;
    } catch (_) {
      // Never connected: free the handle (closing the tab if one appeared).
      page._abandon();
      rethrow;
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
          return withText(id, (ip, il) => _ChromeNative.attachPage(l.handle, wp, wl, ip, il));
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
  /// A launch still in flight is stopped first.
  Future<void> close() async {
    final starting = _starting;
    _starting = null;
    starting?.cancel(StateError('closed'));
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
/// HTML, so `page.html()` gives a `Doc` (import `html.dart` for it) and
/// `page.text()` the markup.
///
/// Every drive call below is a job on a native thread; [close] fails the ones
/// still in flight with `StateError('closed')`, and a call on a closed page
/// throws it at once.
final class Page implements ffi.Finalizable, Source {
  ffi.Pointer<ffi.Void> _handle;

  /// The browser endpoint this tab belongs to.
  final String endpoint;

  /// The CDP jobs in flight: [close] stops them all.
  final _jobs = <NativeJob>{};

  static final _finalizer = ffi.NativeFinalizer(
    require().lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>('tk_cdp_release_page').cast(),
  );

  Page._(this._handle, this.endpoint) {
    _finalizer.attach(this, _handle, detach: this);
    sourceUrls[this] = () => _readUrl;
  }

  /// The page's URL when [reader] last read it: `page.html()` resolves links against it.
  String? _readUrl;

  /// Throws `StateError('closed')` once the tab is gone.
  void _checkOpen() {
    if (_handle == ffi.nullptr) throw StateError('closed');
  }

  /// Runs a native count call ([start] queues it); tracked so [close] stops it.
  Future<int> _count(String op, StartJob start) async {
    _checkOpen();
    final job = startJob(op, chromeJobs, start);
    _jobs.add(job);
    try {
      await job.future;
      return job.rc;
    } finally {
      _jobs.remove(job);
    }
  }

  /// Runs a native byte call ([start] queues it); tracked so [close] stops it.
  Future<Uint8List> _bytes(String op, StartJob start) async {
    _checkOpen();
    final job = startJob(op, chromeJobs, start);
    _jobs.add(job);
    try {
      return await job.future;
    } finally {
      _jobs.remove(job);
    }
  }

  /// Gives up the handle without a server round-trip: detaches the finalizer
  /// and releases the native side (closing the tab if one appeared). For a
  /// failed [Chrome.open] only; [close] goes through the server instead.
  void _abandon() {
    final h = _handle;
    _handle = ffi.nullptr;
    _finalizer.detach(this);
    _jobs.clear();
    if (h != ffi.nullptr) _ChromeNative.releasePage(h);
  }

  /// This page's HTML as a [Reader]; [from] must be 0.
  @override
  Future<Reader> reader({int from = 0}) async {
    if (from != 0) throw ArgumentError.value(from, 'from', 'Only 0: a page cannot seek');
    final read = (await eval('location.href + "\\n" + document.documentElement.outerHTML')).toString();
    final cut = read.indexOf('\n');
    _readUrl = read.substring(0, cut);
    return _PageReader(utf8.encode(read.substring(cut + 1)));
  }

  /// The page markup length is not known up front.
  @override
  int? get lengthHint => null;

  /// Navigates to [url] and waits for the load event.
  Future<void> navigate(String url, {Duration timeout = const Duration(seconds: 30)}) async {
    await _count(
      'navigate to $url',
      (done, stop, progress, id) => withText(
        url,
        (p, n) => _ChromeNative.navigate(_handle, p, n, timeout.inMilliseconds, done, stop, progress, id),
      ),
    );
  }

  /// The page title.
  Future<String> title() async => (await eval('document.title')).toString();

  /// Evaluates [expression] and answers its value.
  Future<dynamic> eval(String expression) async {
    final raw = await _bytes(
      'evaluate JavaScript',
      (done, stop, progress, id) =>
          withText(expression, (p, n) => _ChromeNative.eval(_handle, p, n, done, stop, progress, id)),
    );
    return jsonDecode(utf8.decode(raw));
  }

  /// Clicks the first element matching [selector] with real mouse events at
  /// its center (scrolled into view first).
  Future<void> click(String selector) async {
    await _count(
      'click $selector',
      (done, stop, progress, id) =>
          withText(selector, (p, n) => _ChromeNative.click(_handle, p, n, done, stop, progress, id)),
    );
  }

  /// Types [text] into the first element matching [selector] (focused first,
  /// so framework hooks fire).
  Future<void> type(String selector, String text) async {
    await _count(
      'type into $selector',
      (done, stop, progress, id) => withText(selector, (sp, sn) {
        return withText(text, (tp, tn) => _ChromeNative.type(_handle, sp, sn, tp, tn, done, stop, progress, id));
      }),
    );
  }

  /// Waits until [selector] matches or [timeout] elapses.
  Future<void> wait(String selector, {Duration timeout = const Duration(seconds: 30)}) async {
    await _count(
      'wait for $selector',
      (done, stop, progress, id) => withText(
        selector,
        (p, n) => _ChromeNative.wait(_handle, p, n, timeout.inMilliseconds, done, stop, progress, id),
      ),
    );
  }

  /// Captures a PNG screenshot (`full` captures past the viewport). Pipe it:
  /// `await page.screenshot().pipe(File('shot.png'))`.
  Future<Uint8List> screenshot({bool full = false}) {
    return _bytes(
      'capture screenshot',
      (done, stop, progress, id) => _ChromeNative.shot(_handle, full ? 1 : 0, done, stop, progress, id),
    );
  }

  /// Prints the page to PDF (`landscape` when set). Pipe it:
  /// `await page.pdf().pipe(File('page.pdf'))`.
  Future<Uint8List> pdf({bool landscape = false}) {
    return _bytes(
      'print to PDF',
      (done, stop, progress, id) => _ChromeNative.pdf(_handle, landscape ? 1 : 0, done, stop, progress, id),
    );
  }

  /// Closes the tab: its in-flight calls fail with `StateError('closed')`,
  /// then the server drops the tab. Idempotent.
  Future<void> close() async {
    final h = _handle;
    if (h == ffi.nullptr) return;
    _handle = ffi.nullptr;
    _finalizer.detach(this);
    for (final job in _jobs.toList()) {
      job.cancel(StateError('closed'));
    }
    _jobs.clear();
    await nativeCount(
      'close page',
      chromeJobs,
      (done, stop, progress, id) => _ChromeNative.closePage(h, done, stop, progress, id),
    );
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

/// The native `tk_cdp_*` calls behind [Chrome] and [Page] (native ABI 2: every
/// call that waits on the browser is a job answering through `done`).
abstract final class _ChromeNative {
  static ffi.DynamicLibrary get _lib => require();

  static final launch = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint8,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint8,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Pointer<ffi.Void>>,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Pointer<ffi.Void>>,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_cdp_launch');

  static final attach = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint16,
          ffi.Pointer<ffi.Pointer<ffi.Void>>,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.Pointer<ffi.Void>>,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_cdp_attach');

  static final open = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint64,
          ffi.Pointer<ffi.Pointer<ffi.Void>>,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.Pointer<ffi.Void>>,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_cdp_open');

  static final navigate = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint64,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_cdp_navigate');

  static final eval = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_cdp_eval');

  static final wait = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint64,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_cdp_wait');

  static final click = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_cdp_click');

  static final type = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_cdp_type');

  static final shot = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Uint8,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          int,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_cdp_shot');

  static final pdf = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Uint8,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          int,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_cdp_pdf');

  static final attachPage = _lib
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
        ),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int)
      >('tk_cdp_attach_page');

  static final alive = _lib
      .lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>), int Function(ffi.Pointer<ffi.Void>)>('tk_cdp_alive');

  static void free(ffi.Pointer<ffi.Void> handle) {
    if (_free(handle) < 0) throw NativeException('close Chrome', lastError());
  }

  static final _free = _lib
      .lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>), int Function(ffi.Pointer<ffi.Void>)>('tk_cdp_free');

  static final closePage = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_cdp_close_page');

  /// Best-effort release of a browser handle that never connected (a failed
  /// launch or attach): frees it without failing.
  static final releaseBrowser = _lib
      .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>), void Function(ffi.Pointer<ffi.Void>)>('tk_cdp_release');

  /// Best-effort release of a page handle that never connected (a failed
  /// open): frees it (closing the tab if one appeared) without failing.
  static final releasePage = _lib
      .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>), void Function(ffi.Pointer<ffi.Void>)>(
        'tk_cdp_release_page',
      );
}

/// Deletes the directory at [dir] when there is one; never throws.
Future<void> _dropDir(String dir) async {
  try {
    await io.Directory(dir).delete(recursive: true);
  } catch (_) {
    // Best effort: a half-made profile must not leak, but a missing one is fine.
  }
}

/// The headless user agent: Chrome's own, with `HeadlessChrome` replaced by
/// `Chrome`, versioned by `exe --version` (10 s; any failure answers null, and
/// the launch goes without the flag).
Future<String?> _stealthUserAgent(String exe) async {
  try {
    final res = await io.Process.run(exe, ['--version']).timeout(const Duration(seconds: 10));
    final version = RegExp(r'\d+\.\d+\.\d+\.\d+').firstMatch('${res.stdout}${res.stderr}')?.group(0);
    if (version == null) return null;
    final platform = io.Platform.isMacOS
        ? '(Macintosh; Intel Mac OS X 10_15_7)'
        : io.Platform.isWindows
        ? '(Windows NT 10.0; Win64; x64)'
        : '(X11; Linux x86_64)';
    return 'Mozilla/5.0 $platform AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$version Safari/537.36';
  } catch (_) {
    // A missing executable, a hang, or unparsable output: launch as before.
    return null;
  }
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
