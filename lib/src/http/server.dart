// Http.serve: Server, Request, Reply.
part of '../../http.dart';

/// A running [Http.serve]. Close it to stop: until then it keeps the script
/// alive, as a server should.
final class Server implements Closeable {
  Server._(this._server);

  final HttpServer _server;
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

  Future<void> _answer(HttpRequest req, FutureOr<Reply> Function(Request) handler) async {
    final res = req.response;
    try {
      Reply reply;
      try {
        reply = await handler(Request._(req));
      } catch (e) {
        stderr.writeln('✗ ${req.method} ${names.redact(req.uri)}: $e'); // an OAuth code or token stays out of logs
        reply = const Reply.status(500);
      }
      res.statusCode = reply._status;
      switch (reply) {
        case _TextReply(:final _text):
          res.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
          res.write(_text);
        case _JsonReply(:final _value):
          res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
          res.write(jsonEncode(_value));
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
  Request._(this._req);

  final HttpRequest _req;

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

  @override
  Stream<List<int>> stream() => _req;
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
