/// Browser automation over the Chrome DevTools Protocol (in-house client,
/// `dart:io` WebSocket).
///
/// ```dart
/// final browser = await Chrome.launch(profile: '.chrome');
/// final page = await browser.open('https://example.com/login', block: {.image, .font})
///     .fill('#user', name).fill('#pass', password).click('button[type=submit]').wait('.dashboard');
/// await (page.screenshot(fullPage: true) > Fs.file('orders.png'));
/// await browser.close();
/// ```
///
/// Public surface is exactly: [Chrome], [Browser], [Page], [Download], [Capture], [Resource], [BrowserException].
/// - `Chrome.launch/connect()` open a browser.
/// - [Browser] supports `open` `pages` `close`.
/// - [Page] supports `go` `back` `reload` `url` `html` `text` `run`
///   `cookies` `cookie` `responses` `click` `fill` `press` `select` `upload`
///   `scroll` `wait` `idle`
///   `screenshot` `pdf` `download` `close`.
/// - [Download] supports `name` (plus [Reader]; a probe shows the browser's progress).
/// - [Capture] is an XHR/fetch response the page received: `status` `url`
///   `header` `name` (plus [Reader]).
/// - `page.cookies()` is a core [Cookies] jar, ready for `Http.client(cookies:)`.
/// - [BrowserException] is what a tab action throws when the page fails it.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:path/path.dart' as p;

import 'html.dart';
import 'src/cdp.dart';
import 'src/chrome_find.dart';
import 'src/cookies.dart' as jar;
import 'src/exit.dart' as exit;
import 'src/format.dart' show Unit;
import 'src/glob.dart';
import 'src/keys.dart' as keys;
import 'src/names.dart' as names;
import 'src/origin.dart' as origins;
import 'src/posix.dart' as posix;
import 'src/progress.dart' show Run, working;

export 'core.dart';
export 'html.dart';
export 'src/cdp.dart' show BrowserException;

/// What [Browser.open]'s `block:` can stop a tab from loading.
enum Resource {
  image('Image'),
  font('Font'),
  media('Media'),
  stylesheet('Stylesheet');

  const Resource(this._cdp);
  final String _cdp;
}

/// Default bound on browser waits and actions.
const Duration _defaultTimeout = Duration(seconds: 30);

/// Entry point: launch or attach a browser.
abstract final class Chrome {
  /// Launch Chrome: [path], else Chrome for Testing already in the user
  /// cache, else an installed Chrome or Chromium, else Chrome for Testing
  /// downloaded into the user cache once per machine. A headless run without
  /// a profile uses `chrome-headless-shell`, which starts ~4x faster.
  /// [profile] keeps cookies (session cookies too) and logins between runs,
  /// not tabs, so tabs never pile up; without it, every launch starts fresh
  /// in a temp profile deleted on [Browser.close]. [proxy] routes every request
  /// (`http://host:port`, `socks5://host:port`). Throws when the browser
  /// can't start.
  static Future<Browser> launch({bool headless = true, String? path, String? profile, String? proxy}) async {
    if (proxy != null && (Uri.tryParse(proxy)?.userInfo.isNotEmpty ?? false)) {
      // It would sit in the process list, and Chrome ignores it anyway.
      throw ArgumentError.value(names.redact(proxy), 'proxy', 'Chrome takes no proxy password: use an open local proxy');
    }
    final exe = path ?? await chromeExecutable(headless: headless && profile == null);
    final temp = profile == null ? await io.Directory.systemTemp.createTemp('dart_toolkit_chrome-') : null;
    if (profile != null) {
      try {
        await io.Directory(p.join(profile, 'Default', 'Sessions')).delete(recursive: true);
      } on io.PathNotFoundException catch (_) {}
    }
    // POSIX: CDP over fds 3 and 4 (two FIFOs in an owner-only folder), so
    // no TCP port any local process could drive. Windows keeps the port.
    final pipes = io.Platform.isWindows ? null : await io.Directory.systemTemp.createTemp('dart_toolkit_cdp');
    final args = [
      ..._flags,
      if (headless) ...['--headless', '--hide-scrollbars', '--mute-audio'],
      if (proxy != null) '--proxy-server=$proxy',
      // Keeps session cookies (logins); the session's tabs were deleted above.
      if (profile != null) '--restore-last-session',
      if (pipes == null) '--remote-debugging-port=0' else '--remote-debugging-pipe',
      '--user-data-dir=${profile ?? temp!.path}',
      'about:blank',
    ];
    Future<void> dropTemp() async {
      for (final d in [temp, pipes]) {
        try {
          await d?.delete(recursive: true);
        } catch (_) {}
      }
    }

    // POSIX: Chrome runs detached, its stdout dropped and its stderr in a
    // log beside the FIFOs, so no pipe of it holds a finished script open
    // (the watchdog ends it). Windows keeps a child with piped stdio.
    final log = pipes == null ? null : io.File('${pipes.path}/stderr');
    final io.Process proc;
    try {
      if (pipes == null) {
        proc = await io.Process.start(exe, args);
      } else {
        final made = await io.Process.run('mkfifo', ['${pipes.path}/in', '${pipes.path}/out']);
        if (made.exitCode != 0) throw io.ProcessException('mkfifo', [], '${made.stderr}'.trim(), made.exitCode);
        proc = await io.Process.start('/bin/sh', [
          '-c',
          r'i=$1; o=$2; e=$3; shift 3; exec "$@" 3<"$i" 4>"$o" >/dev/null 2>"$e"',
          'sh',
          '${pipes.path}/in',
          '${pipes.path}/out',
          log!.path,
          exe,
          ...args,
        ], mode: io.ProcessStartMode.detached);
      }
    } catch (e) {
      await dropTemp();
      throw BrowserException('Chrome would not start: $exe ($e)', cause: e);
    }
    final endpoint = Completer<String>();
    final tail = <String>[];
    if (pipes == null) {
      proc.stdout.drain<void>().ignore();
      proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (!endpoint.isCompleted) {
                if (_listening.firstMatch(line) case final m?) return endpoint.complete(m[1]!);
              }
              if (tail.length == 8) tail.removeAt(0);
              tail.add(line);
            },
            onDone: () {
              if (!endpoint.isCompleted) endpoint.completeError(BrowserException('Chrome exited: ${tail.join('\n')}'));
            },
            onError: (Object _) {},
          );
    }
    Future<String> why(String what) async {
      try {
        final lines = [...?(await log?.readAsLines())?.where((l) => l.trim().isNotEmpty)];
        tail.addAll(lines.length > 8 ? lines.sublist(lines.length - 8) : lines);
      } catch (_) {}
      return '$what: $exe${tail.isEmpty ? '' : '\n${tail.join('\n')}'}';
    }

    Cdp? cdp;
    try {
      if (pipes == null) {
        final url = await endpoint.future.timeout(
          _defaultTimeout,
          onTimeout: () async => throw BrowserException(await why('Chrome did not start in ${_defaultTimeout.inSeconds} s')),
        );
        cdp = await Cdp.connect(url).timeout(_defaultTimeout);
      } else {
        // sh opens `in` for reading first, then `out` for writing: open
        // both ends at once (each open waits for its other side).
        cdp = await Cdp.pipe('${pipes.path}/out', io.File('${pipes.path}/in').openWrite());
        try {
          await cdp.browser.send('Browser.getVersion').timeout(_defaultTimeout);
        } on TimeoutException {
          throw BrowserException(await why('Chrome did not start in ${_defaultTimeout.inSeconds} s'));
        } on BrowserException {
          // The pipe closed: Chrome exited, and its log says why.
          throw BrowserException(await why('Chrome exited'));
        }
        await pipes.delete(recursive: true).catchError((_) => pipes); // both ends are open
      }
    } catch (_) {
      if (pipes == null) {
        proc.kill(io.ProcessSignal.sigkill);
        await proc.exitCode;
      } else {
        io.Process.killPid(proc.pid, io.ProcessSignal.sigkill);
        await cdp?.close();
      }
      await dropTemp();
      rethrow;
    }
    final dog = proc.pid > 1 && !io.Platform.isWindows ? await _watchdog(proc.pid, temp?.path) : null;
    return Browser._(cdp, pid: proc.pid, dog: dog, temp: temp);
  }

  static final _listening = RegExp(r'^DevTools listening on (ws://\S+)');

  /// Quiet, deterministic automation defaults (no first run, no sync, no
  /// background throttling, no back/forward cache).
  static const _flags = [
    '--disable-background-networking',
    '--disable-background-timer-throttling',
    '--disable-backgrounding-occluded-windows',
    '--disable-breakpad',
    '--disable-client-side-phishing-detection',
    '--disable-component-extensions-with-background-pages',
    '--disable-default-apps',
    '--disable-dev-shm-usage',
    '--disable-extensions',
    '--disable-features=Translate,BackForwardCache,MediaRouter,OptimizationHints',
    '--disable-hang-monitor',
    '--disable-ipc-flooding-protection',
    '--disable-popup-blocking',
    '--disable-prompt-on-repost',
    '--disable-renderer-backgrounding',
    '--disable-sync',
    '--force-color-profile=srgb',
    '--metrics-recording-only',
    '--no-default-browser-check',
    '--no-first-run',
    '--password-store=basic',
    '--use-mock-keychain',
  ];

  /// A child that blocks on its stdin, which hits EOF when this VM dies for
  /// any reason (even an uncaught throw), then kills Chromium and removes the
  /// temp profile. The pid and dir are arguments, never interpolated.
  /// POSIX only; Windows has no watchdog yet.
  /// Detached with its stdin piped, it never holds the script open.
  static Future<io.Process?> _watchdog(int pid, String? dir) async {
    try {
      return await io.Process.start('/bin/sh', [
        '-c',
        'cat >/dev/null; kill -9 "\$1" 2>/dev/null; sleep 1; [ -z "\$2" ] || rm -rf -- "\$2"',
        '_',
        '$pid',
        dir ?? '',
      ], mode: io.ProcessStartMode.detachedWithStdio);
    } catch (_) {
      return null;
    }
  }

  /// Attach to a running browser (`http://localhost:9222` or a `ws://` URL).
  /// Its [Browser.close] closes the tabs it opened, restores the download
  /// behaviour, disconnects, and leaves that browser running.
  /// Fails with a [BrowserException] when nothing answers within 30 s.
  static Future<Browser> connect(String url) async {
    try {
      var ws = url;
      if (!url.startsWith('ws://') && !url.startsWith('wss://')) {
        final client = io.HttpClient();
        try {
          // One bound over connect, request and body: an endpoint that
          // accepts and never answers fails too.
          final body = await () async {
            final res = await (await client.getUrl(Uri.parse(url).resolve('/json/version'))).close();
            return res.transform(utf8.decoder).join();
          }().timeout(_defaultTimeout);
          ws = (jsonDecode(body) as Map<String, Object?>)['webSocketDebuggerUrl']! as String;
        } finally {
          client.close(force: true);
        }
      }
      return Browser._(await Cdp.connect(ws).timeout(_defaultTimeout));
    } on BrowserException {
      rethrow;
    } catch (e) {
      throw BrowserException('no browser to connect to at $url: $e', cause: e);
    }
  }
}

