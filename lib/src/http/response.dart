// Response: the body as a Reader, and its Future mirrors.
part of '../../http.dart';

/// An HTTP response: a [Reader] of the body, streamed from the socket.
///
/// - A non-2xx status is still a [Response] (unless the client says
///   `check:`). [ok] tests 200–299. The readings ([text], [bytes], [lines])
///   work on any status, but only a 2xx body can be piped: [stream] (and so
///   `>`/`to`) throws the same [HttpStatusException] as [check] otherwise.
/// - [text] decodes with the charset in `content-type`, then
///   `<meta charset>` (HTML or an untyped body only), then UTF-8 (WHATWG CJK
///   decoders included). Unknown charsets fall back to UTF-8; bad bytes
///   become `�`.
/// - A body of up to 64 KB is read as the headers arrive, so an unread
///   response never keeps the script alive; [close] drops a longer unread
///   one. A body read or piped to the end releases the connection by itself.
///   The `Future<Response>` mirrors (`api.get(u).status()`) close the
///   response after reading.
final class Response with Reader implements Closeable {
  Response._(HttpClientResponse resp, this._client, this._method, this._url, {required this._head})
    : _resp = resp,
      _status = resp.statusCode,
      _headers = null {
    _client._responses.add(this);
  }

  /// A stored answer ([Http.client]'s `cache:`): no socket behind it.
  Response._cached(this._client, this._method, this._url, this._status, Map<String, String> headers, Uint8List bytes)
    : _resp = null,
      _headers = headers,
      _head = false {
    _cached = bytes;
    _done = _released = true;
  }

  final HttpClientResponse? _resp;
  final Map<String, String>? _headers;
  final _Client _client;
  final String _method;
  final int _status;

  /// The final URL, after redirects.
  final String _url;

  /// A HEAD response: no body follows, whatever `content-length` says.
  final bool _head;

  Uint8List? _cached;
  Future<Uint8List>? _reading;

  static const _prefix = 64 * 1024;
  StreamSubscription<List<int>>? _preSub;
  Completer<void>? _preReady; // the body ended, overflowed or failed
  final _preBuf = BytesBuilder(copy: false);
  var _preEnded = false, _preTaken = false;
  Object? _preError;
  StackTrace? _preStack;

  var _streaming = false;
  var _closed = false;
  var _done = false;
  var _released = false;

  bool get _empty => _head || _status == 204 || _status == 304;

  void _prefetch() {
    final len = _empty ? 0 : size();
    if (len != null && len > _prefix) return; // known to be long: streamed
    _streaming = true;
    final ready = _preReady = Completer<void>();
    _preSub = _bodyStream().listen(
      (chunk) {
        _preBuf.add(chunk);
        if (_preBuf.length > _prefix && !ready.isCompleted) {
          _preSub!.pause();
          ready.complete();
        }
      },
      onError: (Object e, StackTrace st) {
        _preError = e;
        _preStack = st;
        _preEnded = true;
        _finish();
        if (!ready.isCompleted) ready.complete();
      },
      onDone: () {
        _preEnded = true;
        _cached = _preBuf.takeBytes();
        _finish();
        if (!ready.isCompleted) ready.complete();
      },
      cancelOnError: true,
    );
  }

  /// The prefetched body as a stream: the cache, or the held prefix then
  /// the rest through the resumed subscription.
  Stream<List<int>> _fromPrefetch() async* {
    await _preReady!.future;
    final e = _preError;
    if (e != null) Error.throwWithStackTrace(e, _preStack!);
    if (_preEnded) {
      yield _cached!.asUnmodifiableView();
      return;
    }
    if (_preTaken) throw StateError('body already streaming: ${names.redact(url())}');
    _preTaken = true;
    yield _preBuf.takeBytes();
    final rest = StreamController<List<int>>();
    final sub = _preSub!
      ..onData(rest.add)
      ..onError((Object e, StackTrace st) {
        rest.addError(e, st);
        rest.close();
      })
      ..onDone(rest.close);
    rest.onCancel = sub.cancel;
    sub.resume();
    try {
      yield* rest.stream;
    } finally {
      _finish();
    }
  }

  /// HTTP status code (e.g. 200, 404).
  int status() => _status;

  /// Whether the status is 2xx.
  bool ok() => _status >= 200 && _status < 300;

