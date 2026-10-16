/// A Chrome DevTools Protocol client over `dart:io` `WebSocket`, for
/// `chrome`. One [Cdp] is one browser connection; every tab is a flat
/// [CdpSession] on it (`Target.attachToTarget` with `flatten`).
///
/// Events reach handlers synchronously, in protocol order, so a handler that
/// registers for a follow-up event (a response's `loadingFinished`) never
/// misses it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import '../core.dart';

/// What a tab action throws when the page itself fails it: a click that
/// misses, a PDF that never renders, a download the site cancels, a
/// protocol call the browser rejects. Extends [StateError], so an existing
/// `on StateError` keeps catching it.
final class BrowserException extends StateError implements ToolkitException {
  BrowserException(super.message, {this.selector, this.cause});

  /// The selector in use, when the failure names one.
  final String? selector;

  @override
  final Object? cause;
}

typedef Msg = Map<String, Object?>;

/// One browser connection.
final class Cdp {
  Cdp._(this._ws) {
    _ws.listen(_onMessage, onDone: _onDone, onError: (Object _) => _onDone(), cancelOnError: true);
    browser.on('Target.detachedFromTarget', (e) => _sessions.remove(e['sessionId'])?._end());
  }

  /// Connect to a `ws://…/devtools/browser/…` endpoint.
  static Future<Cdp> connect(String url) async =>
      Cdp._(await io.WebSocket.connect(url, compression: io.CompressionOptions.compressionOff));

  final io.WebSocket _ws;
  var _next = 0;
  final _pending = <int, (Completer<Msg>, String, CdpSession)>{};
  final _sessions = <String, CdpSession>{};

  /// The browser-level session (no session id).
  late final CdpSession browser = CdpSession._(this, null);

  /// Completes when the connection is gone.
  Future<void> get done => _done.future;
  final _done = Completer<void>();

  /// A new flat session on [targetId].
  Future<CdpSession> attach(String targetId) async {
    final r = await browser.send('Target.attachToTarget', {'targetId': targetId, 'flatten': true});
    final id = r['sessionId']! as String;
    return _sessions.putIfAbsent(id, () => CdpSession._(this, id));
  }

  Future<void> close() async {
    try {
      await _ws.close();
    } catch (_) {}
    _onDone();
  }

  void _onMessage(Object? data) {
    final Msg msg;
    try {
      msg = jsonDecode(data is String ? data : utf8.decode(data! as List<int>)) as Msg;
    } catch (_) {
      return;
    }
    if (msg['id'] case final int id) {
      final (done, method, _) = _pending.remove(id) ?? (null, '', browser);
      if (done == null) return;
      if (msg['error'] case final Msg error) {
        done.completeError(BrowserException('$method: ${error['message']}', cause: error));
      } else {
        done.complete((msg['result'] as Msg?) ?? const {});
      }
      return;
    }
    final session = switch (msg['sessionId']) {
      final String id => _sessions[id],
      _ => browser,
    };
    if (session == null) return;
    session._emit(msg['method']! as String, (msg['params'] as Msg?) ?? const {});
  }

  void _onDone() {
    if (_done.isCompleted) return;
    _done.complete();
    for (final s in [..._sessions.values, browser]) {
      s._end();
    }
    _sessions.clear();
    _fail((_) => true, 'browser closed');
  }

  void _fail(bool Function(CdpSession) which, String why) {
    for (final id in [..._pending.keys]) {
      final (done, method, s) = _pending[id]!;
      if (!which(s)) continue;
      _pending.remove(id);
      done.completeError(BrowserException('$method: $why'));
    }
  }
}

/// A session: the browser itself, or one tab.
final class CdpSession {
  CdpSession._(this._cdp, this.id);

  final Cdp _cdp;

  /// The protocol session id (`null` for the browser).
  final String? id;

  final _handlers = <String, List<void Function(Msg)>>{};

  /// Completes when the tab detaches or the connection drops.
  Future<void> get gone => _gone.future;
  final _gone = Completer<void>();

  bool get isGone => _gone.isCompleted;

  /// Send [method]; completes with its result, or throws [BrowserException].
  Future<Msg> send(String method, [Msg params = const {}]) {
    if (_gone.isCompleted) return Future.error(BrowserException('$method: target closed'));
    final done = Completer<Msg>();
    final n = ++_cdp._next;
    _cdp._pending[n] = (done, method, this);
    _cdp._ws.add(jsonEncode({'id': n, 'method': method, 'params': params, 'sessionId': ?id}));
    return done.future;
  }

  /// Call [handler] for every [method] event; the returned function stops it.
  void Function() on(String method, void Function(Msg params) handler) {
    final list = _handlers.putIfAbsent(method, () => []);
    list.add(handler);
    return () => list.remove(handler);
  }

  /// The next [method] event that passes [where]. Fails with a
  /// [TimeoutException] after [timeout] and with [BrowserException] when
  /// the session ends first.
  Future<Msg> once(String method, {bool Function(Msg params)? where, Duration? timeout}) {
    final done = Completer<Msg>();
    late final void Function() off;
    Timer? timer;
    void finish() {
      off();
      timer?.cancel();
    }

    off = on(method, (e) {
      if (where != null && !where(e)) return;
      finish();
      done.complete(e);
    });
    if (timeout != null) {
      timer = Timer(timeout, () {
        finish();
        if (!done.isCompleted) done.completeError(TimeoutException(method, timeout));
      });
    }
    gone.then((_) {
      finish();
      if (!done.isCompleted) done.completeError(BrowserException('browser closed'));
    });
    return done.future;
  }

  void _emit(String method, Msg params) {
    final list = _handlers[method];
    if (list == null) return;
    for (final h in [...list]) {
      try {
        h(params);
      } catch (_) {}
    }
  }

  void _end() {
    if (_gone.isCompleted) return;
    _gone.complete();
    _cdp._fail((s) => s == this, 'target closed');
  }
}