/// An open browser. Owns its pages; one browser serves many pages.
/// A launched browser nobody closes never keeps a finished script alive: a
/// watchdog ends Chromium and its temp profile with the script (POSIX). A
/// SIGTERM/SIGHUP (or a cooked-terminal Ctrl-C) during a call closes it.
final class Browser implements Closeable {
  Browser._(this._cdp, {int? pid, this._dog, this._temp}) : _pid = pid {
    if (pid == null) return;
    // With the watchdog, a signal closes the browser gracefully only while
    // it works: an idle one holds no signal watcher open, and the watchdog
    // ends it with the script. Without one (Windows) the hook stays.
    if (_dog == null) {
      _hook(true);
    } else {
      _cdp.onBusy = _hook;
      // Chromium gone on its own (a crash, a kill): its pid may be reused
      // before the script ends, so the watchdog must not signal it then.
      unawaited(_cdp.done.then((_) => _gone(), onError: (Object _) => _gone()));
    }
  }

  /// The connection ended without [close]: Chromium has exited.
  Future<void> _gone() async {
    if (_closed) return;
    if (_dog case final dog?) dog.kill();
    try {
      await _temp?.delete(recursive: true);
    } catch (_) {}
  }

  void _hook(bool on) {
    if (on && _exitToken == null && !_closed) {
      _exitToken = exit.onExit(() async {
        try {
          await close();
        } catch (_) {}
      });
    } else if (!on && _exitToken != null) {
      exit.offExit(_exitToken!);
      _exitToken = null;
    }
  }

  final Cdp _cdp;

  /// The launched process's pid (`null` when connected: close only
  /// disconnects).
  final int? _pid;

  /// Orphan watchdog (see [Chrome.launch]) and the temp profile it removes.
  final io.Process? _dog;
  final io.Directory? _temp;
  Object? _exitToken;

  /// One wrapper per tab, so `pages()` returns the same [Page] each time.
  final _pages = <String, Future<Page>>{};

  /// Tabs [open] made: a connected browser's [close] closes only these.
  final _opened = <Page>{};

  /// One shared download folder per browser, set up on first download;
  /// downloads are told apart by their DevTools `guid`.
  Future<String>? _downloads;
  String? _downloadDir;
  var _closed = false;

