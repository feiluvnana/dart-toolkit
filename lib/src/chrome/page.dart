part of '../../chrome.dart';

/// One tab, open for as long as the work takes: what [Chrome.open] hands over, and what a render
/// drives underneath. It acts and waits; reading is the DOM's (`await page.html`, then `$`,
/// `text`, `attr`, `links`).
///
/// ```dart
/// final page = await chrome.open(login);
/// await page.fill('#user', 'me');
/// await page.expectNavigation(() => page.click('button[type=submit]'));
/// await page.wait('.dashboard');
/// final html = await page.html;
/// final file = await page.expectDownload(() => page.click('.statement'), into: 'out');
/// await page.close();
/// ```
///
/// Every wait throws a [TimeoutException] on time, the navigation of [goto] included; a selector
/// that matches nothing is a [MissingException] naming it and the page; a browser that went away
/// is a [ChromeException] that says so.
///
/// {@category Networking}
final class Page {
  final Chrome _client;
  final _Tab _tab;

  /// The tab's page when this is a [frame] view.
  final Page? _parent;

  /// Execution context per frame id; filled by the tab's page, read by its frame views.
  final Map<String, int> _contexts = {};

  StreamSubscription<_Cdp>? _events;
  FutureOr<void> Function(Dialog dialog)? _onDialog;

  /// Chrome starts ~10 downloads a second per page and silently drops the rest, so downloads on
  /// one page take turns: each action runs [_downloadGap] after the download before it began (or
  /// its wait ended), however long the actions take.
  Future<void> _downloadTurn = Future.value();
  static const _downloadGap = Duration(milliseconds: 120);
  Set<Resource>? _blocked;

  /// The site of the page's document, for [Resource.offsite].
  String? _site;

  /// The render's credentials and the one origin they may go to.
  ({String origin, Map<String, String> headers})? _grant;

  /// The user agent a render asked for, so an unchanged one costs no round trip.
  String? _agentSet;

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

  /// The [frame] view of each frame id, so asking again adds no listener.
  final Map<String, Page> _views = {};

  /// The tab's watch on each out-of-process frame's session, by session.
  final Map<String, StreamSubscription<_Cdp>> _children = {};

  /// An out-of-process frame, driven through its own session.
  final bool _remote;
  String _frame = '';
  Uri _url = Uri.parse('about:blank');
  bool _alive = true;

  Page._(this._client, this._tab, {Page? parent, bool remote = false}) : _parent = parent, _remote = remote;

  Page get _owner => _parent ?? this;

  /// The context an in-process frame evaluates in; `null` uses the session's default.
  int? get _context => _parent == null || _remote ? null : _owner._contexts[_frame];

  /// The URL this tab is on, after every redirect and navigation.
  Uri get url => _url;

  /// Whether this tab or its client has been closed.
  bool get isClosed => !_alive || !_owner._alive || _client.isClosed;

  /// The status of the last document loaded, or `null` before the first.
  int? get statusCode => (_document?['status'] as num?)?.toInt();

  /// How long each wait takes by default: the client's render timeout.
  Duration get _timeout => _client._render._timeout;

  /// Navigates to [url] as [render] says (over the client's), and answers the page as it then
  /// stands. Chrome refusing the navigation (an unresolved name, a refused connection) is a
  /// [ClientException]; a page that has not loaded in time a [TimeoutException]; an interstitial
  /// that did not clear in `render.challenge` is the answer, with its status.
  Future<Response> goto(Uri url, {Render? render}) async {
    render?._check();
    final how = _client._render._under(render);
    if (how.block case final kinds?) await block(kinds);
    final res = await _goto(url, how);
    if (how.waitFor case final selector?) await wait(selector, timeout: how._timeout);
    if (how.script case final source?) await _value(source, timeout: how._timeout);
    return how.waitFor != null || how.script != null ? _response() : res;
  }

  /// Navigates and settles as [how] says, giving an interstitial `how.challenge` to clear, a time
  /// no request's timeout counts.
  Future<Response> _goto(Uri url, Render how, {Request? request}) async {
    _arm(how._wait._lifecycle);
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
    if (!await _settle(how._timeout)) throw _unsettled('Navigation to $url', how._timeout);

    final patience = how._challenge;
    var res = await _response(request);
    if (patience <= Duration.zero || !_interstitial(res)) return res;
    return HttpBridge.untimed(() async {
      final deadline = Clock.current.elapsed + patience;
      while (_interstitial(res) && Clock.current.elapsed < deadline) {
        await const Duration(milliseconds: 500).delay();
        Cancel.check();
        if (isClosed) break;
        try {
          res = await _response(request);
          // The markers also go between documents and as the real page starts streaming: it
          // has cleared only if it still has once loaded.
          if (!_interstitial(res)) {
            await _loaded(how);
            res = await _response(request);
          }
        } on ChromeException catch (e) {
          if (!_navigatedAway(e)) rethrow;
          await _settle(how._timeout);
        }
      }
      return res;
    });
  }

