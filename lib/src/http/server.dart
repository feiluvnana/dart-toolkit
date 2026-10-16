// Http.serve: Server, Request, Reply.
part of '../../http.dart';

/// A running [Http.serve]. Close it to stop: until then it keeps the script
/// alive, as a server should.
final class Server implements Closeable {
  Server._(this._server, this._limit);

  final HttpServer _server;
  final int _limit;
  final _inFlight = <Future<void>>{};
  var _closed = false;

  /// Where it listens: `http://127.0.0.1:<port>/`.
  String url() => _url;

  late final String _url = () {
    final a = _server.address;
    final host = a.type == InternetAddressType.IPv6 ? '[${a.address}]' : a.address;
    return 'http://$host:${_server.port}/';
  }();

  /// Stop accepting connections and wait for the requests in flight.
  /// Idempotent.
  @override
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      await _server.close();
    }
    while (_inFlight.isNotEmpty) {
      await Future.wait([..._inFlight]);
    }
  }

  /// Bound to loopback: only loopback `Host` names are answered.
  late final bool _loopback = _server.address.isLoopback;

  static const _loopbackNames = {'127.0.0.1', 'localhost', '::1', '[::1]'};

  Future<void> _answer(HttpRequest req, FutureOr<Reply> Function(Request) handler) async {
    final res = req.response;
    try {
      Reply reply;
      final host = req.headers.host?.toLowerCase();
      if (_loopback && (host == null || !_loopbackNames.contains(host))) {
        reply = const Reply.status(421); // DNS rebinding: a page's own name pointed at us
      } else if (req.contentLength > _limit) {
        reply = const Reply.status(413);
      } else {
        final request = Request._(req, _limit);
        try {
          reply = await handler(request);
        } catch (e) {
          if (request._over) {
            reply = const Reply.status(413);
          } else {
            stderr.writeln('✗ ${req.method} ${names.redact(req.uri)}: $e'); // an OAuth code or token stays out of logs
            reply = const Reply.status(500);
          }
        }
      }
      // Encoded before the status goes out, so a value jsonEncode cannot
      // take is a logged 500, not a half-written 200.
      String? json;
      if (reply case _JsonReply(:final _value)) {
        try {
          json = jsonEncode(_value);
        } catch (e) {
          stderr.writeln('✗ ${req.method} ${names.redact(req.uri)}: $e');
          reply = const Reply.status(500);
        }
      }
      res.statusCode = reply._status;
      switch (reply) {
        case _TextReply(:final _text):
          res.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
          res.write(_text);
        case _JsonReply():
          res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
          res.write(json);
        case _StreamReply(:final _body, :final _type):
          final type = _type ?? _typeFor(_body.origin().name());
          if (type != null) res.headers.set('content-type', type);
          await res.addStream(_body.stream());
        case _RedirectReply(:final _to):
          res.headers.set('location', _to);
        case _StatusReply():
          break;
      }
    } catch (e) {
      // A body stream that fails after the headers: the status is gone,
      // so the log is the only place it shows.
      stderr.writeln('✗ ${req.method} ${names.redact(req.uri)}: $e');
      try {
        res.statusCode = 500;
      } catch (_) {}
    } finally {
      try {
        await res.close();
      } catch (_) {}
    }
  }
}

/// A request to an [Http.serve] handler: a [Reader] of its body.
final class Request with Reader {
  Request._(this._req, this._limit);

  final HttpRequest _req;
  final int _limit;
  var _over = false;

  /// `GET`, `POST` …
  String method() => _req.method;

  /// The path, `/` first, without the query.
  String path() => _req.uri.path;

  /// Query parameter [name] (the first one when repeated), or null.
  String? query(String name) => _req.uri.queryParameters[name];

  /// Request header [name] (case-insensitive), or null.
  String? header(String name) {
    final values = _req.headers[name];
    return values == null || values.isEmpty ? null : values.join(', ');
  }

  @override
  Origin origin() => Origin(url: _req.requestedUri.toString());

  /// The body; past the server's `max:` the read fails (and the
  /// handler's answer becomes a 413).
  @override
  Stream<List<int>> stream() async* {
    var n = 0;
    await for (final chunk in _req) {
      n += chunk.length;
      if (n > _limit) {
        _over = true;
        throw ContentException('request body over $_limit bytes: ${_req.method} ${names.redact(_req.uri)}');
      }
      yield chunk;
    }
  }
}

/// What an [Http.serve] handler answers.
sealed class Reply {
  const Reply._(this._status);

  final int _status;

  /// UTF-8 text.
  const factory Reply.text(String text, {int status}) = _TextReply;

  /// `jsonEncode(value)` as `application/json`.
  const factory Reply.json(Object? value, {int status}) = _JsonReply;

  /// Any [Reader] (an fs `File` sets `content-type` from its name).
  const factory Reply.stream(Reader body, {int status, String? type}) = _StreamReply;

  /// A 302 to [url].
  const factory Reply.redirect(String url) = _RedirectReply;

  /// A status with no body (`Reply.status(404)`).
  const factory Reply.status(int status) = _StatusReply;
}

final class _TextReply extends Reply {
  const _TextReply(this._text, {int status = 200}) : super._(status);
  final String _text;
}

final class _JsonReply extends Reply {
  const _JsonReply(this._value, {int status = 200}) : super._(status);
  final Object? _value;
}

final class _StreamReply extends Reply {
  const _StreamReply(this._body, {int status = 200, this._type}) : super._(status);
  final Reader _body;
  final String? _type;
}

final class _RedirectReply extends Reply {
  const _RedirectReply(this._to) : super._(302);
  final String _to;
}

final class _StatusReply extends Reply {
  const _StatusReply(super.status) : super._();
}

/// `content-type` for a file name, for the common web types.
String? _typeFor(String? name) {
  if (name == null) return null;
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  return switch (name.substring(dot + 1).toLowerCase()) {
    'html' || 'htm' => 'text/html; charset=utf-8',
    'css' => 'text/css; charset=utf-8',
    'js' || 'mjs' => 'text/javascript; charset=utf-8',
    'json' => 'application/json',
    'txt' || 'md' => 'text/plain; charset=utf-8',
    'svg' => 'image/svg+xml',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'ico' => 'image/x-icon',
    'pdf' => 'application/pdf',
    'wasm' => 'application/wasm',
    'mp4' => 'video/mp4',
    'zip' => 'application/zip',
    _ => null,
  };
}