  /// This response when 2xx; otherwise throws [HttpStatusException] with
  /// the body's first 200 characters (and drops the body).
  Future<Response> check() async {
    if (ok()) return this;
    throw await _statusError();
  }

  Future<HttpStatusException> _statusError() async {
    final snippet = await _snippet();
    final where = names.redact(_url);
    return HttpStatusException(
      'HTTP $_status $_method $where${snippet.isEmpty ? '' : ': $snippet'}',
      status: _status,
      method: _method,
      url: where,
      snippet: snippet,
    );
  }

  /// Response header [name] (case-insensitive) or `null` if absent.
  String? header(String name) {
    final headers = _headers;
    if (headers != null) return headers[name.toLowerCase()];
    final values = _resp!.headers[name];
    if (values == null || values.isEmpty) return null;
    return values.join(', ');
  }

  /// The final URL, after redirects.
  String url() => _url;

  /// The body's length in bytes as it will be read, or `null` when unknown
  /// (no `content-length`, or a compressed body decoded on the fly).
  int? size() {
    final encoding = header('content-encoding');
    if (encoding != null && encoding.toLowerCase() != 'identity' && _resp != null) return null;
    final n = int.tryParse(header('content-length')?.trim() ?? '');
    return n == null || n < 0 ? null : n;
  }

  /// A file name for the body: the `content-disposition` filename
  /// (`filename*=` wins over `filename=`, paths stripped), else the final
  /// URL's last segment, else `'download'`.
  String name() => names.fileName(url: _url, contentDisposition: header('content-disposition'));

  /// Where the body came from: final URL, status and file name.
  @override
  Origin origin() => Origin(url: _url, status: _status, name: name());

  /// The body as text (see the class doc for the charset rules); cached.
  @override
  Future<String> text() async => charset.Charset.decode(await bytes(), contentType: header('content-type'));

  /// The text line by line; works on any status, like [text].
  @override
  Stream<String> lines() => ok() ? super.lines() : Stream.fromFuture(text()).expand(LineSplitter.split);

  /// The body as bytes, cached like [text]: an unmodifiable view, no copy.
  @override
  Future<List<int>> bytes() async {
    if (_closed) throw StateError('response is closed: ${names.redact(url())}');
    final cached = _cached;
    if (cached != null) return cached.asUnmodifiableView();
    if (_preReady != null) return (await (_reading ??= _readAll())).asUnmodifiableView();
    final reading = _reading;
    if (reading != null) return (await reading).asUnmodifiableView();
    if (_streaming) throw StateError('body already streaming: ${names.redact(url())}');
    _streaming = true;
    return (await (_reading = _readAll())).asUnmodifiableView();
  }

  Future<Uint8List> _readAll() async {
    try {
      final out = BytesBuilder(copy: false);
      final limit = _client._s.limit;
      await for (final chunk in _preReady != null ? _fromPrefetch() : _bodyStream()) {
        out.add(chunk);
        if (out.length > limit) {
          await _abandon();
          throw ContentException(
            'response body over $limit bytes: pipe it to a file, or raise Http.client(limit:) '
            '(${names.redact(url())})',
          );
        }
      }
      return _cached = out.takeBytes();
    } finally {
      _reading = null;
      _finish();
    }
  }

  @override
  Stream<List<int>> stream() {
    if (_closed) throw StateError('response is closed: ${names.redact(url())}');
    if (!ok()) return _refused();
    final cached = _cached;
    if (cached != null) return Stream.value(cached.asUnmodifiableView());
    if (_preReady != null) return _fromPrefetch();
    if (_streaming) throw StateError('body already streaming: ${names.redact(url())}');
    _streaming = true;
    return _streamBody();
  }

  /// Only a 2xx body can be piped, so an error page is never saved.
  Stream<List<int>> _refused() async* {
    throw await _statusError();
  }

  Stream<List<int>> _streamBody() async* {
    try {
      yield* _bodyStream();
    } finally {
      _finish();
    }
  }