  /// Waits until the current document is as far as [how] asks: `interactive` for [Wait.dom],
  /// `complete` otherwise.
  Future<void> _loaded(Render how) async {
    final done = await _value('''
new Promise((resolve) => {
  const ready = () => document.readyState == 'complete' || ${how._wait == Wait.dom} && document.readyState == 'interactive';
  if (ready()) return resolve(true);
  document.addEventListener('readystatechange', () => { if (ready()) resolve(true); });
  setTimeout(() => resolve(false), ${how._timeout.inMilliseconds});
})''', timeout: how._timeout + const Duration(seconds: 5));
    if (done != true) throw _unsettled('Loading $url', how._timeout);
  }

  /// The bodiless answer of an aborted navigation, if it was a 204/205, an error status or a
  /// download; the event may trail the command's reply.
  Future<Response?> _empty(Uri url, Request? request) async {
    for (var i = 0; i < 25 && _answer == null; i++) {
      await const Duration(milliseconds: 20).delay();
      Cancel.check();
    }
    final status = (_answer?['status'] as num?)?.toInt();
    if (status == null || (status != 204 && status != 205 && status < 400 && !_attachment(_answer))) return null;
    return Response.bytes(Uint8List(0), status, headers: _wire(_answer?['headers']), request: request, url: url);
  }