  /// Open a new tab and wait for the load event. Tab setup goes here, before
  /// the first request: [headers] are extra request headers for everything
  /// the tab loads (`user-agent` also sets the UA string), [block]
  /// aborts requests of those [Resource] types, [width]/[height] set the
  /// viewport.
  /// [timeout] bounds the navigation and the page's [Page.run] calls.
  /// Dialogs are always dismissed.
  Future<Page> open(
    String url, {
    Map<String, String>? headers,
    Set<Resource> block = const {},
    int? width,
    int? height,
    Duration? timeout,
  }) async {
    final blocked = {for (final r in block) r._cdp};
    final created = await _cdp.browser.send('Target.createTarget', {'url': 'about:blank'});
    final id = created['targetId']! as String;
    final page = await (_pages[id] = Page._attach(this, id));
    if (timeout != null) page._timeout = timeout;
    _opened.add(page);
    try {
      final s = page._s;
      String? ua;
      final extra = <String, String>{};
      headers?.forEach((k, v) => k.toLowerCase() == 'user-agent' ? ua = v : extra[k] = v);
      await Future.wait([
        if (width != null || height != null)
          s.send('Emulation.setDeviceMetricsOverride', {
            'width': width ?? 1280,
            'height': height ?? 1024,
            'deviceScaleFactor': 1,
            'mobile': false,
          }),
        if (ua != null) s.send('Network.setUserAgentOverride', {'userAgent': ua}),
        if (extra.isNotEmpty) s.send('Network.setExtraHTTPHeaders', {'headers': extra}),
        if (blocked.isNotEmpty) page._block(blocked),
      ]);
      await page.go(url, timeout: timeout);
    } catch (_) {
      // Don't leak the tab when setup or navigation fails.
      await page.close();
      rethrow;
    }
    return page;
  }


  /// Every open tab, popups included (one wrapper per tab).
  Future<List<Page>> pages() async {
    final targets = await _cdp.browser.send('Target.getTargets');
    final ids = [
      for (final t in (targets['targetInfos']! as List).cast<Map<String, Object?>>())
        if (t['type'] == 'page') t['targetId']! as String,
    ];
    _pages.removeWhere((id, _) => !ids.contains(id));
    final out = <Page>[];
    for (final id in ids) {
      try {
        out.add(await (_pages[id] ??= Page._attach(this, id)));
      } catch (_) {
        _pages.remove(id); // closed meanwhile
      }
    }
    return out;
  }

  /// Close every tab and the process it launched (for a connected browser:
  /// close the tabs [open] made, restore its download behaviour, then
  /// disconnect, leaving it running). Removes downloaded copies. Idempotent.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final page in await Future.wait([
      for (final f in _pages.values) f.then<Page?>((p) => p, onError: (_) => null),
    ])) {
      if (page != null) await page._unstage();
    }
    final pid = _pid;
    if (pid != null) {
      try {
        await _cdp.browser.send('Browser.close').timeout(const Duration(seconds: 5));
      } catch (_) {}
      // The connection ends when the process does.
      await _cdp
          .hold(_cdp.done)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              io.Process.killPid(pid, io.ProcessSignal.sigkill);
              return _cdp.done.timeout(const Duration(seconds: 2), onTimeout: () {});
            },
          );
      // Only after the process is gone: a failed close keeps the watchdog.
      if (_dog case final dog?) io.Process.killPid(dog.pid);
    } else {
      if (_downloadDir != null) {
        try {
          await _cdp.browser.send('Browser.setDownloadBehavior', {'behavior': 'default'});
        } catch (_) {}
      }
      for (final page in List.of(_opened)) {
        await page.close();
      }
    }
    await _cdp.close();
    for (final dir in [_downloadDir, _temp?.path]) {
      if (dir == null) continue;
      try {
        await io.Directory(dir).delete(recursive: true);
      } catch (_) {}
    }
    if (_exitToken case final token?) exit.offExit(token);
    _exitToken = null;
  }

  /// The shared download folder; the first call points the browser at it.
  Future<String> _downloadFolder() => _downloads ??= () async {
    final dir = (await io.Directory.systemTemp.createTemp('dart_toolkit_downloads')).path;
    _downloadDir = dir;
    await _cdp.browser.send('Browser.setDownloadBehavior', {
      'behavior': 'allowAndName',
      'downloadPath': dir,
      'eventsEnabled': true,
    });
    return dir;
  }();
}

/// An open tab. Read it, drive it, wait on it, take content out of it.
final class Page implements Closeable {
  Page._(this._s, this._target, this._browser) {
    _s
      ..on('Page.javascriptDialogOpening', (_) => _s.send('Page.handleJavaScriptDialog', {'accept': false}).ignore())
      ..on('Page.frameAttached', (e) => _frames.add(e['frameId']! as String))
      ..on('Page.frameDetached', (e) => _frames.remove(e['frameId']))
      ..on('Page.frameNavigated', (e) => _frame(e['frame']! as Map<String, Object?>))
      ..on('Page.navigatedWithinDocument', (e) {
        if (e['frameId'] == _main) _url = e['url']! as String;
      })
      ..on('Page.lifecycleEvent', (e) {
        if (e['name'] != 'load' || e['frameId'] != _main) return;
        _loads.add(e['loaderId']! as String);
        if (_loads.length > 16) _loads.remove(_loads.first);
      })
      ..on('Network.requestWillBeSent', (e) {
        final url = (e['request']! as Map)['url']! as String;
        if (_countable(url)) _inflight[e['requestId']! as String] = _clock.elapsed;
      })
      ..on('Network.loadingFinished', (e) => _settle(e['requestId']! as String, true))
      ..on('Network.loadingFailed', (e) => _settle(e['requestId']! as String, false));
    _s.gone.then((_) {
      for (final end in _ends.values) {
        end.complete(false);
      }
      _ends.clear();
    });
  }

  /// Attach to tab [target] and turn on the domains every page uses.
  static Future<Page> _attach(Browser browser, String target) async {
    final page = Page._(await browser._cdp.attach(target), target, browser);
    final s = page._s;
    await Future.wait([
      s.send('Page.enable'),
      s.send('Page.setLifecycleEventsEnabled', {'enabled': true}),
      s.send('Network.enable'),
      s.send('Page.getFrameTree').then((r) => page._tree(r['frameTree']! as Map<String, Object?>)),
    ]);
    return page;
  }

  final CdpSession _s;
  final String _target;
  final Browser _browser;

  var _url = '';
  var _main = '';

  /// What bounds [run]: `open(timeout:)`, else 30 s.
  var _timeout = _defaultTimeout;

  /// Every frame of this tab, for crediting downloads started in iframes.
  final _frames = <String>{};

  /// Loaders whose `load` fired lately (a fast page can load before its
  /// navigation's reply is handled).
  final _loads = <String>{};

  /// Requests in flight (for [idle]) and when each started on [_clock].
  /// Both sides see the same ids, so `data:`/`ws:` URLs never enter.
  final _inflight = <String, Duration>{};

  /// Waiters for a request's end (a [Capture] body), true when it finished.
  final _ends = <String, Completer<bool>>{};

  /// Completed whenever a request ends so [idle] wakes without polling.
  Completer<void>? _idleNotified;
  final _clock = Stopwatch()..start();
  var _settledAt = Duration.zero;