  /// Drop a body nobody will read, so the socket doesn't keep the script
  /// alive. Idempotent; a no-op after the body is consumed. Reading after
  /// [close] is a [StateError].
  @override
  Future<void> close() async {
    final ready = _preReady;
    if (ready != null) {
      _closed = true;
      if (_preEnded || _preTaken) return;
      // A short body still arriving gets the drain budget, then is dropped.
      if (_preBuf.length <= _prefix) await ready.future.timeout(_drainBudget, onTimeout: () {});
      if (!_preEnded) {
        await _preSub?.cancel();
        await _abandon();
      }
      return;
    }
    if (_closed || _done) {
      _closed = true;
      _finish();
      return;
    }
    final len = _empty ? 0 : size();
    if (len == null || len > _prefix) return _abandon();
    _closed = true;
    try {
      await _resp!.drain<void>().timeout(_drainBudget);
    } catch (_) {
      await _detach(_resp!);
    } finally {
      _finish();
    }
  }

  /// The first 200 characters of the body, whitespace collapsed, then the
  /// body is dropped. Empty when unreadable.
  Future<String> _snippet() async {
    final out = BytesBuilder(copy: false);
    try {
      final cached = _cached;
      if (cached != null) {
        out.add(cached.length > 1024 ? cached.sublist(0, 1024) : cached);
      } else if (_preReady != null && !_closed) {
        await _preReady!.future.timeout(_drainBudget, onTimeout: () {});
        out.add(_cached ?? _preBuf.toBytes());
      } else if (!_streaming && !_closed && !_done) {
        _streaming = true;
        await for (final chunk in _bodyStream()) {
          out.add(chunk);
          if (out.length >= 1024) break;
        }
      }
    } catch (_) {}
    await _abandon();
    final text = charset.Charset.decode(out.takeBytes(), contentType: header('content-type'));
    final flat = text.replaceAll(_spaces, ' ').trim();
    return flat.length > 200 ? '${flat.substring(0, 200)}...' : flat;
  }

  /// Drop the body without draining it: force-close the socket instead of
  /// waiting up to the full timeout for bytes nobody wants.
  Future<void> _abandon() async {
    _closed = true;
    if (!_done) {
      try {
        await _preSub?.cancel();
      } catch (_) {}
      final resp = _resp;
      if (resp != null) await _detach(resp);
    }
    _finish();
  }

  /// The socket's body with the stall timeout, which [_kill] can fail.
  Stream<List<int>> _bodyStream() {
    final limit = _client._s.timeout;
    late final StreamController<List<int>> out;
    StreamSubscription<List<int>>? sub;
    out = StreamController<List<int>>(
      sync: true,
      onListen: () {
        sub = _resp!
            .timeout(
              limit,
              onTimeout: (sink) =>
                  sink.addError(Timeout('body stalled for ${limit.human()}: $_method ${names.redact(_url)}', limit)),
            )
            .listen(out.add, onError: out.addError, onDone: out.close);
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () => sub?.cancel(),
    );
    _killer = (error) {
      sub?.cancel();
      if (!out.isClosed) {
        out.addError(error);
        out.close();
      }
    };
    return out.stream;
  }

  void Function(Object error)? _killer;

  /// Fail the body read in flight with [error] and drop the connection.
  void _kill(Object error) {
    _closed = true;
    final ready = _preReady;
    if (ready != null && !ready.isCompleted) {
      _preError = error;
      _preStack = StackTrace.current;
      _preEnded = true;
      ready.complete();
    }
    final killer = _killer;
    if (killer != null && !_done) {
      killer(error);
    } else if (!_done && _resp != null) {
      unawaited(_detach(_resp));
    }
    _finish();
  }

  void _finish() {
    _done = true;
    if (_released) return;
    _released = true;
    _client._responses.remove(this);
    _client._conn.release();
  }
}

final _spaces = RegExp(r'\s+');

/// Future mirrors (rule 4). The extension name is import-only; never reference it.
///
/// Each reading mirror closes the response after reading: a response reached
/// only through a mirror can never be read later. [check] keeps it open.
extension ResponseFuture on Future<Response> {
  Future<T> _read<T>(T Function(Response r) read) async {
    final res = await this;
    try {
      return read(res);
    } finally {
      await res.close();
    }
  }

  Future<int> status() => _read((r) => r.status());

  Future<bool> ok() => _read((r) => r.ok());

  Future<String?> header(String name) => _read((r) => r.header(name));

  Future<String> url() => _read((r) => r.url());

  Future<int?> size() => _read((r) => r.size());

  Future<String> name() => _read((r) => r.name());

  /// `api.get(u).check().json()`.
  Future<Response> check() async => (await this).check();
}