  /// The DOM as it stands now, under the status and headers the document was served with.
  Future<Response> _response([Request? request]) async {
    final mime = _document?['mimeType'] as String? ?? 'text/html';
    final body = await _value(
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

  /// The page as it stands now, parsed: then the DOM's readings.
  Future<Html> get html async => (await _response()).html;

  /// Waits until [selector] matches: a mutation observer, not a poll. A [TimeoutException] when
  /// it has not by [timeout] (the client's render timeout by default).
  Future<void> wait(String selector, {Duration? timeout}) => _watch(selector, timeout: timeout, gone: false);

  /// Waits until [selector] matches nothing (a spinner gone, a challenge cleared); a
  /// [TimeoutException] when it still does by [timeout].
  Future<void> waitGone(String selector, {Duration? timeout}) => _watch(selector, timeout: timeout, gone: true);

  Future<void> _watch(String selector, {required bool gone, Duration? timeout}) async {
    final hit = gone ? '!${_q(selector)}' : '!!${_q(selector)}';
    final limit = timeout ?? _timeout;
    final deadline = Clock.current.elapsed + limit;
    while (true) {
      final remaining = deadline - Clock.current.elapsed;
      if (remaining <= Duration.zero) throw TimeoutBridge('${gone ? 'waitGone' : 'wait'} "$selector" on $url', limit);
      try {
        final found = await _value('''
new Promise((resolve) => {
  const hit = () => $hit;
  if (hit()) return resolve(true);
  const observer = new MutationObserver(() => { if (hit()) { observer.disconnect(); resolve(true); } });
  observer.observe(document, {childList: true, subtree: true, attributes: true});
  setTimeout(() => { observer.disconnect(); resolve(false); }, ${remaining.inMilliseconds});
})''', timeout: remaining + const Duration(seconds: 5));
        if (found == true) return;
      } on ChromeException catch (e) {
        if (isClosed || !_navigatedAway(e)) rethrow;
        await _settle(remaining);
      }
    }
  }

  /// Clicks the first element [selector] matches with real mouse events at its centre, scrolled
  /// into view; through the DOM when it has no box. A [MissingException] when nothing matches.
  Future<void> click(String selector) async {
    if (await _box(selector) case final quad?) {
      final at = _centre(quad);
      await _mouse('mouseMoved', at);
      await _mouse('mousePressed', at, press: true);
      await _mouse('mouseReleased', at, press: true);
      return;
    }
    final clicked = await _value('(() => { const el = ${_q(selector)}; if (el) el.click(); return !!el; })()');
    if (clicked != true) throw _missing(selector);
  }

  /// Focuses the first element [selector] matches and types [value] in as text, firing `input`
  /// and then `change`, as a person leaving the field does; `keydown` listeners may not see it
  /// (use [press]). A [MissingException] when nothing matches.
  Future<void> fill(String selector, String value) async {
    final node = await _node(selector) ?? (throw _missing(selector));
    await _call('DOM.focus', {'nodeId': node});
    await _value("(() => { const el = ${_q(selector)}; if (el && 'value' in el) el.value = ''; })()");
    await _call('Input.insertText', {'text': value});
    await _value(
      "(() => { const el = ${_q(selector)}; if (el) el.dispatchEvent(new Event('change', {bubbles: true})); })()",
    );
  }

  /// Submits the form [selector] matches, or the form around the match, as a script's
  /// `form.submit()` does (through `HTMLFormElement.prototype.submit`, so click handlers where ad
  /// popups live never run), and waits for the navigation it causes as [expectNavigation] does.
  /// A [MissingException] when nothing matches or no form holds it.
  Future<void> submit(String selector) => expectNavigation(() async {
    final sent = await _value('''(() => {
  const el = ${_q(selector)};
  const form = el && (el.form ?? el.closest('form'));
  if (!form) return false;
  HTMLFormElement.prototype.submit.call(form);
  return true;
})()''');
    if (sent != true) throw _missing(selector);
  });

  MissingException _missing(String selector) => MissingException('match for "$selector"', where: '$url');

  /// Presses a key on whatever has focus: `Enter`, `Tab`, `Escape`, `Backspace`, an arrow, or a
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
      '' => throw ArgumentError.value(key, 'key', 'Invalid key, expected a key name or one character'),
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

  /// Scrolls to the bottom [times] times, half a second apart, stopping early when the height
  /// stops growing; answers the final height.
  Future<num> scroll({int times = 3}) {
    if (times < 1) throw ArgumentError.value(times, 'times', 'Invalid times, expected at least 1');
    return _scrolling((i, _) => i < times);
  }

  /// Scrolls to the bottom until the height stops growing (a feed that loads as it is read), for
  /// at most the render timeout; answers the final height.
  Future<num> scrollToEnd() {
    final deadline = Clock.current.elapsed + _timeout;
    return _scrolling((_, _) => Clock.current.elapsed < deadline);
  }

  Future<num> _scrolling(bool Function(int round, num height) again) async {
    num height = 0;
    for (var i = 0; again(i, height); i++) {
      final grown = await _value('''(async () => {
  const before = document.body ? document.body.scrollHeight : 0;
  window.scrollTo(0, before);
  await new Promise((r) => setTimeout(r, 500));
  return document.body ? document.body.scrollHeight : 0;
})()''', timeout: const Duration(seconds: 10));
      final now = grown is num ? grown : 0;
      if (now == height) break;
      height = now;
    }
    return height;
  }

  /// Runs [expression] in the page and answers its value as [T], a promise's once it settles:
  /// `await page.eval<String>('document.title')`, or a [Doc] to read JSON in
  /// (`(await page.eval<Doc>('fetch("/api").then(r => r.json())'))['items'].list`). A value
  /// that is not a [T] is read as `Doc.to` reads it; a script that throws (or rejects) is a
  /// [ChromeException].
  Future<T> eval<T>(String expression, {Duration? timeout}) async {
    final doc = Doc(await _value(expression, timeout: timeout));
    // `eval<Doc>` keeps the document; any other type is read out of it.
    return <T>[] is List<Doc> ? doc as T : doc.to<T>();
  }

  /// [eval]'s value as it came: what the page's own steps read.
  Future<Object?> _value(String expression, {Duration? timeout}) async {
    final result = await _call('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
      'contextId': ?_context,
    }, timeout);
    if (result['exceptionDetails'] case final Map<String, Object?> thrown) {
      // `text` is only "Uncaught"; what was thrown, and where, is in its description.
      final what = (thrown['exception'] as Map?)?['description'] ?? thrown['text'] ?? thrown;
      throw ChromeException('Page script failed on $url: $what', method: 'Runtime.evaluate');
    }
    return (result['result'] as Map<String, Object?>?)?['value'];
  }

  /// A PNG of the window, or of the element [of] matches; a [MissingException] when [of] matches
  /// nothing with a box.
  Future<Uint8List> screenshot({String? of}) async {
    Map<String, Object?>? clip;
    if (of != null) {
      final quad = await _box(of) ?? (throw MissingException('match for "$of" with a box', where: '$url'));
      final view = (await _call('Page.getLayoutMetrics'))['visualViewport'] as Map<String, Object?>? ?? const {};
      clip = {
        'x': quad[0] + (view['pageX'] as num? ?? 0),
        'y': quad[1] + (view['pageY'] as num? ?? 0),
        'width': quad[2] - quad[0],
        'height': quad[5] - quad[1],
      };
    }
    return _shot(clip);
  }

  /// A PNG of the whole document, past the window.
  Future<Uint8List> screenshotPage() async {
    final metrics = await _call('Page.getLayoutMetrics');
    final size = (metrics['cssContentSize'] ?? metrics['contentSize']) as Map<String, Object?>?;
    return _shot({'x': 0, 'y': 0, 'width': size?['width'] ?? 0, 'height': size?['height'] ?? 0});
  }

  Future<Uint8List> _shot(Map<String, Object?>? clip) async {
    final shot = await _call('Page.captureScreenshot', {
      'format': 'png',
      if (clip != null) ...{
        'captureBeyondViewport': true,
        'clip': {...clip, 'scale': 1},
      },
    });
    return base64.decode(shot['data'] as String? ?? '');
  }

  /// Chooses the option of the `<select>` [selector] whose value, else text, is [value], and
  /// fires `input` and `change`. A [MissingException] naming what is missing: the select, or the
  /// option.
  Future<void> select(String selector, String value) async {
    final chosen = await _value('''(() => {
  const el = ${_q(selector)};
  if (!el || !el.options) return 'select';
  const want = ${jsonEncode(value)};
  const option = [...el.options].find((o) => o.value === want) ??
                 [...el.options].find((o) => o.textContent.trim() === want);
  if (!option) return 'option';
  el.value = option.value;
  el.dispatchEvent(new Event('input', {bubbles: true}));
  el.dispatchEvent(new Event('change', {bubbles: true}));
  return 'ok';
})()''');
    if (chosen == 'select') throw _missing(selector);
    if (chosen == 'option') throw MissingException('option "$value" in "$selector"', where: '$url');
  }

  /// Moves the mouse over the first element [selector] matches. A [MissingException] when nothing
  /// matches or it has no box.
  Future<void> hover(String selector) async =>
      _mouse('mouseMoved', _centre(await _box(selector) ?? (throw _missing(selector))));

  /// Refuses to load [kinds] in this tab from now on; `block({})` allows everything again.
  /// `page.block(Resource.heavy)` reads the same text in a fraction of the time.
  Future<void> block(Set<Resource> kinds) async {
    _blocked = kinds;
    await _intercept();
  }

  /// Tells Chrome which requests to pause: all of them for an authenticated proxy
  /// (`--proxy-server` cannot carry a password), a render with a credential to add to its own
  /// origin, or [Resource.offsite]; otherwise only blocked kinds.
  Future<void> _intercept() async {
    final authenticating = _client._logins.isNotEmpty;
    final kinds = _blocked ?? const <Resource>{};
    final everything = authenticating || _grant != null || kinds.contains(Resource.offsite);
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
      await _fetch(_Tab(remote.key, remote.value.session)).catchError((Object _) {}); // a frame that closed meanwhile
    }
  }