  /// Staged upload dirs (non-File readers): kept until this tab closes,
  /// since the browser reads them at submit.
  final _stagedDirs = <io.Directory>[];

  /// Serializes this tab's download begins.
  Future<void> _dlGate = Future.value();
  var _closed = false;

  /// Idle when no request has been in flight for this long.
  static const _quietPeriod = Duration(milliseconds: 500);

  /// A request open this long is a long-poll or a stream: it no longer
  /// holds [idle].
  static const _longLived = Duration(seconds: 5);

  void _tree(Map<String, Object?> node) {
    _frame(node['frame']! as Map<String, Object?>);
    for (final child in (node['childFrames'] as List? ?? const []).cast<Map<String, Object?>>()) {
      _tree(child);
    }
  }

  void _frame(Map<String, Object?> f) {
    final id = f['id']! as String;
    _frames.add(id);
    if (f['parentId'] != null) return;
    _main = id;
    _url = '${f['url']}${f['urlFragment'] ?? ''}';
  }

  static bool _countable(String url) {
    final lower = url.toLowerCase();
    return !(lower.startsWith('data:') || lower.startsWith('ws:') || lower.startsWith('wss:'));
  }

  void _settle(String id, bool ok) {
    _ends.remove(id)?.complete(ok);
    if (_inflight.remove(id) == null) return;
    _settledAt = _clock.elapsed;
    _idleNotified?.complete();
    _idleNotified = null;
  }

  Future<void> _block(Set<String> types) {
    _s.on(
      'Fetch.requestPaused',
      (e) => _s.send('Fetch.failRequest', {'requestId': e['requestId'], 'errorReason': 'BlockedByClient'}).ignore(),
    );
    return _s.send('Fetch.enable', {
      'patterns': [
        for (final t in types) {'resourceType': t, 'requestStage': 'Request'},
      ],
    });
  }

  /// Re-navigate this tab; waits for the load event. Returns this page.
  Future<Page> go(String url, {Duration? timeout}) => _navigate(url, timeout, () async {
    final r = await _s.send('Page.navigate', {'url': url});
    if (r['errorText'] case final String e when e.isNotEmpty) throw BrowserException('go $url: $e');
    return r['loaderId'] as String?;
  }, sameDocument: true);

  /// Go back; waits for the load event. Without history, stays. Returns this page.
  Future<Page> back({Duration? timeout}) async {
    final h = await _s.send('Page.getNavigationHistory');
    final at = h['currentIndex']! as int;
    if (at == 0) return this;
    final entry = ((h['entries']! as List)[at - 1] as Map)['id'];
    return _navigate(_url, timeout, () async {
      await _s.send('Page.navigateToHistoryEntry', {'entryId': entry});
      return null;
    });
  }

  /// Reload; waits for the load event. Returns this page.
  Future<Page> reload({Duration? timeout}) => _navigate(_url, timeout, () async {
    await _s.send('Page.reload');
    return null;
  });

  /// Run [start] and wait for the main frame's load. [start] returns the
  /// new loader id, or null to learn it from the next `frameNavigated`
  /// (with [sameDocument], null means a fragment change: done).
  Future<Page> _navigate(
    String subject,
    Duration? timeout,
    Future<String?> Function() start, {
    bool sameDocument = false,
  }) async {
    final limit = timeout ?? _defaultTimeout;
    final sw = Stopwatch()..start();
    Duration left() => limit - sw.elapsed;
    try {
      final navigated = sameDocument
          ? null
          : _s.once('Page.frameNavigated', where: (e) => (e['frame']! as Map)['parentId'] == null, timeout: limit);
      navigated?.ignore();
      var loader = await start().timeout(limit);
      if (navigated != null) {
        final e = await navigated.timeout(left());
        if (e['type'] == 'BackForwardCacheRestore') return this;
        loader = (e['frame']! as Map)['loaderId'] as String?;
      }
      if (loader == null || _loads.contains(loader)) return this;
      await _s.once(
        'Page.lifecycleEvent',
        where: (e) => e['name'] == 'load' && e['loaderId'] == loader,
        timeout: left(),
      );
    } on TimeoutException {
      throw _Timeout('navigation timed out', limit, subject);
    }
    return this;
  }

  /// The current URL.
  Future<String> url() async => _url;

  /// The rendered DOM as [Elements], with the page's URL as the base.
  /// Chain into it: `page.html().$('a')`.
  Future<Elements> html() async => Html.parse(
    await run(
      '(document.doctype ? new XMLSerializer().serializeToString(document.doctype) : "")'
      ' + (document.documentElement ? document.documentElement.outerHTML : "")',
    ).or(''),
    base: _url,
  );

  /// The page's `innerText`.
  Future<String> text() => run('document.documentElement.innerText').or('');

  /// Evaluate [js] once (an expression or statements; a function source is
  /// then called once), awaiting a promise, and return the result as [Json]
  /// (`null` and `undefined` read as null). A script that throws is a
  /// [BrowserException]; one that has not settled after the page's timeout
  /// (`open(timeout:)`, default 30 s) a [TimeoutException].
  ///
  /// ```dart
  /// final title = await page.run('document.title').or('');
  /// final tags = await page.run('[...document.querySelectorAll("a")].map(a => a.href)').asList<String>();
  /// ```
  Future<Json> run(String js) async {
    final sw = Stopwatch()..start();
    try {
      var v = await _eval(js, byValue: false);
      // An object or function stays in the page: read it (calling a function
      // first) by reference, so the source never runs twice.
      if (v['objectId'] case final String id) {
        final r = await _s.send('Runtime.callFunctionOn', {
          'objectId': id,
          'functionDeclaration': 'function() { return typeof this === "function" ? this() : this; }',
          'awaitPromise': true,
          'returnByValue': true,
          'userGesture': true,
        }, _timeout - sw.elapsed);
        unawaited(_s.send('Runtime.releaseObject', {'objectId': id}).then<void>((_) {}, onError: (Object _) {}));
        _thrown(r, 'run');
        v = r['result']! as Map<String, Object?>;
      }
      return Json.of(_value(v));
    } on TimeoutException {
      throw _Timeout('run timed out', _timeout, js.length > 80 ? '${js.substring(0, 80)}…' : js);
    }
  }

  /// Evaluate [js], bounded by the page's timeout.
  Future<Map<String, Object?>> _eval(String js, {bool byValue = true}) async {
    final r = await _s.send('Runtime.evaluate', {
      'expression': js,
      'awaitPromise': true,
      'returnByValue': byValue,
      'userGesture': true,
    }, _timeout);
    _thrown(r, 'run');
    return r['result']! as Map<String, Object?>;
  }

  /// Throw the page's exception from a `Runtime` reply, if any.
  static void _thrown(Map<String, Object?> r, String what) {
    if (r['exceptionDetails'] case final Map<String, Object?> d) {
      final ex = d['exception'] as Map?;
      throw BrowserException('$what: ${ex?['description'] ?? d['text']}', cause: d);
    }
  }

