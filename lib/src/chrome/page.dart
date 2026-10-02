part of '../../chrome.dart';

/// One tab, open for as long as the work takes: what [ChromeClient.open] hands over and what
/// [ChromeClient.send] drives underneath.
///
/// Reads never throw on an empty result and waits never throw on time ([waitFor] answers
/// `false`, [response] answers the DOM as it stands), so an interstitial is always readable.
///
/// {@category Networking}
final class ChromePage {
  final ChromeClient _client;
  final _Tab _tab;

  /// The tab's page when this is a [frame] view.
  final ChromePage? _parent;

  /// Execution context per frame id; filled by the tab's page, read by its frame views.
  final Map<String, int> _contexts = {};

  StreamSubscription<_Cdp>? _events;
  FutureOr<void> Function(Dialog dialog)? _onDialog;

  /// Chrome starts ~10 downloads a second per page and silently drops the rest, so
  /// [waitForDownload] keeps starts [_downloadGap] apart.
  DateTime? _downloadBegan;
  static const _downloadGap = Duration(milliseconds: 120);
  Set<Resource>? _blocked;

  /// The render's credentials and the one origin they may go to.
  ({String origin, Map<String, String> headers})? _grant;

  /// What `Fetch.enable` was last told, so an unchanged render costs no round trip, and the
  /// call itself (`null` when disabled), repeated on every out-of-process frame.
  String? _intercepting;
  Map<String, Object?>? _fetching;
  Map<String, Object?>? _document;
  Completer<void>? _waiter;
  String _want = '';

  /// The frame's last committed loader, the one an armed wait must ignore, and the one it
  /// expects once a navigation names it: a late `networkIdle` from the previous page would
  /// otherwise settle the new one before it has a body.
  String? _loader;
  String? _stale;
  String? _expect;

  /// The document response of the navigation in progress, even one that commits nothing.
  Map<String, Object?>? _answer;

  /// Set by the first [frame] call: `Runtime.enable` is a mark pages detect, and costs every
  /// console line and worker event.
  Future<void>? _frames;

  /// Out-of-process frames by id: their session and last URL.
  final Map<String, ({String session, String url})> _remotes = {};

  /// The tab's watch on each out-of-process frame's session, by session.
  final Map<String, StreamSubscription<_Cdp>> _children = {};

  /// An out-of-process frame, driven through its own session.
  final bool _remote;
  String _frame = '';
  Uri _url = Uri.parse('about:blank');
  bool _alive = true;

  ChromePage._(this._client, this._tab, {ChromePage? parent, bool remote = false}) : _parent = parent, _remote = remote;

  ChromePage get _owner => _parent ?? this;

  /// The context an in-process frame evaluates in; `null` uses the session's default.
  int? get _context => _parent == null || _remote ? null : _owner._contexts[_frame];

  /// The URL this tab is on, after every redirect and navigation.
  Uri get url => _url;

  /// Whether this tab or its client has been closed.
  bool get isClosed => !_alive || !_owner._alive || _client.isClosed;

  /// The status of the last document loaded, or `null` before the first.
  int? get statusCode => (_document?['status'] as num?)?.toInt();

  /// Navigates, waits, and answers the page as it stands.
  ///
  /// Throws [ClientException] only when Chrome refuses the navigation (unresolved name,
  /// refused connection); an expired wait or an uncleared interstitial is a response.
  /// [challenge] is as in [ChromeClient.launch].
  Future<Response> goto(Uri url, {ChromeWait? until, Duration? challenge, Request? request}) async =>
      (await _goto(url, until: until, challenge: challenge, request: request, read: true))!;