  /// Applies [_fetching] to [tab]'s session.
  Future<void> _fetch(_Tab tab) => _client._call(_fetching == null ? 'Fetch.disable' : 'Fetch.enable', _fetching, tab);

  /// Sets the cookies in [header] for [url] alone, never as a header every request carries;
  /// answers the names it set that the browser did not hold already.
  Future<List<String>> _plant(String header, Uri url) async {
    final pairs = [
      for (final pair in header.split(';'))
        if (pair.indexOf('=') case final eq when eq > 0) (pair.substring(0, eq).trim(), pair.substring(eq + 1).trim()),
    ];
    if (pairs.isEmpty) return const [];
    final had = await _call('Network.getCookies', {
      'urls': ['$url'],
    });
    final held = {for (final c in (had['cookies'] as List? ?? const []).cast<Map<String, Object?>>()) c['name']};
    await _call('Network.setCookies', {
      'cookies': [
        for (final (name, value) in pairs) {'name': name, 'value': value, 'url': '${url.removeFragment()}'},
      ],
    });
    return [
      for (final (name, _) in pairs)
        if (!held.contains(name)) name,
    ];
  }

  /// Removes the cookies [names] [_plant] set for [url].
  Future<void> _unplant(List<String> names, Uri url) async {
    for (final name in names) {
      await _call('Network.deleteCookies', {'name': name, 'url': '${url.removeFragment()}'}).catchError(
        (Object _) => const <String, Object?>{}, // best-effort: the tab may be gone
      );
    }
  }

