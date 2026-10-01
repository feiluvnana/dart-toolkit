part of '../../chrome.dart';

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

  /// When this tab last started a download: Chrome starts about ten a second per page and
  /// silently drops the rest, so [waitForDownload] keeps its starts [_downloadGap] apart.
  DateTime? _downloadBegan;
  static const _downloadGap = Duration(milliseconds: 120);
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

  /// Frame tracking, switched on by the tab's first [frame] call and never before:
  /// `Runtime.enable` is a mark an automated browser leaves for a page to find, and every
  /// console line and worker it reports would otherwise be decoded for nothing.
  Future<void>? _frames;

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
  Future<Response> goto(Uri url, {ChromeWait? until, Duration? challenge, Request? request}) async =>
      (await _goto(url, until: until, challenge: challenge, request: request, read: true))!;

  /// [goto], which reads the DOM only when [read] asks or the status could be an interstitial:
  /// a render with a `waitFor` or a `script` reads it once, after them, not here as well.
  Future<Response?> _goto(
    Uri url, {
    required bool read,
    ChromeWait? until,
    Duration? challenge,
    Request? request,
  }) async {
    final wait = until ?? _client._wait;
    _arm(wait._lifecycle);
    _answer = null;
    // A frame view navigates its frame; without the id, Chrome would move the whole tab.
    final nav = await _call('Page.navigate', {'url': '$url', if (_parent != null && !_remote) 'frameId': _frame});
    if (nav['errorText'] case final String error when error.isNotEmpty) {
      _disarm();
      // A 204 or 205 is an answer that keeps the page where it was, and Chrome reports it as
      // an aborted navigation. It is a response — the server said "nothing to show".
      if (error.contains('ERR_ABORTED') || error.contains('ERR_HTTP_RESPONSE_CODE_FAILURE')) {
        if (await _empty(url, request) case final answered?) return answered;
      }
      throw ClientException(_readable(error), url);
    }
    if (nav['frameId'] case final String frame when frame.isNotEmpty && _parent == null) _frame = frame;
    if (nav['loaderId'] case final String loader when loader.isNotEmpty) _loader = _expect = loader;
    _url = url;
    await _settle();

    final patience = challenge ?? _client._challenge;
    // Only a 403, 429 or 503 can be an interstitial, so only those are read to find out.
    if (patience <= Duration.zero || !_challenging(statusCode)) return read ? response(request) : null;
    var res = await response(request);
    if (!_interstitial(res)) return res;
    // The page is a challenge: Cloudflare's reload, a 503 that comes back, a box for a
    // human to click. None of that is a failure, and the tab stays open for it.
    final deadline = DateTime.now().add(patience);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!_alive) break;
      try {
        res = await response(request);
      } catch (e) {
        final msg = '$e';
        if (msg.contains('navigated') || msg.contains('closed') || msg.contains('Execution context was destroyed')) {
          await _settle();
          continue;
        }
        rethrow;
      }
      if (!_interstitial(res)) return res;
    }
    return res;
  }

  /// The bodiless answer an aborted navigation got, if it got a 204 or 205, or an empty 4xx/5xx;
  /// the event may trail the command's reply by a moment.
  Future<Response?> _empty(Uri url, Request? request) async {
    for (var i = 0; i < 25 && _answer == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final answer = _answer;
    final status = (answer?['status'] as num?)?.toInt();
    if (status == null || (status != 204 && status != 205 && status < 400)) return null;
    final headers = Headers();
    if (answer?['headers'] case final Map<String, Object?> raw) {
      raw.forEach((name, value) => headers[name] = '$value');
    }
    return Response.bytes(Uint8List(0), status, headers: headers, request: request, url: url);
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
      ..['content-type'] = '$mime; charset=utf-8';
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
    final deadline = DateTime.now().add(limit);
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return false;
      try {
        final found = await eval(
          '''
new Promise((resolve) => {
  const hit = () => $hit;
  if (hit()) return resolve(true);
  const observer = new MutationObserver(() => { if (hit()) { observer.disconnect(); resolve(true); } });
  observer.observe(document.documentElement, {childList: true, subtree: true, attributes: true});
  setTimeout(() => { observer.disconnect(); resolve(false); }, ${remaining.inMilliseconds});
})''',
          awaitPromise: true,
          timeout: remaining + const Duration(seconds: 5),
        );
        return found == true;
      } catch (e) {
        if (!_alive) rethrow;
        final msg = '$e';
        if (msg.contains('navigated') || msg.contains('closed') || msg.contains('Execution context was destroyed')) {
          await _settle();
          continue;
        }
        rethrow;
      }
    }
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
      _ => (key.toUpperCase().codeUnitAt(0), key),
    };
    for (final type in ['keyDown', 'keyUp']) {
      await _call('Input.dispatchKeyEvent', {
        'type': type,
        'key': key,
        'windowsVirtualKeyCode': code,
        if (type == 'keyDown' && text != null) 'text': text,
      });
    }
  }

  /// Scrolls to the bottom [times] times, waiting [settle] after each — an infinite feed,
  /// loaded. Answers the page height when it stopped growing.
  ///
  /// With [toEnd], it scrolls until the height stops growing however many times that takes,
  /// for at most the client's `timeout` — a feed that never ends is a feed read for that long.
  Future<num> scroll({int times = 3, bool toEnd = false, Duration settle = const Duration(milliseconds: 500)}) async {
    num height = 0;
    final deadline = DateTime.now().add(_client._timeout);
    for (var i = 0; toEnd ? DateTime.now().isBefore(deadline) : i < times; i++) {
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
      final metrics = await _call('Page.getLayoutMetrics');
      final visual = metrics['visualViewport'] as Map<String, Object?>? ?? const {};
      final pageX = (visual['pageX'] as num?)?.toDouble() ?? 0.0;
      final pageY = (visual['pageY'] as num?)?.toDouble() ?? 0.0;
      params
        ..['captureBeyondViewport'] = true
        ..['clip'] = {
          'x': quad[0] + pageX,
          'y': quad[1] + pageY,
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
  /// Chrome lets one page start about ten downloads a second and drops the rest, so a wait
  /// that follows another on the same tab within ~120 ms holds back its action until then; a
  /// loop over many tiny files needs no pacing of its own.
  ///
  /// ```dart
  /// final file = await page.waitForDownload(() => page.click('.download'), to: 'books'.path);
  /// ```
  Future<Path?> waitForDownload(FutureOr<void> Function() action, {Path? to, Duration? timeout}) async {
    final landing = Path((await _client._downloads()).path);
    final idle = timeout ?? _client._timeout;
    String? id;
    String? suggested;
    final finished = Completer<bool>();
    void done(bool ok) {
      if (!finished.isCompleted) finished.complete(ok);
    }

    // Silence for [idle] is the end of the wait; every event about the download starts it
    // again, and the one that says it is complete ends it at once.
    Timer? quiet;
    void stirred() {
      quiet?.cancel();
      quiet = Timer(idle, () => done(false));
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
          _owner._downloadBegan = DateTime.now();
          id = guid;
          suggested = event.params['suggestedFilename'] as String?;
          stirred();
        case 'Browser.downloadProgress':
          if (event.params['guid'] != id) return;
          // Every one of these is proof the transfer is alive, whatever it says.
          stirred();
          if (event.params['state'] case 'completed') done(true);
          if (event.params['state'] case 'canceled') done(false);
      }
    });
    try {
      if (_owner._downloadBegan case final began?) {
        final wait = _downloadGap - DateTime.now().difference(began);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      stirred();
      await action();
      if (!await finished.future) {
        if (id case final guid?) await _client._abandon(guid, landing);
        return null;
      }
      final into = (to ?? Path.current).absolute;
      await into.mkdir();
      final wanted = await _unused(into, _fileName(suggested ?? id!));
      await (landing / id!).move(wanted.path);
      return wanted;
    } finally {
      quiet?.cancel();
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
        case 'Network.loadingFinished' || 'Network.loadingFailed':
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
  /// `page.cookies()` reads them — after a login, to hand to something that is not a browser:
  /// `Http.scope(jar: await page.cookies(), …)` carries the session to plain sockets.
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
    final all = await _call('Storage.getCookies');
    return [
      for (final c in (all['cookies'] as List? ?? const []).cast<Map<String, Object?>>())
        Cookie(c['name'] as String? ?? '', c['value'] as String? ?? '')
          ..domain = c['domain'] as String?
          ..path = c['path'] as String?
          ..secure = c['secure'] == true
          ..httpOnly = c['httpOnly'] == true
          ..expires = (c['expires'] is num && (c['expires'] as num) > 0)
              ? DateTime.fromMillisecondsSinceEpoch(((c['expires'] as num) * 1000).round())
              : null,
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
    await (owner._frames ??= owner._watchFrames());
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
    for (final remote in _remotes.values) {
      await _client._sessions.remove(remote.session)?.close();
    }
    _remotes.clear();
    await _client._sessions.remove(_tab.session)?.close();
    try {
      await _client._call('Target.closeTarget', {'targetId': _tab.target});
    } catch (_) {}
  }

  // ---- internals -------------------------------------------------------------------------

  /// Execution contexts for in-process frames, and a session for each out-of-process one.
  Future<void> _watchFrames() async {
    await _call('Runtime.enable');
    await _call('Target.setAutoAttach', {'autoAttach': true, 'waitForDebuggerOnStart': false, 'flatten': true});
  }

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

  /// The statuses an interstitial answers with.
  static bool _challenging(int? status) => status == 403 || status == 503 || status == 429;

  /// Whether this looks like an interstitial rather than the page that was asked for.
  bool _interstitial(Response res) {
    if (!_challenging(res.statusCode)) return false;
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