  /// [goto], reading the DOM only when [read] or the status could be an interstitial.
  Future<Response?> _goto(
    Uri url, {
    required bool read,
    ChromeWait? until,
    Duration? challenge,
    Request? request,
  }) async {
    _arm((until ?? _client._wait)._lifecycle);
    _answer = null;
    // Without `frameId` a frame view would navigate the whole tab.
    final nav = await _call('Page.navigate', {'url': '$url', if (_parent != null && !_remote) 'frameId': _frame});
    if (nav['errorText'] case final String error when error.isNotEmpty) {
      _disarm();
      // Chrome reports a 204/205 (and an empty error page) as an aborted navigation.
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
    if (patience <= Duration.zero || !_challenging(statusCode)) return read ? response(request) : null;
    var res = await response(request);
    final deadline = DateTime.now().add(patience);
    while (_interstitial(res) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (isClosed) break;
      try {
        res = await response(request);
      } catch (e) {
        if (!_navigatedAway(e)) rethrow;
        await _settle();
      }
    }
    return res;
  }

  /// The bodiless answer of an aborted navigation, if it was a 204/205, an error status or a
  /// download; the event may trail the command's reply.
  Future<Response?> _empty(Uri url, Request? request) async {
    for (var i = 0; i < 25 && _answer == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final status = (_answer?['status'] as num?)?.toInt();
    if (status == null || (status != 204 && status != 205 && status < 400 && !_attachment(_answer))) return null;
    return Response.bytes(Uint8List(0), status, headers: _wire(_answer?['headers']), request: request, url: url);
  }

  /// The DOM as it stands now, under the status and headers the document was served with.
  /// Callable at any moment.
  Future<Response> response([Request? request]) async {
    final mime = _document?['mimeType'] as String? ?? 'text/html';
    final body = await eval(
      mime.contains('html') || mime.contains('xml')
          ? 'document.documentElement ? document.documentElement.outerHTML : ""'
          : 'document.body ? document.body.innerText : ""',
    );
    final bytes = utf8.encode(body is String ? body : '${body ?? ''}');
    // The wire's length and encoding described the bytes before the page ran.
    final headers = _wire(_document?['headers'])
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

  /// [response], parsed.
  Future<HtmlDocument> html() async => (await response()).html;

  /// Waits until [selector] matches; answers whether it did before [timeout]. A mutation
  /// observer, not a poll.
  Future<bool> waitFor(String selector, {Duration? timeout}) => _watch(selector, timeout: timeout, gone: false);

  /// Waits until [selector] matches nothing (a spinner gone, a challenge cleared); answers
  /// whether it did before [timeout].
  Future<bool> waitWhile(String selector, {Duration? timeout}) => _watch(selector, timeout: timeout, gone: true);

  Future<bool> _watch(String selector, {required bool gone, Duration? timeout}) async {
    final hit = gone ? '!${_q(selector)}' : '!!${_q(selector)}';
    final deadline = DateTime.now().add(timeout ?? _client._timeout);
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
        if (isClosed || !_navigatedAway(e)) rethrow;
        await _settle();
      }
    }
  }

  /// Clicks the first element [selector] matches with real mouse events at its centre,
  /// scrolled into view; through the DOM when it has no box. Answers `false` when nothing
  /// matched.
  Future<bool> click(String selector) async {
    try {
      final at = _centre(await _box(selector) ?? (throw const ClientException('no box')));
      await _mouse('mouseMoved', at);
      await _mouse('mousePressed', at, press: true);
      await _mouse('mouseReleased', at, press: true);
      return true;
    } catch (_) {
      return await eval('(() => { const el = ${_q(selector)}; if (el) el.click(); return !!el; })()') == true;
    }
  }

  /// Focuses the first element [selector] matches and inserts [value] as text: `input`
  /// listeners see it, `keydown` ones may not (use [press]). Answers `false` when nothing
  /// matched.
  Future<bool> fill(String selector, String value) async {
    final node = await _node(selector);
    if (node == null) return false;
    await _call('DOM.focus', {'nodeId': node});
    await eval("(() => { const el = ${_q(selector)}; if (el && 'value' in el) el.value = ''; })()");
    await _call('Input.insertText', {'text': value});
    return true;
  }

  /// Presses a key on whatever has focus: `Enter`, `Tab`, `Escape`, `Backspace`, an arrow, or
  /// a single character.
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
      '' => throw ArgumentError.value(key, 'key', 'is empty'),
      // Only these share their code unit with a key code: `.` is 46, Delete's.
      _ => (_plain.hasMatch(key) ? key.toUpperCase().codeUnitAt(0) : 0, key),
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

  static final _plain = RegExp(r'^[A-Za-z0-9 ]$');

  /// Scrolls to the bottom [times] times, [settle] apart, stopping early when the height stops
  /// growing; answers the final height. [toEnd] scrolls until it stops growing, for at most
  /// the client's `timeout`.
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

  /// Runs [expression] in the page and answers its JSON value; [awaitPromise] awaits a
  /// promise. A script that throws throws [ClientException].
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

  /// A PNG of the window, of the element [selector] matches, or of the whole document with
  /// [full]. Empty when [selector] matched nothing with a box.
  Future<Uint8List> screenshot({String? selector, bool full = false}) async {
    Map<String, Object?>? clip;
    if (selector != null) {
      final quad = await _box(selector);
      if (quad == null) return Uint8List(0);
      final view = (await _call('Page.getLayoutMetrics'))['visualViewport'] as Map<String, Object?>? ?? const {};
      clip = {
        'x': quad[0] + (view['pageX'] as num? ?? 0),
        'y': quad[1] + (view['pageY'] as num? ?? 0),
        'width': quad[2] - quad[0],
        'height': quad[5] - quad[1],
      };
    } else if (full) {
      final metrics = await _call('Page.getLayoutMetrics');
      final size = (metrics['cssContentSize'] ?? metrics['contentSize']) as Map<String, Object?>?;
      clip = {'x': 0, 'y': 0, 'width': size?['width'] ?? 0, 'height': size?['height'] ?? 0};
    }
    final shot = await _call('Page.captureScreenshot', {
      'format': 'png',
      if (clip != null) ...{
        'captureBeyondViewport': true,
        'clip': {...clip, 'scale': 1},
      },
    });
    return base64.decode(shot['data'] as String? ?? '');
  }

  /// The `innerText` of the first element [selector] matches, or `null`; one value without
  /// parsing the whole page.
  Future<String?> text(String selector) async => switch (await eval('${_q(selector)}?.innerText')) {
    final String found => found,
    _ => null,
  };

  /// The `innerText` of the first element [selector] matches, or `null`; see [text].
  Future<String?> textOrNull(String selector) => text(selector);

  /// Attribute [name] of the first element [selector] matches, or `null`. Resolved by the
  /// DOM, so `href` and `src` come back absolute.
  Future<String?> attr(String selector, String name) async => switch (await eval('''(() => {
  const el = ${_q(selector)};
  if (!el) return null;
  const name = ${jsonEncode(name)};
  return typeof el[name] === 'string' ? el[name] : el.getAttribute(name);
})()''')) {
    final String found => found,
    _ => null,
  };

  /// Attribute [name] of the first element [selector] matches, or `null`; see [attr].
  Future<String?> attrOrNull(String selector, String name) => attr(selector, name);

  /// Whether [selector] matches anything right now.
  Future<bool> has(String selector) async => await eval('!!${_q(selector)}') == true;

  /// Chooses the option of the `<select>` [selector] whose value, else text, is [value], and
  /// fires `input` and `change`. Answers `false` when the select or option is missing.
  Future<bool> select(String selector, String value) async =>
      await eval('''(() => {
  const el = ${_q(selector)};
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

  /// Moves the mouse over the first element [selector] matches. Answers `false` when nothing
  /// matched or it has no box.
  Future<bool> hover(String selector) async {
    final quad = await _box(selector);
    if (quad == null) return false;
    try {
      await _mouse('mouseMoved', _centre(quad));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Refuses to load [kinds] in this tab from now on; `block({})` allows everything again.
  /// `page.block(Resource.heavy)` reads the same text in a fraction of the time.
  Future<void> block(Set<Resource> kinds) async {
    _blocked = kinds;
    await _intercept();
  }

  /// Tells Chrome which requests to pause: all of them for an authenticated proxy
  /// (`--proxy-server` cannot carry a password) or a render with a credential to add to its
  /// own origin; otherwise only blocked kinds.
  Future<void> _intercept() async {
    final authenticating = _client._login != null;
    final everything = authenticating || _grant != null;
    final kinds = _blocked ?? const <Resource>{};
    final want = everything
        ? '*${authenticating ? '+auth' : ''}'
        : (kinds.map((k) => k.name).toList()..sort()).join(',');
    if (want == _intercepting) return;
    _intercepting = want;
    _fetching = want.isEmpty
        ? null
        : {
            'patterns': everything
                ? [
                    {'urlPattern': '*', 'requestStage': 'Request'},
                  ]
                : [
                    for (final kind in kinds)
                      for (final type in kind._types)
                        {'urlPattern': '*', 'resourceType': type, 'requestStage': 'Request'},
                  ],
            if (authenticating) 'handleAuthRequests': true,
          };
    await _fetch(_tab);
    for (final remote in _remotes.entries.toList()) {
      await _fetch(_Tab(remote.key, remote.value.session)).catchError((Object _) {});
    }
  }

  /// Applies [_fetching] to [tab]'s session.
  Future<void> _fetch(_Tab tab) => _client._call(_fetching == null ? 'Fetch.disable' : 'Fetch.enable', _fetching, tab);

  /// Sets the cookies in [header] for [url] alone, never as a header every request carries.
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

  /// Runs [action] and waits for the download it starts; answers where the file landed in
  /// [to] (the working directory by default), under the site's name or `name (2).ext`.
  ///
  /// Armed before [action]: a small file can be on disk before the next line runs. Chrome
  /// writes into a client-owned directory and only a finished file is moved, so nothing
  /// half-written reaches [to]. [timeout] is how long the download may go *quiet*, not how
  /// long it may take. One that never starts, stalls or is cancelled answers `null`, its
  /// partial erased.
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

    // Every event about the download restarts the silence timer.
    Timer? quiet;
    void stirred() {
      quiet?.cancel();
      quiet = Timer(idle, () => done(false));
    }

    final watch = _client._browser.stream.listen((event) {
      switch (event.method) {
        case 'Browser.downloadWillBegin' when id == null:
          final guid = event.params['guid'] as String?;
          if (guid == null || _client._claimed.contains(guid)) return;
          // Ours, or from a tab no page owns (`target=_blank`), never another page's.
          final from = event.params['frameId'];
          if (_frame.isNotEmpty && from != _frame && _client._pages.any((p) => p != _owner && p._frame == from)) return;
          _client._claimed.add(guid);
          id = guid;
          suggested = event.params['suggestedFilename'] as String?;
          stirred();
        case 'Browser.downloadProgress' when event.params['guid'] == id:
          stirred();
          switch (event.params['state']) {
            case 'completed':
              done(true);
            case 'canceled':
              done(false);
          }
      }
    });
    try {
      // The slot is taken before waiting, so concurrent waits queue rather than all wake at once.
      final now = DateTime.now();
      final slot = switch (_owner._downloadBegan) {
        final began? when began.add(_downloadGap).isAfter(now) => began.add(_downloadGap),
        _ => now,
      };
      _owner._downloadBegan = slot;
      if (slot.isAfter(now)) await Future<void>.delayed(slot.difference(now));
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

  /// Runs [action] and answers the first response whose URL contains [match]: the XHR's JSON
  /// rather than the DOM it becomes. Armed before [action]; `null` when nothing matched
  /// before [timeout] or the body was evicted.
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
        case 'Network.responseReceived' when id == null:
          final res = event.params['response'] as Map<String, Object?>?;
          if (res == null || !'${res['url']}'.contains(match)) return;
          id = event.params['requestId'] as String?;
          answered = res;
        case 'Network.loadingFinished' || 'Network.loadingFailed':
          if (event.params['requestId'] == id && !finished.isCompleted) finished.complete();
      }
    });
    try {
      await action();
      await finished.future.timeout(timeout ?? _client._timeout, onTimeout: () {});
      final res = answered;
      if (res == null) return null;
      try {
        final body = await _call('Network.getResponseBody', {'requestId': id});
        final raw = body['body'] as String? ?? '';
        return Response.bytes(
          body['base64Encoded'] == true ? base64.decode(raw) : utf8.encode(raw),
          (res['status'] as num?)?.toInt() ?? 200,
          headers: _wire(res['headers']),
          url: Uri.tryParse('${res['url']}'),
        );
      } catch (_) {
        return null;
      }
    } finally {
      await watch?.cancel();
    }
  }

  /// Puts [files] into the first file input [selector] matches. Answers `false` when nothing
  /// matched.
  Future<bool> upload(String selector, List<Path> files) async {
    final node = await _node(selector);
    if (node == null) return false;
    await _call('DOM.setFileInputFiles', {
      'nodeId': node,
      'files': [for (final file in files) file.absolute.path],
    });
    return true;
  }

  /// Runs [action] and waits for the navigation it causes; answers whether the page settled
  /// before [timeout].
  ///
  /// Armed before [action], which is why it takes one: a fast page can finish loading before
  /// a wait armed after the click would start.
  ///
  /// ```dart
  /// await page.waitForNavigation(() => page.click('a.next'));
  /// ```
  Future<bool> waitForNavigation(FutureOr<void> Function() action, {ChromeWait? until, Duration? timeout}) async {
    _arm((until ?? _client._wait)._lifecycle);
    try {
      await action();
    } catch (_) {
      _disarm();
      rethrow;
    }
    return _settle(timeout);
  }

  /// Goes back one history entry and waits; `false` when there is none.
  Future<bool> back({ChromeWait? until, Duration? timeout}) => _history(-1, until, timeout);

  /// Goes forward one history entry and waits; `false` when there is none.
  Future<bool> forward({ChromeWait? until, Duration? timeout}) => _history(1, until, timeout);

  Future<bool> _history(int step, ChromeWait? until, Duration? timeout) async {
    final history = await _call('Page.getNavigationHistory');
    final index = (history['currentIndex'] as int? ?? 0) + step;
    final entries = (history['entries'] as List? ?? const []).cast<Map<String, Object?>>();
    if (index < 0 || index >= entries.length) return false;
    final was = _url;
    _arm((until ?? _client._wait)._lifecycle);
    await _call('Page.navigateToHistoryEntry', {'entryId': entries[index]['id']});
    // A bfcache restore fires no `load`; the URL moving is the other proof.
    var decided = false;
    final moved = await Future.any([_settle(timeout), _left(was, timeout, () => decided)]);
    decided = true;
    // Ends whichever wait lost.
    _complete();
    _disarm();
    return moved;
  }

  Future<bool> _left(Uri was, Duration? timeout, bool Function() decided) async {
    final deadline = DateTime.now().add(timeout ?? _client._timeout);
    while (!isClosed && !decided() && DateTime.now().isBefore(deadline)) {
      if (_url != was) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return _url != was;
  }

  /// The whole browser's cookies, after putting [restore] in first.
  ///
  /// `Http.scope(jar: await page.cookies(), …)` carries a browser login to plain sockets; a
  /// saved jar passed back restores it. A cookie with no domain is set for the current page.
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
    final jar = <Cookie>[];
    for (final c in (all['cookies'] as List? ?? const []).cast<Map<String, Object?>>()) {
      // dart:io refuses values Chrome keeps (`x,y`); one such cookie must not cost the jar.
      try {
        jar.add(
          Cookie(c['name'] as String? ?? '', c['value'] as String? ?? '')
            ..domain = c['domain'] as String?
            ..path = c['path'] as String?
            ..secure = c['secure'] == true
            ..httpOnly = c['httpOnly'] == true
            ..expires = switch (c['expires']) {
              final num at when at > 0 => DateTime.fromMillisecondsSinceEpoch((at * 1000).round()),
              _ => null,
            },
        );
      } on FormatException catch (_) {}
    }
    return jar;
  }

  /// The page as a PDF. Headless only: a headful Chrome throws `Printing is not available`.
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

  /// Handles the page's dialogs; answers a function that unregisters [handler].
  ///
  /// A handler that neither accepts nor dismisses (or throws) gets the default: dismissed,
  /// except `beforeunload`, which is accepted.
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

  /// Always answers: Chrome holds the renderer on an open dialog, which would take a pooled
  /// tab with it. Dismissing `beforeunload` would cancel the navigation, so it is accepted.
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

  /// The iframe whose URL or `name` contains [match], as a [ChromePage] every method works
  /// in; `null` when none does. Closing the view closes nothing.
  ///
  /// ```dart
  /// final form = await page.frame('checkout');
  /// await form!.fill('#card', '4242…');
  /// ```
  Future<ChromePage?> frame(String match) async {
    final owner = _owner;
    await (owner._frames ??= owner._watchFrames());
    final tree = await owner._call('Page.getFrameTree');
    // A cross-origin frame is not in the tree.
    final found =
        _descend((tree['frameTree'] as Map<String, Object?>?) ?? const {}, match, root: true) ??
        await owner._remoteMatching(match);
    if (found == null) return null;
    final (id, at) = found;
    final page = switch (owner._remotes[id]) {
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

  /// The out-of-process frame whose URL or `<iframe name>` contains [match].
  Future<(String, String)?> _remoteMatching(String match) async {
    for (final MapEntry(:key, :value) in _remotes.entries.toList()) {
      // Attached before its first request, so the URL it attached with is blank.
      var url = value.url;
      try {
        final info = await _client._call('Target.getTargetInfo', {'targetId': key});
        url = '${(info['targetInfo'] as Map<String, Object?>?)?['url'] ?? url}';
        _remotes[key] = (session: value.session, url: url);
      } catch (_) {}
      if (url.contains(match)) return (key, url);
      try {
        final holder = await _call('DOM.getFrameOwner', {'frameId': key});
        final node = await _call('DOM.describeNode', {'backendNodeId': holder['backendNodeId']});
        final attributes = ((node['node'] as Map<String, Object?>?)?['attributes'] as List?) ?? const [];
        for (var i = 0; i + 1 < attributes.length; i += 2) {
          final name = '${attributes[i + 1]}';
          if (attributes[i] == 'name' && name.isNotEmpty && name.contains(match)) return (key, url);
        }
      } catch (_) {}
    }
    return null;
  }

  /// The first frame under [node] (not the [root] itself) whose URL or name contains [match],
  /// as id and URL.
  static (String, String)? _descend(Map<String, Object?> node, String match, {bool root = false}) {
    if (root ? null : node['frame'] case final Map<String, Object?> frame) {
      final url = '${frame['url'] ?? ''}';
      final name = '${frame['name'] ?? ''}';
      if (url.contains(match) || (name.isNotEmpty && name.contains(match))) return (frame['id'] as String? ?? '', url);
    }
    for (final child in (node['childFrames'] as List? ?? const []).cast<Map<String, Object?>>()) {
      if (_descend(child, match) case final hit?) return hit;
    }
    return null;
  }

  /// Closes the tab; safe twice. On a [frame] view it closes nothing.
  Future<void> close() async {
    if (!_alive) return;
    _alive = false;
    if (_parent != null) return _events?.cancel().then((_) {});
    _client._pages.remove(this);
    _client._free.remove(this);
    await _events?.cancel();
    for (final child in _children.values) {
      await child.cancel();
    }
    _children.clear();
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

  /// Contexts for in-process frames; out-of-process ones attach from the tab's start.
  Future<void> _watchFrames() => _call('Runtime.enable');

  Future<Map<String, Object?>> _call(String method, [Map<String, Object?>? params, Duration? timeout]) {
    if (isClosed) return Future.error(ClientException('The page is closed', _url));
    return _client._call(method, params, _tab, timeout);
  }

  /// The JavaScript for the first match of [selector].
  static String _q(String selector) => 'document.querySelector(${jsonEncode(selector)})';

  /// Whether [e] is an evaluation cut short by a navigation, worth retrying once it settles.
  static bool _navigatedAway(Object e) {
    final msg = '$e';
    // Not this package's own "closed": a dead page or client never comes back.
    if (e is ClientException && (msg.contains('is closed') || msg.contains('disconnected'))) return false;
    return msg.contains('navigated') || msg.contains('closed') || msg.contains('Execution context was destroyed');
  }

  static (num, num) _centre(List<num> quad) => ((quad[0] + quad[4]) / 2, (quad[1] + quad[5]) / 2);

  Future<void> _mouse(String type, (num, num) at, {bool press = false}) => _call('Input.dispatchMouseEvent', {
    'type': type,
    'x': at.$1,
    'y': at.$2,
    if (press) ...{'button': 'left', 'buttons': 1, 'clickCount': 1},
  });

  /// The border quad of the first element [selector] matches, scrolled into view, or `null`.
  Future<List<num>?> _box(String selector) async {
    final node = await _node(selector);
    if (node == null) return null;
    try {
      await _call('DOM.scrollIntoViewIfNeeded', {'nodeId': node});
      final box = await _call('DOM.getBoxModel', {'nodeId': node});
      final quad = ((box['model'] as Map<String, Object?>?)?['border'] as List?)?.cast<num>();
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
        // An in-process frame's nodes hang off its `<iframe>`'s content document.
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
      final params = event.params;
      switch (event.method) {
        case 'Runtime.executionContextCreated':
          final context = params['context'] as Map<String, Object?>?;
          if ((context?['auxData'] as Map<String, Object?>?)?['frameId'] case final String frame) {
            _owner._contexts[frame] = (context!['id'] as num).toInt();
          }
        case 'Runtime.executionContextsCleared':
          _owner._contexts.clear();
        case 'Network.responseReceived':
          if (params['type'] != 'Document') return;
          // A challenge renders inside an iframe; only the main frame is this page.
          if (_frame.isNotEmpty && params['frameId'] != _frame) return;
          final answer = _answer = params['response'] as Map<String, Object?>?;
          // A 204 or a download leaves the document where it was.
          if (answer?['status'] case 204 || 205) return;
          if (_attachment(answer)) return;
          _document = answer;
        case 'Page.frameNavigated':
          final frame = params['frame'] as Map<String, Object?>?;
          if (frame == null) return;
          if ((_owner._remotes[frame['id']], frame['url']) case (final remote?, final String url)) {
            _owner._remotes[frame['id'] as String] = (session: remote.session, url: url);
          }
          if (_frame.isNotEmpty && frame['id'] != _frame) return;
          if (frame['url'] case final String moved) _url = Uri.tryParse(moved) ?? _url;
          if (frame['loaderId'] case final String loader) _loader = loader;
        case 'Page.navigatedWithinDocument':
          // pushState and `#hash` fire no lifecycle event; the move is the navigation.
          if (_frame.isNotEmpty && params['frameId'] != _frame) return;
          if (params['url'] case final String moved) _url = Uri.tryParse(moved) ?? _url;
          if (_expect == null) _complete();
        case 'Target.attachedToTarget' || 'Target.detachedFromTarget' || 'Fetch.requestPaused' || 'Fetch.authRequired'
            when _parent == null:
          _route(event, _tab);
        case 'Page.javascriptDialogOpening' when _parent == null:
          unawaited(_dialog(params));
        case 'Page.lifecycleEvent':
          if (params['name'] != _want) return;
          // Not a subframe's event, nor a late one from the previous document.
          if (_frame.isNotEmpty && params['frameId'] != _frame) return;
          final loader = params['loaderId'];
          if (_expect != null ? loader != _expect : loader != null && loader == _stale) return;
          _complete();
      }
    });
  }

  /// What the tab answers for itself and for each out-of-process frame, on [on]'s session.
  void _route(_Cdp event, _Tab on) {
    final params = event.params;
    switch (event.method) {
      case 'Target.attachedToTarget':
        unawaited(_adopt(params));
      case 'Target.detachedFromTarget':
        final session = params['sessionId'];
        _remotes.removeWhere((_, remote) => remote.session == session);
        unawaited(_children.remove(session)?.cancel());
        unawaited(_client._sessions.remove(session)?.close());
      case 'Fetch.requestPaused':
        // With an authenticating proxy everything pauses, so refusal is by kind. `headers`
        // replaces the request's, so the grant is merged into the ones it had.
        final kind = '${params['resourceType']}';
        final refused = (_blocked ?? const <Resource>{}).any((r) => r._types.contains(kind));
        final paused = params['request'] as Map<String, Object?>?;
        final grant = _grant;
        final own = !refused && grant != null && _origin(Uri.tryParse('${paused?['url']}')) == grant.origin;
        unawaited(
          _client
              ._call(refused ? 'Fetch.failRequest' : 'Fetch.continueRequest', {
                'requestId': params['requestId'],
                if (refused) 'errorReason': 'BlockedByClient',
                if (own) 'headers': _granted(paused?['headers'], grant.headers),
              }, on)
              .catchError((Object _) => const <String, Object?>{}),
        );
      case 'Fetch.authRequired':
        // The proxy's password is for the proxy: a site's 401 is cancelled, which shows its page
        // as Chrome would (`Default` fails the navigation instead).
        final proxied = (params['authChallenge'] as Map<String, Object?>?)?['source'] == 'Proxy';
        unawaited(
          _client
              ._call('Fetch.continueWithAuth', {
                'requestId': params['requestId'],
                'authChallengeResponse': switch (_client._login) {
                  (final user, final password) when proxied => {
                    'response': 'ProvideCredentials',
                    'username': user,
                    'password': password,
                  },
                  _ => {'response': 'CancelAuth'},
                },
              }, on)
              .catchError((Object _) => const <String, Object?>{}),
        );
    }
  }

  /// Takes on a target Chrome holds at its start: an out-of-process frame gets the tab's
  /// interception before its first request; anything else is just let go.
  Future<void> _adopt(Map<String, Object?> params) async {
    final info = params['targetInfo'] as Map<String, Object?>? ?? const {};
    final session = params['sessionId'];
    if (session is! String) return;
    final child = _Tab('${info['targetId']}', session);
    try {
      if (info['type'] == 'iframe' && _alive) {
        final events = _client._sessions[session] ??= StreamController<_Cdp>.broadcast();
        _remotes[child.target] = (session: session, url: '${info['url'] ?? ''}');
        _children[session] = events.stream.listen((event) => _route(event, child));
        if (_fetching != null) await _fetch(child);
        await _client._call('Target.setAutoAttach', _attach, child);
      }
    } catch (_) {
    } finally {
      await _client
          ._call('Runtime.runIfWaitingForDebugger', null, child)
          .catchError((Object _) => const <String, Object?>{});
    }
  }

  /// Frames attach paused, so [block] and the proxy's login apply to their first request.
  static const _attach = {'autoAttach': true, 'waitForDebuggerOnStart': true, 'flatten': true};

  void _complete() {
    if (_waiter case final waiter? when !waiter.isCompleted) waiter.complete();
  }

  /// Arms the lifecycle wait *before* navigating, so a page that loads before the call
  /// returns is not missed.
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

  /// Waits for the armed event, quietly: a page that never fires `load` still has a DOM.
  /// Answers whether it arrived in time.
  Future<bool> _settle([Duration? timeout]) async {
    final waiter = _waiter;
    if (waiter == null) return true;
    var fired = true;
    try {
      await waiter.future.timeout(timeout ?? _client._timeout, onTimeout: () => fired = false);
    } finally {
      if (identical(_waiter, waiter)) _disarm();
    }
    return fired;
  }

  static bool _attachment(Map<String, Object?>? res) =>
      '${_wire(res?['headers'])['content-disposition']}'.toLowerCase().startsWith('attachment');

  static bool _challenging(int? status) => status == 403 || status == 503 || status == 429;

  static const _markers = [
    'cf-browser-verification',
    'challenge-form',
    '__cf_chl',
    'cf-turnstile',
    'Just a moment',
    'Checking your browser',
  ];

  bool _interstitial(Response res) {
    if (!_challenging(res.statusCode)) return false;
    final body = res.text;
    return body.length < 80000 && _markers.any(body.contains);
  }
}

/// A dialog the page opened: `alert`, `confirm`, `prompt` or `beforeunload`. See
/// [ChromePage.onDialog]. Answering twice is answering once.
///
/// {@category Networking}
final class Dialog {
  /// `alert`, `confirm`, `prompt` or `beforeunload`.
  final String type;

  final String message;

  /// What a `prompt` was pre-filled with; empty otherwise.
  final String defaultValue;

  final ChromePage _page;
  var _answered = false;

  Dialog._(this._page, this.type, this.message, this.defaultValue);

  /// OK, with [text] as a `prompt`'s answer.
  Future<void> accept([String? text]) => _answer(true, text);

  /// Cancel.
  Future<void> dismiss() => _answer(false, null);

  Future<void> _answer(bool accept, String? text) async {
    if (_answered) return;
    _answered = true;
    try {
      await _page._call('Page.handleJavaScriptDialog', {'accept': accept, 'promptText': ?text});
    } catch (_) {}
  }
}

final class _Tab {
  final String target;
  final String session;

  const _Tab(this.target, this.session);
}

/// One protocol event.
final class _Cdp {
  final String method;
  final Map<String, Object?> params;

  const _Cdp(this.method, this.params);
}

/// DevTools headers as [Headers].
Headers _wire(Object? raw) => Headers({
  if (raw case final Map<String, Object?> sent)
    for (final MapEntry(:key, :value) in sent.entries) key: '$value',
});

/// A paused request's headers, plus [grant] where it named none.
List<Map<String, String>> _granted(Object? had, Map<String, String> grant) {
  final merged = _wire(had);
  grant.forEach((name, value) => merged.putIfAbsent(name, () => value));
  return [
    for (final MapEntry(:key, :value) in merged.entries) {'name': key, 'value': value},
  ];
}