  static Object? _value(Map<String, Object?> v) => switch (v['unserializableValue']) {
    'NaN' => double.nan,
    'Infinity' => double.infinity,
    '-Infinity' => double.negativeInfinity,
    '-0' => -0.0,
    final String big when big.endsWith('n') => int.tryParse(big.substring(0, big.length - 1)),
    _ => v['value'],
  };

  /// The cookies the current URL would send (every cookie the browser holds
  /// with [all]), as a [Cookies] jar with their domain, path, expiry and
  /// `secure` flag: hand it to `Http.client(cookies:)`, or persist it with
  /// `encode()`.
  Future<Cookies> cookies({bool all = false}) async {
    final r = all
        ? await _browser._cdp.browser.send('Storage.getCookies')
        : await _s.send('Network.getCookies', {
            'urls': [_url],
          });
    final out = Cookies();
    for (final c in (r['cookies']! as List).cast<Map<String, Object?>>()) {
      final expires = (c['expires'] as num?) ?? -1;
      jar.addCookie(
        out,
        name: c['name']! as String,
        value: c['value']! as String,
        domain: c['domain']! as String,
        path: c['path'] as String? ?? '/',
        secure: c['secure'] == true,
        expires: c['session'] == true || expires <= 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch((expires * 1000).round()),
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
        if (_clock.elapsed >= end) throw _Timeout('no cookie "$name"', limit, _url);
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
    void Function()? off;
    // Listened, it is pending work: the script waits for its events.
    final listened = Completer<void>();
    late final StreamController<Capture> out;
    out = StreamController<Capture>(
      onListen: () {
        _browser._cdp.hold(listened.future).ignore();
        off = _s.on('Network.responseReceived', (e) {
          if (e['type'] != 'XHR' && e['type'] != 'Fetch') return;
          final r = e['response']! as Map<String, Object?>;
          final url = r['url']! as String;
          if (!match.hasMatch(url)) return;
          out.add(
            Capture._((r['status']! as num).toInt(), url, {
              for (final h in (r['headers']! as Map).entries) (h.key as String).toLowerCase(): '${h.value}',
            }, _body(e['requestId']! as String, url)),
          );
        });
        _s.gone.then((_) {
          if (!listened.isCompleted) listened.complete();
          return out.close();
        });
      },
      onCancel: () {
        off?.call();
        if (!listened.isCompleted) listened.complete();
      },
    );
    return out.stream;
  }

  /// A response body, fetched once the request finished.
  Future<List<int>> _body(String id, String url) async {
    final done = _ends[id] ??= Completer<bool>();
    if (!await _browser._cdp.hold(done.future)) throw BrowserException('response failed: $url');
    final r = await _s.send('Network.getResponseBody', {'requestId': id});
    final body = r['body']! as String;
    return r['base64Encoded'] == true ? base64Decode(body) : utf8.encode(body);
  }

  /// [work], or [BrowserException] `browser closed` when the window closes first.
  Future<T> _whileOpen<T>(Future<T> work, [String? selector]) {
    work.ignore();
    return Future.any([
      work,
      _s.gone.then<T>(
        (_) => throw BrowserException(
          selector == null ? 'browser closed' : 'browser closed: wait $selector',
          selector: selector,
        ),
      ),
    ]);
  }

  /// Click the first match of [selector], waiting until it is actionable
  /// (up to [timeout]): scrolled into view, then pressed at the centre of its
  /// visible box. Returns this page.
  Future<Page> click(String selector, {Duration? timeout}) =>
      _act('click', selector, () => _on(selector, _Ready.actionable, timeout, (el) => _click(el, selector)));

  Future<void> _click(String el, String selector) async {
    final at = await _call(el, _pointJs);
    if (at is! List) throw BrowserException('click $selector: outside the viewport', selector: selector);
    final x = at[0] as num, y = at[1] as num;
    await Future.wait([
      _s.send('Input.dispatchMouseEvent', {'type': 'mouseMoved', 'x': x, 'y': y}),
      for (final (type, buttons) in [('mousePressed', 1), ('mouseReleased', 0)])
        _s.send('Input.dispatchMouseEvent', {
          'type': type,
          'x': x,
          'y': y,
          'button': 'left',
          'buttons': buttons,
          'clickCount': 1,
        }),
    ]);
  }

  /// Scroll into view if needed; the centre of the first box part inside
  /// the viewport, or null.
  static const _pointJs = '''
function() {
  if (this.scrollIntoViewIfNeeded) this.scrollIntoViewIfNeeded(true);
  else this.scrollIntoView({block: 'center', inline: 'center'});
  for (const r of this.getClientRects()) {
    const x1 = Math.max(r.left, 0), y1 = Math.max(r.top, 0);
    const x2 = Math.min(r.right, innerWidth), y2 = Math.min(r.bottom, innerHeight);
    if (x2 - x1 >= 1 && y2 - y1 >= 1) return [(x1 + x2) / 2, (y1 + y2) / 2];
  }
  return null;
}''';

  /// Replace the field's content keystroke by keystroke (firing `input` and
  /// `change`), waiting until it is actionable. Works on inputs, textareas
  /// and `contenteditable` elements. Always clears first, so an empty
  /// [value] empties the field. Returns this page.
  Future<Page> fill(String selector, String value, {Duration? timeout}) => _act(
    'fill',
    selector,
    () => _on(selector, _Ready.actionable, timeout, (el) async {
      await _call(el, _clearJs);
      await _type(value);
      await _call(el, 'function() { this.dispatchEvent(new Event("change", {bubbles: true})); }');
    }),
  );

  static const _clearJs = '''
function() {
  this.focus();
  if (this.isContentEditable) {
    const range = document.createRange();
    range.selectNodeContents(this);
    const sel = getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    if (this.textContent) document.execCommand('delete');
  } else if ('value' in this) {
    this.value = '';
    this.dispatchEvent(new Event('input', {bubbles: true}));
  }
}''';

  /// Type [text]: ASCII as key events (frameworks listen for `keydown`),
  /// anything else as inserted text. Sent pipelined, awaited together.
  Future<void> _type(String text) {
    final sends = <Future<void>>[];
    final other = StringBuffer();
    void flush() {
      if (other.isEmpty) return;
      sends.add(_s.send('Input.insertText', {'text': other.toString()}));
      other.clear();
    }

    for (final c in text.split('')) {
      final key = c == '\n' || c == '\r' ? _named['enter'] : _char(c);
      if (key == null) {
        other.write(c);
      } else {
        flush();
        sends.addAll(_keyPress(key, 0));
      }
    }
    flush();
    return Future.wait(sends);
  }

  /// Send a key or a chord, with the key names shared with `Console`/`Tui`
  /// (`'enter'`, `'tab'`, `'down'`, `'ctrl+a'`; a single printable
  /// character is typed; `'wheelup'`/`'wheeldown'` scroll). Aliases (`'esc'`,
  /// `'cmd'`, `'control'`) canonicalize to the shared table; an unknown name
  /// is an [ArgumentError], never a silent mis-hit. Returns this page.
  Future<Page> press(String key) async {
    final lower = key.toLowerCase();
    if (lower == 'wheelup' || lower == 'wheeldown') {
      return _act('press $key', null, () => _eval('window.scrollBy(0, ${lower == 'wheelup' ? -400 : 400})'));
    }
    final canonical = keys.canonicalize(key); // throws ArgumentError first
    return _act('press $key', null, () => _press(canonical));
  }

  Future<void> _press(String canonical) {
    final parts = canonical == '+' ? ['+'] : canonical.split('+');
    final mods = [for (final m in parts.sublist(0, parts.length - 1)) _modifiers[m]!];
    final main = parts.last;
    final key = main.length == 1 ? (_char(main) ?? (main, '', 0, main)) : _named[main]!;
    var bits = 0;
    final sends = <Future<void>>[];
    for (final (name, code, keyCode, bit) in mods) {
      bits |= bit;
      sends.add(_key('rawKeyDown', (name, code, keyCode, null), bits));
    }
    sends.addAll(_keyPress(key, bits));
    for (final (name, code, keyCode, bit) in mods.reversed) {
      bits &= ~bit;
      sends.add(_key('keyUp', (name, code, keyCode, null), bits));
    }
    return Future.wait(sends);
  }

  /// Key down and up; text only when no modifier but shift is held.
  List<Future<void>> _keyPress(_Key key, int bits) {
    final text = bits & ~8 == 0 ? key.$4 : null;
    return [
      _key(text == null ? 'rawKeyDown' : 'keyDown', (key.$1, key.$2, key.$3, text), bits),
      _key('keyUp', key, bits),
    ];
  }

  Future<void> _key(String type, _Key key, int bits) => _s.send('Input.dispatchKeyEvent', {
    'type': type,
    'modifiers': bits,
    'key': key.$1,
    'code': key.$2,
    'windowsVirtualKeyCode': key.$3,
    if (type != 'keyUp' && key.$4 != null) ...{'text': key.$4, 'unmodifiedText': key.$4},
  });

  /// A printable ASCII character as a key (key, code, keyCode, text), or null.
  static _Key? _char(String c) {
    final u = c.codeUnitAt(0);
    if (u < 0x20 || u > 0x7e) return null;
    if (u >= 0x61 && u <= 0x7a) return (c, 'Key${c.toUpperCase()}', u - 32, c);
    if (u >= 0x41 && u <= 0x5a) return (c, 'Key$c', u, c);
    if (u >= 0x30 && u <= 0x39) return (c, 'Digit$c', u, c);
    if (u == 0x20) return _named['space'];
    return (c, '', 0, c);
  }

  /// The §4.12 key names as DevTools keys.
  static final Map<String, _Key> _named = {
    'enter': ('Enter', 'Enter', 13, '\r'),
    'tab': ('Tab', 'Tab', 9, null),
    'escape': ('Escape', 'Escape', 27, null),
    'backspace': ('Backspace', 'Backspace', 8, null),
    'up': ('ArrowUp', 'ArrowUp', 38, null),
    'down': ('ArrowDown', 'ArrowDown', 40, null),
    'left': ('ArrowLeft', 'ArrowLeft', 37, null),
    'right': ('ArrowRight', 'ArrowRight', 39, null),
    'home': ('Home', 'Home', 36, null),
    'end': ('End', 'End', 35, null),
    'pageup': ('PageUp', 'PageUp', 33, null),
    'pagedown': ('PageDown', 'PageDown', 34, null),
    'delete': ('Delete', 'Delete', 46, null),
    'insert': ('Insert', 'Insert', 45, null),
    'space': (' ', 'Space', 32, ' '),
    for (var n = 1; n <= 12; n++) 'f$n': ('F$n', 'F$n', 111 + n, null),
  };

  static const _modifiers = {
    'alt': ('Alt', 'AltLeft', 18, 1),
    'ctrl': ('Control', 'ControlLeft', 17, 2),
    'meta': ('Meta', 'MetaLeft', 91, 4),
    'shift': ('Shift', 'ShiftLeft', 16, 8),
  };

  /// Pick the `<option>` by its value, waiting until actionable.
  /// Throws [BrowserException] when the option is missing. Returns this page.
  Future<Page> select(String selector, String value, {Duration? timeout}) => _act(
    'select',
    selector,
    () => _on(selector, _Ready.actionable, timeout, (el) async {
      if (await _call(el, _selectJs, [value]) != true) {
        throw BrowserException('no option "$value" in $selector', selector: selector);
      }
    }),
  );

  static const _selectJs = '''
function(value) {
  if (!this.options) throw new Error('not a <select>');
  const option = [...this.options].find((o) => o.value === value);
  if (!option) return false;
  option.selected = true;
  this.dispatchEvent(new Event('input', {bubbles: true}));
  this.dispatchEvent(new Event('change', {bubbles: true}));
  return true;
}''';

  /// Set a file input from a [Reader]: the name and path come from the
  /// typed `file.origin()` (a `File` keeps its name; any other reader is
  /// staged under its origin name, else `upload`). File inputs are usually
  /// hidden, so this waits for *attached*, not visible. Staged copies are
  /// kept until this tab closes (the browser reads them at submit). The
  /// browser fires `input`/`change`. Returns this page.
  Future<Page> upload(String selector, Reader file, {Duration? timeout}) async {
    final (path, tmp) = await _stage(file);
    if (tmp != null) _stagedDirs.add(tmp);
    try {
      return await _act(
        'upload',
        selector,
        () => _on(selector, _Ready.attached, timeout, (el) async {
          await _s.send('DOM.setFileInputFiles', {
            'objectId': el,
            'files': [p.absolute(path)],
          });
        }),
      );
    } catch (_) {
      if (tmp != null) {
        _stagedDirs.remove(tmp);
        await _delete(tmp);
      }
      rethrow;
    }
  }

  /// Bring the first match of the selector [to] into view, waiting until it
  /// is attached (up to [timeout]); with no selector, go to the bottom of
  /// the page (what infinite lists need). Returns this page.
  Future<Page> scroll({String? to, Duration? timeout}) => _act('scroll', to, () async {
    if (to == null) {
      await _eval('window.scrollTo(0, document.body.scrollHeight)');
    } else {
      await _on(to, _Ready.attached, timeout, (el) => _call(el, 'function() { this.scrollIntoViewIfNeeded(true); }'));
    }
  });

  /// Run one action; returns this page. Timeouts, [ArgumentError]s and
  /// toolkit exceptions pass through; a protocol failure is rethrown naming
  /// the action and [selector], and anything else becomes a
  /// [BrowserException].
  Future<Page> _act(String what, String? selector, Future<void> Function() body) async {
    try {
      await body();
    } on BrowserException catch (e) {
      if (e.selector != null || selector == null) rethrow;
      throw BrowserException('$what $selector: ${e.message}', selector: selector, cause: e);
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
    await _whileOpen(_on(selector, _Ready.visible, timeout, (_) async {}), selector);
    return this;
  }

  /// Wait until there has been no request in flight for 500 ms. A request
  /// open longer than 5 s (a long-poll, an event stream) stops counting, so
  /// a page that keeps one open still settles. Returns this page.
  Future<Page> idle({Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    final start = _clock.elapsed;
    for (;;) {
      final now = _clock.elapsed;
      final left = limit - (now - start);
      var wait = left;
      var busy = false;
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
      if (left <= Duration.zero) throw _Timeout('network never idle', limit, _url);
      if (!busy && _quietPeriod - quiet < wait) wait = _quietPeriod - quiet;
      final notified = _idleNotified ??= Completer<void>();
      await notified.future.timeout(wait, onTimeout: () {});
    }
  }

  /// A PNG of the viewport (or the whole page with [fullPage]), captured
  /// when read.
  Reader screenshot({bool fullPage = false}) => _Shot(() async {
    Map<String, Object?>? clip;
    if (fullPage) {
      final size = (await _s.send('Page.getLayoutMetrics'))['cssContentSize']! as Map;
      clip = {'x': 0, 'y': 0, 'width': size['width'], 'height': size['height'], 'scale': 1};
    }
    final r = await _s.send('Page.captureScreenshot', {
      'format': 'png',
      if (clip != null) ...{'clip': clip, 'captureBeyondViewport': true},
    });
    return base64Decode(r['data']! as String);
  });

  /// The page printed, captured when read.
  Reader pdf() => _Shot(() async => base64Decode((await _s.send('Page.printToPDF'))['data']! as String));

  /// Click [selector] and wait for the download it starts, in this tab or
  /// any of its frames, to begin. Returns a [Download]: the name the site
  /// suggested, and a [Reader] of the file that waits for it to finish
  /// (`d & Console.bar(d.name()) > Fs.file(d.name())` shows the browser's
  /// progress). Downloads share one folder per browser, told apart by their
  /// DevTools `guid`, so concurrent downloads don't clash. Beginning and
  /// finishing share one [timeout] deadline. The browser's copies are
  /// removed when the browser closes.
  Future<Download> download(String selector, {Duration? timeout}) async {
    final limit = timeout ?? _defaultTimeout;
    final sw = Stopwatch()..start();
    Duration left() => limit - sw.elapsed < Duration.zero ? Duration.zero : limit - sw.elapsed;
    final events = _browser._cdp.browser;
    final prev = _dlGate;
    final gate = Completer<void>();
    _dlGate = gate.future;
    Map<String, Object?>? begun;
    final String dir;
    // Heard from before the click: a small file can finish before
    // `downloadWillBegin` is handled, and its progress goes to its Download.
    final ended = <Object?, Map<String, Object?>>{};
    final heard = <Object?, Download>{};
    final stopHearing = events.on('Browser.downloadProgress', (e) {
      heard[e['guid']]?._progress(e);
      if (e['state'] == 'completed' || e['state'] == 'canceled') ended[e['guid']] = e;
    });
    try {
      await prev;
      dir = await _browser._downloadFolder();
      await _act('download', selector, () async {
        await _on(selector, _Ready.actionable, timeout, (el) async {
          final begin = events.once(
            'Browser.downloadWillBegin',
            where: (e) => _frames.contains(e['frameId']),
            timeout: left(),
          );
          begin.ignore();
          await _click(el, selector);
          try {
            begun = await begin;
          } on TimeoutException {
            throw _Timeout('no download from $selector', limit);
          }
        });
      });
    } catch (_) {
      stopHearing();
      rethrow;
    } finally {
      gate.complete();
    }
    final guid = begun!['guid']! as String;
    final suggested = begun!['suggestedFilename'] as String? ?? '';
    final safe = names.stripPath(suggested);
    Future<io.File> finish() async {
      final Map<String, Object?> end;
      try {
        end =
            ended[guid] ??
            await events.once(
              'Browser.downloadProgress',
              where: (e) => e['guid'] == guid && (e['state'] == 'completed' || e['state'] == 'canceled'),
              timeout: left(),
            );
      } on TimeoutException {
        throw _Timeout('download never finished', limit, suggested);
      } finally {
        stopHearing();
      }
      if (end['state'] != 'completed') throw BrowserException('download ${end['state']}: $suggested');
      return io.File(end['filePath'] as String? ?? p.join(dir, guid));
    }

    final download = Download._(safe.isEmpty ? 'download' : safe);
    heard[guid] = download;
    download._finish(finish());
    return download;
  }

  /// Close this tab. Idempotent.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _browser._opened.remove(this);
    _browser._pages.remove(_target);
    await _unstage();
    try {
      await _browser._cdp.browser.send('Target.closeTarget', {'targetId': _target});
      await _s.gone.timeout(const Duration(seconds: 2));
    } catch (_) {
      // Already closed with the browser.
    }
  }

  Future<void> _unstage() async {
    for (final dir in _stagedDirs) {
      await _delete(dir);
    }
    _stagedDirs.clear();
  }

  /// Wait for [selector] to be ready per [mode], then run [use] on its
  /// remote object id and release it.
  Future<void> _on(String selector, _Ready mode, Duration? timeout, Future<void> Function(String el) use) async {
    final el = await _ready(selector, mode, timeout ?? _defaultTimeout);
    try {
      await use(el);
    } finally {
      if (!_s.isGone) _s.send('Runtime.releaseObject', {'objectId': el}).ignore();
    }
  }

  /// One in-page promise polls [_readyJs] every 50 ms until the first match
  /// is ready (`requestAnimationFrame` pauses in background tabs) and
  /// resolves with the element: one round trip per wait, no gap between the
  /// check and the use. A navigation mid-wait retries in the new document;
  /// an invalid selector fails fast with [ContentException].
  Future<String> _ready(String selector, _Ready mode, Duration limit) async {
    final sw = Stopwatch()..start();
    for (;;) {
      final left = limit - sw.elapsed;
      final Map<String, Object?> r;
      try {
        r = await _s
            .send('Runtime.evaluate', {
              'expression': '($_readyJs)(${jsonEncode(selector)}, "${mode.name}", ${left.inMilliseconds})',
              'awaitPromise': true,
            })
            .timeout(left + const Duration(seconds: 1));
      } on TimeoutException {
        throw _Timeout('no ${mode.name} $selector', limit);
      } on BrowserException catch (e) {
        if (_contextGone(e.message) && sw.elapsed < limit) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          continue;
        }
        throw BrowserException('${mode.name} $selector: ${e.message}', selector: selector, cause: e);
      }
      if (r['exceptionDetails'] case final Map<String, Object?> d) {
        final text = '${(d['exception'] as Map?)?['description'] ?? d['text']}';
        if (_contextGone(text) && sw.elapsed < limit) continue;
        throw BrowserException('${mode.name} $selector: $text', selector: selector, cause: d);
      }
      final v = r['result']! as Map;
      if (v['subtype'] == 'node') return v['objectId']! as String;
      if (v['value'] == 'invalid-selector') throw ContentException("invalid selector '$selector'");
      throw _Timeout('no ${mode.name} $selector', limit);
    }
  }

  static bool _contextGone(String message) =>
      message.contains('context was destroyed') ||
      message.contains('navigated or closed') ||
      message.contains('Cannot find default execution context');

  /// Valid selector, attached, and (per mode) visible and enabled.
  static const _readyJs = '''
async (selector, mode, ms) => {
  const end = Date.now() + ms;
  const check = () => {
    let el;
    try { el = document.querySelector(selector); } catch (_) { return 'invalid-selector'; }
    if (!el) return null;
    if (mode === 'attached') return el;
    const rect = el.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return null;
    const style = getComputedStyle(el);
    if (style.visibility === 'hidden' || style.display === 'none') return null;
    if (mode === 'visible') return el;
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') return null;
    return el;
  };
  for (;;) {
    const v = check();
    if (v || Date.now() >= end) return v;
    await new Promise((r) => setTimeout(r, 50));
  }
}''';

  /// Call [fn] with `this` = the element [el]; its result by value.
  Future<Object?> _call(String el, String fn, [List<Object?> args = const []]) async {
    final r = await _s.send('Runtime.callFunctionOn', {
      'objectId': el,
      'functionDeclaration': fn,
      'arguments': [
        for (final a in args) {'value': a},
      ],
      'returnByValue': true,
      'awaitPromise': true,
    });
    _thrown(r, 'call');
    return (r['result']! as Map)['value'];
  }

  /// The path to hand the browser, and the temp dir staged for it.
  Future<(String, io.Directory?)> _stage(Reader file) async {
    final o = file.origin();
    if (o.path() case final keep?) return (keep, null);
    var name = names.stripPath(o.name() ?? '');
    if (name.isEmpty) name = 'upload';
    final tmp = await io.Directory.systemTemp.createTemp('dart_toolkit_up');
    final staged = io.File(p.join(tmp.path, name));
    try {
      await (file > _FileWriter(staged));
    } catch (_) {
      await _delete(tmp);
      rethrow;
    }
    return (staged.path, tmp);
  }

  static Future<void> _delete(io.Directory dir) async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}

/// A key as DevTools takes it: key, code, Windows key code, text.
typedef _Key = (String, String, int, String?);

/// What [Page._ready] waits for.
enum _Ready { attached, visible, actionable }

/// A browser download: the name the site suggested, and a [Reader] of the
/// file that waits for the browser to finish it. A probe on it
/// (`d & Console.bar(d.name())`) shows the browser's progress.
final class Download with Reader {
  Download._(this._name) {
    working[this] = _watched;
  }

  final String _name;
  final _done = Completer<io.File>();
  io.File? _file;
  (int, int?) _seen = (0, null);
  final _runs = <Run>[];

  /// The file name the site suggested, made safe like `Response.name()`.
  String name() => _name;

  void _finish(Future<io.File> file) {
    file.then((f) => _done.complete(_file = f), onError: _done.completeError);
    _done.future.ignore(); // a failure surfaces when the download is read
  }

  void _progress(Map<String, Object?> e) {
    final received = (e['receivedBytes'] as num?)?.toInt() ?? 0;
    final total = (e['totalBytes'] as num?)?.toInt();
    _seen = (received, total == null || total <= 0 ? null : total);
    for (final run in _runs) {
      run.report(_seen.$1, _seen.$2, Unit.bytes);
    }
  }

  /// The path once the browser has finished the file (a reader of paths
  /// never sees half of it).
  @override
  Origin origin() => Origin(name: _name, path: _file?.path);

  @override
  Stream<List<int>> stream() async* {
    yield* (await _done.future).openRead();
  }

  /// Watched: the browser's bytes as they arrive, then the file.
  Stream<List<int>> _watched(Run run) async* {
    _runs.add(run);
    run.report(_seen.$1, _seen.$2, Unit.bytes);
    try {
      final file = await _done.future;
      final size = await file.length();
      run.report(size, size, Unit.bytes);
      yield* file.openRead();
    } finally {
      _runs.remove(run);
    }
  }
}

/// An XHR/fetch response the page received ([Page.responses]). The body is
/// requested from the browser as the response finishes, so reading it later
/// still works after the page moves on. Readings use http's names.
final class Capture with Reader {
  Capture._(this._status, this._url, this._headers, this._body) {
    _body.ignore();
  }

  final int _status;
  final String _url;
  final Map<String, String> _headers;
  final Future<List<int>> _body;

  /// HTTP status.
  int status() => _status;

  /// The response URL.
  String url() => _url;

  /// Response header [name] (case-insensitive), or null.
  String? header(String name) => _headers[name.toLowerCase()];

  /// A file name for the body, as `Response.name()` gives one: the
  /// `content-disposition` filename, else the URL's last segment.
  String name() => origins.fileName(url: _url, contentDisposition: header('content-disposition'));

  @override
  Origin origin() => Origin(url: _url, status: _status, name: name());

  @override
  Stream<List<int>> stream() => Stream.fromFuture(_body);

  @override
  Future<List<int>> bytes() => _body;
}

/// A [TimeoutException] that prints its limit once, for people:
/// `TimeoutException: no actionable #nope after 1 s`.
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
    Set<Resource> block = const {},
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
  Future<Json> run(String js) async => (await this).run(js);
  Future<Cookies> cookies({bool all = false}) async => (await this).cookies(all: all);
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
  Future<Page> scroll({String? to, Duration? timeout}) async => (await this).scroll(to: to, timeout: timeout);
  Future<Page> wait(String selector, {Duration? timeout}) async => (await this).wait(selector, timeout: timeout);
  Future<Page> idle({Duration? timeout}) async => (await this).idle(timeout: timeout);
  Reader screenshot({bool fullPage = false}) => _later((p) => p.screenshot(fullPage: fullPage));
  Reader pdf() => _later((p) => p.pdf());

  /// A reader on this page's [reader]; a failed page future with no reader
  /// yet never surfaces as an unhandled error (reading still gets it).
  Reader _later(Reader Function(Page) reader) {
    then((_) {}, onError: (_) {}).ignore();
    return _Shot(() async => reader(await this).bytes());
  }

  Future<Download> download(String selector, {Duration? timeout}) async =>
      (await this).download(selector, timeout: timeout);
}

/// Content captured when read.
final class _Shot with Reader {
  _Shot(this._capture);

  final Future<List<int>> Function() _capture;

  @override
  Stream<List<int>> stream() async* {
    yield await _capture();
  }
}

final class _FileWriter with Writer {
  _FileWriter(this._file);

  final io.File _file;

  @override
  Future<void> consume(Stream<List<int>> input) => posix.writeAll(_file, input);
}