  /// Sets this tab's user agent to [agent] (`null`: the client's own) when it is another.
  Future<void> _agent(String? agent) async {
    if (agent == _agentSet) return;
    _agentSet = agent;
    await _client._override(_tab, agent);
  }

  /// Runs [action] and follows the download it starts, as a task: `Running` as Chrome reports
  /// bytes, then the file in [into] under the site's name. A file of that name already there
  /// follows [conflict] (by default it is left, `Done(fresh: false)`).
  ///
  /// Armed before [action]: a small file can be on disk before the next line runs. Chrome
  /// writes into a client-owned folder and only a finished file is moved, so nothing
  /// half-written reaches [into]. [timeout] is how long the download may go *quiet*, not how long
  /// it may take: one that never starts or stalls is a [TimeoutException], one Chrome cancels a
  /// [ChromeException], its partial erased either way. Several on one page take turns.
  ///
  /// ```dart
  /// final file = await page.expectDownload(() => page.click('.download'), into: 'books');
  /// ```
  Task<Path> expectDownload(
    FutureOr<void> Function() action, {
    required String into,
    Conflict conflict = Conflict.skip,
    Duration? timeout,
  }) => TaskInternals.start(url, HttpInternals.label(url), (work) => _download(action, into, conflict, timeout, work));

