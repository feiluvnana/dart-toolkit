/// A Chrome DevTools Protocol client for `chrome`, over a WebSocket
/// ([Cdp.connect]) or the pipe a launched Chrome reads (fds 3 and 4,
/// `--remote-debugging-pipe`: no port any local process could reach). One
/// [Cdp] is one browser connection; every tab is a flat [CdpSession] on it
/// (`Target.attachToTarget` with `flatten`).
///
/// Events reach handlers synchronously, in protocol order, so a handler that
/// registers for a follow-up event (a response's `loadingFinished`) never
/// misses it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

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
  Cdp._(Stream<Object?> incoming, this._add, this._closeWire) {
    incoming.listen(_onMessage, onDone: _onDone, onError: _onDone, cancelOnError: true);
    browser.on('Target.detachedFromTarget', (e) => _sessions.remove(e['sessionId'])?._end());
  }

  /// Connect to a `ws://…/devtools/browser/…` endpoint.
  static Future<Cdp> connect(String url) async {
    final ws = await io.WebSocket.connect(url, compression: io.CompressionOptions.compressionOff);
    return Cdp._(ws, ws.add, ws.close);
  }

  /// Talk over a pipe pair: NUL-terminated JSON messages written to [into],
  /// read from [from].
  static Cdp pipe(Stream<List<int>> from, io.IOSink into) {
    // A write to a Chrome that died fails here; the read side's end says so.
    into.done.catchError((Object _) {});
    return Cdp._(
      _nulSplit(from),
      (m) => into
        ..add(utf8.encode(m))
        ..add(const [0]),
      into.close,
    );
  }

  /// The NUL-terminated messages in [bytes].
  static Stream<Object?> _nulSplit(Stream<List<int>> bytes) async* {
    final buf = BytesBuilder(copy: false);
    await for (final chunk in bytes) {
      var from = 0;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] != 0) continue;
        buf.add(chunk.sublist(from, i));
        from = i + 1;
        yield buf.takeBytes();
      }
      if (from < chunk.length) buf.add(chunk.sublist(from));
    }
  }

  final void Function(String message) _add;
  final Future<Object?> Function() _closeWire;
  var _next = 0;
  final _pending = <int, (Completer<Msg>, String, CdpSession)>{};
  final _sessions = <String, CdpSession>{};

  /// The browser-level session (no session id).
  late final CdpSession browser = CdpSession._(this, null);

  final _done = Completer<void>();

  /// A new flat session on [targetId].
  Future<CdpSession> attach(String targetId) async {
    final r = await browser.send('Target.attachToTarget', {'targetId': targetId, 'flatten': true});
    final id = r['sessionId']! as String;
    return _sessions.putIfAbsent(id, () => CdpSession._(this, id));
  }

  Future<void> close() async {
    _closing = true;
    try {
      await _closeWire();
    } catch (_) {}
    _onDone();
  }

  /// Set by [close]: a send from then on fails at once.
  var _closing = false;

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

  /// The connection ended; [error] is the socket's, when it failed.
  void _onDone([Object? error]) {
    if (_done.isCompleted) return;
    _cause = error;
    _done.complete();
    for (final s in [..._sessions.values, browser]) {
      s._end();
    }
    _sessions.clear();
    _fail((_) => true, 'browser closed');
  }

  /// Why the connection failed, if it did.
  Object? _cause;

  void _fail(bool Function(CdpSession) which, String why) {
    for (final id in [..._pending.keys]) {
      final (done, method, s) = _pending[id]!;
      if (!which(s)) continue;
      _pending.remove(id);
      done.completeError(BrowserException('$method: $why', cause: _cause));
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
    if (_gone.isCompleted || _cdp._closing) {
      return Future.error(BrowserException('$method: target closed', cause: _cdp._cause));
    }
    final done = Completer<Msg>();
    final n = ++_cdp._next;
    _cdp._pending[n] = (done, method, this);
    try {
      _cdp._add(jsonEncode({'id': n, 'method': method, 'params': params, 'sessionId': ?id}));
    } catch (e) {
      _cdp._pending.remove(n);
      return Future.error(BrowserException('$method: browser closed', cause: e));
    }
    return done.future;
  }

  /// Call [handler] for every [method] event; the returned function stops it.
  void Function() on(String method, void Function(Msg params) handler) {
    final list = _handlers.putIfAbsent(method, () => []);
    list.add(handler);
    return () => list.remove(handler);
  }

  /// The next [method] event that passes [where]. Fails with a
  /// [TimeoutException] after [timeout], with [BrowserException] when the
  /// session ends first, and with [where]'s error when it throws.
  Future<Msg> once(String method, {bool Function(Msg params)? where, Duration? timeout}) {
    final done = Completer<Msg>();
    if (_gone.isCompleted) return Future.error(BrowserException('browser closed', cause: _cdp._cause));
    late final void Function() off;
    Timer? timer;
    late final void Function() ended;
    void finish() {
      off();
      timer?.cancel();
      _waiters.remove(ended);
    }

    ended = () {
      finish();
      done.completeError(BrowserException('browser closed', cause: _cdp._cause));
    };

    off = on(method, (e) {
      try {
        if (where != null && !where(e)) return;
      } catch (error, st) {
        finish();
        done.completeError(error, st);
        return;
      }
      finish();
      done.complete(e);
    });
    if (timeout != null) {
      timer = Timer(timeout, () {
        finish();
        if (!done.isCompleted) done.completeError(TimeoutException(method, timeout));
      });
    }
    _waiters.add(ended);
    return done.future;
  }

  /// The pending [once] calls, failed when the session ends.
  final _waiters = <void Function()>{};

  void _emit(String method, Msg params) {
    final list = _handlers[method];
    if (list == null) return;
    for (final h in [...list]) {
      try {
        h(params);
      } catch (e) {
        // One bad handler must not stop the others or the connection.
        io.stderr.writeln('chrome: a $method handler failed: $e');
      }
    }
  }

  void _end() {
    if (_gone.isCompleted) return;
    _gone.complete();
    for (final w in [..._waiters]) {
      w();
    }
    _waiters.clear();
    _cdp._fail((s) => s == this, 'target closed');
  }
}
