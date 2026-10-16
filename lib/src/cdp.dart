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
import 'dart:isolate';
import 'dart:typed_data';

import '../core.dart';
import 'exit.dart' as exit;

/// What a tab action throws when the page itself fails it: a click that
/// misses, a PDF that never renders, a download the site cancels, a
/// protocol call the browser rejects. An [Exception] like every toolkit
/// failure (a `Command` prints its message, never a stack trace).
final class BrowserException extends ToolkitException {
  BrowserException(super.message, {this.selector, super.cause});

  /// The selector in use, when the failure names one.
  final String? selector;

  @override
  String toString() => 'BrowserException: $message';
}

typedef Msg = Map<String, Object?>;

/// One browser connection.
final class Cdp {
  Cdp._(Stream<Object?> incoming, this._add, this._closeWire, [this._ref]) {
    incoming.listen(_onMessage, onDone: _onDone, onError: _onDone, cancelOnError: true);
    browser.on('Target.detachedFromTarget', (e) => _sessions.remove(e['sessionId'])?._end());
  }

  /// Connect to a `ws://…/devtools/browser/…` endpoint.
  static Future<Cdp> connect(String url) async {
    final ws = await io.WebSocket.connect(url, compression: io.CompressionOptions.compressionOff);
    return Cdp._(ws, ws.add, ws.close);
  }

  /// Talk over a pipe pair: NUL-terminated JSON messages written to [into],
  /// read from the FIFO at [from]. The read runs in a helper isolate whose
  /// port holds the script open only while a call or a wait is pending, so
  /// a browser nobody closed never keeps a finished script alive.
  static Future<Cdp> pipe(String from, io.IOSink into) async {
    // A write to a Chrome that died fails here; the read side's end says so.
    into.done.catchError((Object _) {});
    final port = RawReceivePort()..keepIsolateAlive = false;
    final incoming = StreamController<Object?>(sync: true);
    var open = true;
    port.handler = (Object? m) {
      switch (m) {
        case null:
          open = false;
          port.close();
          incoming.close();
        case [final String error]:
          incoming.addError(io.FileSystemException(error, from));
        default:
          incoming.add(m);
      }
    };
    final reader = await Isolate.spawn(_readPipe, (port.sendPort, from));
    return Cdp._(
      incoming.stream,
      (m) => into
        ..add(utf8.encode(m))
        ..add(const [0]),
      () async {
        await into.close();
        reader.kill();
        if (open) {
          open = false;
          port.close();
          await incoming.close();
        }
        return null;
      },
      (alive) {
        if (open) port.keepIsolateAlive = alive;
      },
    );
  }

  /// The helper isolate: each NUL-terminated message at the FIFO [from], as
  /// text, to [to]; then null (or `[error]` first).
  static Future<void> _readPipe((SendPort, String) args) async {
    final (to, from) = args;
    final buf = BytesBuilder(copy: false);
    try {
      await for (final chunk in io.File(from).openRead()) {
        var start = 0;
        for (var i = 0; i < chunk.length; i++) {
          if (chunk[i] != 0) continue;
          buf.add(chunk.sublist(start, i));
          start = i + 1;
          to.send(utf8.decode(buf.takeBytes(), allowMalformed: true));
        }
        if (start < chunk.length) buf.add(chunk.sublist(start));
      }
    } catch (e) {
      to.send(['$e']);
    }
    to.send(null);
  }

  final void Function(String message) _add;
  final Future<Object?> Function() _closeWire;

  /// Holds the script open while true (a pipe's reader port); null for a
  /// WebSocket, whose socket holds it anyway.
  final void Function(bool alive)? _ref;

  /// Hears the busy state flip: a call or a wait is pending (true), or
  /// none is (false).
  void Function(bool busy)? onBusy;

  var _holds = 0;

  /// Count [work] as pending until it completes: the script stays alive
  /// for it. Returns [work], which Ctrl-C fails with
  /// [InterruptedException] unless the browser is [ending].
  Future<T> hold<T>(Future<T> work, {bool always = false}) {
    if (_holds++ == 0) _busy(true);
    final held = work.whenComplete(() {
      if (--_holds == 0) _busy(false);
    });
    return always || ending ? held : exit.interruptible(held);
  }

  /// Set while the browser closes: its own calls are never interrupted.
  var ending = false;

  void _busy(bool busy) {
    _ref?.call(busy);
    onBusy?.call(busy);
  }

  /// Completes when the connection ends (the browser exited or closed it).
  Future<void> get done => _done.future;
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

  /// The id of a reply, read without parsing it.
  static final _id = RegExp(r'^\s*\{\s*"id"\s*:\s*(\d+)');

  void _onMessage(Object? data) {
    final text = data is String ? data : utf8.decode(data! as List<int>, allowMalformed: true);
    final Msg msg;
    try {
      msg = jsonDecode(text) as Msg;
    } catch (e) {
      // A reply that does not parse still fails its call, if its id reads.
      final id = int.tryParse(_id.firstMatch(text)?[1] ?? '');
      if (_pending.remove(id) case (final done, final method, _)) {
        done.completeError(BrowserException('$method: a malformed reply', cause: e));
      }
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

  /// Send [method]; completes with its result, or throws [BrowserException]
  /// (a [TimeoutException] after [timeout], when given: the late reply is
  /// dropped).
  Future<Msg> send(String method, [Msg params = const {}, Duration? timeout]) =>
      _send(method, params, timeout, always: _cdp.ending);

  /// [send] for cleanup (closing a tab): Ctrl-C never fails it.
  Future<Msg> finish(String method, [Msg params = const {}]) => _send(method, params, null, always: true);

  Future<Msg> _send(String method, Msg params, Duration? timeout, {required bool always}) {
    if (_gone.isCompleted || _cdp._closing) {
      return Future.error(BrowserException('$method: target closed', cause: _cdp._cause));
    }
    if (exit.interrupted && !always) return Future.error(const InterruptedException());
    final done = Completer<Msg>();
    final n = ++_cdp._next;
    _cdp._pending[n] = (done, method, this);
    try {
      _cdp._add(jsonEncode({'id': n, 'method': method, 'params': params, 'sessionId': ?id}));
    } catch (e) {
      _cdp._pending.remove(n);
      return Future.error(BrowserException('$method: browser closed', cause: e));
    }
    if (timeout != null) {
      final timer = Timer(timeout, () {
        if (_cdp._pending.remove(n) != null) done.completeError(TimeoutException(method, timeout));
      });
      done.future.whenComplete(timer.cancel).ignore();
    }
    return _cdp.hold(done.future, always: always);
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
    if (exit.interrupted && !_cdp.ending) return Future.error(const InterruptedException());
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
    return _cdp.hold(done.future);
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