  Future<Path> _download(
    FutureOr<void> Function() action,
    String into,
    Conflict conflict,
    Duration? timeout,
    Work work,
  ) async {
    final landing = (await _client._downloads()).path;
    final idle = timeout ?? _timeout;
    String? id;
    String? suggested;
    final finished = Completer<Object?>();
    // `null` when it completed, else why it did not.
    void done(Object? why) {
      if (!finished.isCompleted) finished.complete(why);
    }

    // Taken before waiting, so concurrent waits queue in call order.
    final before = _owner._downloadTurn;
    final turn = Completer<void>();
    _owner._downloadTurn = turn.future;
    void pass() => Timer(_downloadGap, () => turn.isCompleted ? null : turn.complete());

    // Every event about the download restarts the silence timer.
    Timer? quiet;
    void stirred() {
      quiet?.cancel();
      quiet = Timer(idle, () => done(TimeoutBridge('A download on $url', idle)));
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
          pass();
        case 'Browser.downloadProgress' when event.params['guid'] == id:
          stirred();
          final total = (event.params['totalBytes'] as num?)?.toInt();
          work.amount(
            (event.params['receivedBytes'] as num?)?.toInt() ?? 0,
            total: total == null || total <= 0 ? null : total,
          );
          switch (event.params['state']) {
            case 'completed':
              done(null);
            case 'canceled':
              done(ChromeException('Chrome cancelled the download of ${suggested ?? 'a file'}', uri: url));
          }
      }
    });
    final cancelled = Cancel.token?.onCancel(() => done(CancelledException.of(Cancel.token!)));
    try {
      await before;
      stirred();
      try {
        await action();
      } catch (_) {
        // A download that began is what the action was for: a `goto` to a file without a
        // disposition fails as an aborted navigation, and the download's event trails it.
        for (var i = 0; i < 25 && id == null; i++) {
          await const Duration(milliseconds: 20).delay();
        }
        if (id == null) rethrow;
      }
      if (await finished.future case final why?) {
        if (id case final guid?) await _client._abandon(guid, landing);
        throw why;
      }
      final from = _join(landing, id!);
      await Directory(into).create(recursive: true);
      final wanted = _join(Directory(into).absolute.path, _fileName(suggested ?? id!));
      final target = FileBridge.settle(wanted, conflict, verb: 'download', subject: '$url', source: DateTime.now());
      if (target == null) {
        await File(from).delete();
        TaskInternals.stale(work);
        return Path(wanted);
      }
      try {
        await _place(from, target);
      } finally {
        FileBridge.release(target);
      }
      return Path(target);
    } finally {
      pass();
      quiet?.cancel();
      cancelled?.call();
      await watch.cancel();
      if (id case final guid?) _client._claimed.remove(guid);
      await _client._released();
    }
  }

  /// Runs [action] and answers the first response whose URL contains [match] (a `String` or a
  /// `RegExp`): the XHR's JSON rather than the DOM it becomes. Armed before [action]. A
  /// [TimeoutException] when nothing matched within [timeout], a [ChromeException] when Chrome no
  /// longer holds the body.
  ///
  /// ```dart
  /// final more = await page.expectResponse('/api/items', () => page.click('#more'));
  /// for (final item in more.json['items'].list) { … }
  /// ```
  Future<Response> expectResponse(Pattern match, FutureOr<void> Function() action, {Duration? timeout}) async {
    final limit = timeout ?? _timeout;
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
      await finished.future.timeout(limit, onTimeout: () {});
      final res = answered ?? (throw TimeoutBridge('A response matching "$match" on $url', limit));
      final Map<String, Object?> body;
      try {
        body = await _call('Network.getResponseBody', {'requestId': id});
      } on ChromeException catch (e) {
        if (e.detached) rethrow;
        throw ChromeException('Chrome no longer holds the body of ${res['url']}', method: e.method, uri: url);
      }
      final raw = body['body'] as String? ?? '';
      return Response.bytes(
        body['base64Encoded'] == true ? base64.decode(raw) : utf8.encode(raw),
        (res['status'] as num?)?.toInt() ?? 200,
        headers: _wire(res['headers']),
        url: Uri.tryParse('${res['url']}'),
      );
    } finally {
      await watch?.cancel();
    }
  }

  /// Puts [files] into the first file input [selector] matches; a [MissingException] when
  /// nothing matches.
  Future<void> upload(String selector, List<String> files) async {
    final node = await _node(selector) ?? (throw _missing(selector));
    await _call('DOM.setFileInputFiles', {
      'nodeId': node,
      'files': [for (final file in files) File(file).absolute.path],
    });
  }

  /// Runs [action] and waits for the navigation it causes, as far as the client's render waits;
  /// a [TimeoutException] when the page has not settled in its timeout. Armed before [action],
  /// which is why it takes one: a fast page can finish loading before a wait armed after the
  /// click would start.
  ///
  /// ```dart
  /// await page.expectNavigation(() => page.click('a.next'));
  /// ```
  Future<void> expectNavigation(FutureOr<void> Function() action) async {
    _arm(_client._render._wait._lifecycle);
    try {
      await action();
    } catch (_) {
      _disarm();
      rethrow;
    }
    if (!await _settle(_timeout)) throw _unsettled('Navigation from $url', _timeout);
  }

  TimeoutException _unsettled(String what, Duration limit) => TimeoutBridge(what, limit);

  /// Goes back one history entry and waits for it; a [MissingException] when there is none, a
  /// [TimeoutException] when it has not settled in time.
  Future<void> back() => _history(-1);

  /// Goes forward one history entry and waits, as [back] does.
  Future<void> forward() => _history(1);

  Future<void> _history(int step) async {
    final history = await _call('Page.getNavigationHistory');
    final index = (history['currentIndex'] as int? ?? 0) + step;
    final entries = (history['entries'] as List? ?? const []).cast<Map<String, Object?>>();
    if (index < 0 || index >= entries.length) {
      throw MissingException('history entry ${step < 0 ? 'before' : 'after'} this one', where: '$url');
    }
    final was = _url;
    _arm(_client._render._wait._lifecycle);
    await _call('Page.navigateToHistoryEntry', {'entryId': entries[index]['id']});
    // A bfcache restore fires no `load`; the URL moving is the other proof.
    var decided = false;
    final moved = await Future.any([_settle(_timeout), _left(was, () => decided)]);
    decided = true;
    // Ends whichever wait lost.
    _complete();
    _disarm();
    if (!moved) throw _unsettled('Going ${step < 0 ? 'back' : 'forward'} from $was', _timeout);
  }

  Future<bool> _left(Uri was, bool Function() decided) async {
    final deadline = Clock.current.elapsed + _timeout;
    while (!isClosed && !decided() && Clock.current.elapsed < deadline) {
      if (_url != was) return true;
      await const Duration(milliseconds: 20).delay();
      Cancel.check();
    }
    return _url != was;
  }

  /// The page as a PDF. Headless only: a visible Chrome refuses (`Printing is not available`).
  Future<Uint8List> pdf({bool background = true, bool landscape = false, double scale = 1}) async {
    final printed = await _call('Page.printToPDF', {
      'printBackground': background,
      'landscape': landscape,
      'scale': scale,
      'transferMode': 'ReturnAsStream',
    });
    // Read a chunk at a time: one base64 answer holds the document several times over.
    final handle = printed['stream'] as String? ?? '';
    final out = BytesBuilder(copy: false);
    try {
      while (true) {
        final chunk = await _call('IO.read', {'handle': handle, 'size': 1 << 20});
        final data = chunk['data'] as String? ?? '';
        out.add(chunk['base64Encoded'] == true ? base64.decode(data) : utf8.encode(data));
        if (chunk['eof'] == true) return out.takeBytes();
      }
    } finally {
      await _client
          ._call('IO.close', {'handle': handle}, _tab)
          .catchError((Object _) => const <String, Object?>{}); // best-effort: the tab may be gone
    }
  }

  /// Sets headers sent with every request this tab makes from now on (every third-party
  /// subresource included, so never a credential).
  Future<void> _extraHeaders(Map<String, String> headers) => _call('Network.setExtraHTTPHeaders', {'headers': headers});

  /// Handles the page's dialogs; answers a function that unregisters [handler].
  ///
  /// A handler that neither accepts nor dismisses (or throws) gets the default: dismissed,
  /// except `beforeunload`, which is accepted.
  ///
  /// ```dart
  /// page.onDialog((d) => d.accept(d.type == DialogType.prompt ? 'yes' : null));
  /// ```
  void Function() onDialog(FutureOr<void> Function(Dialog dialog)? handler) {
    _onDialog = handler;
    return () {
      if (identical(_onDialog, handler)) _onDialog = null;
    };
  }

  /// Always answers: Chrome holds the renderer on an open dialog, which would take a pooled tab
  /// with it. Dismissing `beforeunload` would cancel the navigation, so it is accepted.
  Future<void> _dialog(Map<String, Object?> params) async {
    final dialog = Dialog._(
      this,
      DialogType.values.asNameMap()[params['type']] ?? DialogType.alert,
      params['message'] as String? ?? '',
      params['defaultPrompt'] as String? ?? '',
    );
    try {
      await _onDialog?.call(dialog);
    } catch (_) {} // a throwing dialog handler leaves the default answer
    await (dialog.type == DialogType.beforeunload ? dialog.accept() : dialog.dismiss());
  }

  /// The iframe whose URL or `name` contains [match], as a [Page] every method works in; a
  /// [MissingException] when none does. Asking again gives the same view; closing it closes
  /// nothing.
  ///
  /// ```dart
  /// final form = await page.frame('checkout');
  /// await form.fill('#card', '4242…');
  /// ```
  Future<Page> frame(String match) async {
    final owner = _owner;
    await (owner._frames ??= owner._watchFrames());
    final tree = await owner._call('Page.getFrameTree');
    // A cross-origin frame is not in the tree.
    final found =
        _descend((tree['frameTree'] as Map<String, Object?>?) ?? const {}, match, root: true) ??
        await owner._remoteMatching(match);
    if (found == null) throw MissingException('frame matching "$match"', where: '$url');
    final (id, at) = found;
    final session = owner._remotes[id]?.session ?? _tab.session;
    if (owner._views[id] case final view? when !view.isClosed && view._tab.session == session) {
      return view.._url = Uri.tryParse(at) ?? view._url;
    }
    await owner._views.remove(id)?.close();
    final page = switch (owner._remotes[id]) {
      final remote? => Page._(_client, _Tab(id, remote.session), parent: owner, remote: true),
      null => Page._(_client, _tab, parent: owner),
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
    return owner._views[id] = page;
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
      } catch (_) {} // a target that went away keeps the URL it attached with
      if (url.contains(match)) return (key, url);
      try {
        final holder = await _call('DOM.getFrameOwner', {'frameId': key});
        final node = await _call('DOM.describeNode', {'backendNodeId': holder['backendNodeId']});
        final attributes = ((node['node'] as Map<String, Object?>?)?['attributes'] as List?) ?? const [];
        for (var i = 0; i + 1 < attributes.length; i += 2) {
          final name = '${attributes[i + 1]}';
          if (attributes[i] == 'name' && name.isNotEmpty && name.contains(match)) return (key, url);
        }
      } catch (_) {} // a frame without an owner node is matched by URL only
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
    // A navigation waiting on this tab gives up now, not at its timeout.
    _complete();
    if (_parent != null) return _events?.cancel().then((_) {});
    _client._pages.remove(this);
    _client._free.remove(this);
    await _events?.cancel();
    for (final view in _views.values) {
      await view.close();
    }
    _views.clear();
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
    } catch (_) {} // best-effort: the tab may be closed already
  }

  // ---- internals -------------------------------------------------------------------------

  /// Contexts for in-process frames; out-of-process ones attach from the tab's start.
  Future<void> _watchFrames() => _call('Runtime.enable');

  /// [method] on this tab's session; a cancel of the enclosing work ends it.
  Future<Map<String, Object?>> _call(String method, [Map<String, Object?>? params, Duration? timeout]) {
    if (_client.isClosed) return _client._call(method, params, _tab, timeout, true);
    if (isClosed) return Future.error(ChromeException('The page is closed', method: method, uri: _url));
    return _client._call(method, params, _tab, timeout, true);
  }

  /// The JavaScript for the first match of [selector].
  static String _q(String selector) => 'document.querySelector(${jsonEncode(selector)})';

  /// Whether [e] is an evaluation cut short by a navigation, worth retrying once it settles:
  /// the protocol's own words for it, never a page or browser that is gone.
  static bool _navigatedAway(ChromeException e) {
    if (e.detached || e.method.isEmpty || e.message.contains('The page is closed')) return false;
    final msg = e.message;
    return msg.contains('navigated') ||
        msg.contains('Execution context was destroyed') ||
        msg.contains('Cannot find context');
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
    } on ChromeException catch (e) {
      if (e.detached) rethrow;
      return null; // no layout: hidden, or gone from the DOM since
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
    } on ChromeException catch (e) {
      // The protocol's refusal of a selector or a node is absence; a browser gone is not.
      if (e.detached || e.method.isEmpty) rethrow;
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
        case 'Inspector.targetCrashed' when _parent == null:
          // A crashed tab answers nothing again: not one for the pool.
          unawaited(close());
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
        for (final view in [..._views.values.where((view) => view._tab.session == session)]) {
          _views.remove(view._frame);
          unawaited(view.close());
        }
        unawaited(_children.remove(session)?.cancel());
        unawaited(_client._sessions.remove(session)?.close());
      case 'Fetch.requestPaused':
        // With an authenticating proxy everything pauses, so refusal is by kind. `headers`
        // replaces the request's, so the grant is merged into the ones it had.
        final kind = '${params['resourceType']}';
        final paused = params['request'] as Map<String, Object?>?;
        final blocked = _blocked ?? const <Resource>{};
        final refused =
            blocked.any((r) => r._types.contains(kind)) || (blocked.contains(Resource.offsite) && _offsite(params));
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
                'authChallengeResponse': switch (_client._loginFor(params['authChallenge'])) {
                  (final user, final password) when proxied => {
                    'response': 'ProvideCredentials',
                    'username': user,
                    'password': password.reveal,
                  },
                  _ => {'response': 'CancelAuth'},
                },
              }, on)
              .catchError((Object _) => const <String, Object?>{}),
        );
    }
  }

  /// Whether the paused request [params] is for another site than the page's. The page's own
  /// document (the main frame's) sets the site, and is never refused.
  bool _offsite(Map<String, Object?> params) {
    final url = Uri.tryParse('${(params['request'] as Map?)?['url'] ?? ''}');
    if (url == null || (url.scheme != 'http' && url.scheme != 'https' && url.scheme != 'ws' && url.scheme != 'wss')) {
      return false;
    }
    final site = _registrable(url.host);
    if (params['resourceType'] == 'Document' && (_frame.isEmpty || params['frameId'] == _frame)) {
      _site = site;
      return false;
    }
    return site != (_site ??= _registrable(_url.host));
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

  /// Waits for the armed event; answers whether it arrived in time.
  Future<bool> _settle([Duration? timeout]) async {
    final waiter = _waiter;
    if (waiter == null) return true;
    var fired = true;
    try {
      final settled = waiter.future.timeout(timeout ?? _timeout, onTimeout: () => fired = false);
      await (Cancel.token == null ? settled : settled.cancellable);
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
    'ddos-guard',
    'DDoS-Guard',
  ];

  bool _interstitial(Response res) {
    if (!_challenging(res.statusCode)) return false;
    final body = res.text;
    return body.length < 80000 && _markers.any(body.contains);
  }
}

/// What kind of dialog a page opened.
///
/// {@category Networking}
enum DialogType { alert, confirm, prompt, beforeunload }

/// A dialog the page opened. See [Page.onDialog]. Answering twice is answering once.
///
/// {@category Networking}
final class Dialog {
  final DialogType type;

  final String message;

  /// What a `prompt` was pre-filled with; empty otherwise.
  final String defaultValue;

  final Page _page;
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
      // Never cut short: an open dialog holds the tab's renderer.
      await _page._client._call('Page.handleJavaScriptDialog', {'accept': accept, 'promptText': ?text}, _page._tab);
    } catch (_) {} // best-effort: the dialog may be gone already
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
