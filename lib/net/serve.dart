/// # Serving (`net.serve`, `net.once`)
///
/// The mirror image of the client half of `net`: something that listens. Three
/// ordinary script jobs need one — catching an OAuth redirect, receiving a
/// webhook, and previewing what was just scraped — and all three otherwise
/// mean `dart:io`'s `HttpServer` and a hand-rolled request switch.
///
/// ```dart
/// final server = await net.serve(8080, (req) async {
///   return switch (req.path) {
///     '/callback' => Served.text(req.query['code'] ?? ''),
///     '/health' => Served.json({'ok': true}),
///     _ => Served.status(404),
///   };
/// });
/// await server.close();
/// ```
///
/// Deliberately not here: routing with path parameters, middleware,
/// static-directory serving beyond [Served.file], HTTPS and WebSockets. Each
/// is the first step towards a web framework, and this is a scraping toolkit
/// that needs to catch a redirect.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../src/jsontext.dart';
import '../util/json.dart';
import 'http.dart';

// ============================================================================
// SERVING (net.serve / net.once)
// ============================================================================

/// One incoming request.
///
/// Named `Asked` rather than `Request` because 2.0.0 spent that name once
/// already and renamed out of it: a type called `Request` sitting beside
/// `package:http`'s and `dart:io`'s is the shadow that made `HttpClient` a bug
/// rather than a compile error.
final class Asked {
  final HttpRequest _raw;
  List<int>? _bytes;

  Asked._(this._raw);

  /// The full URL as requested, including the query string.
  Uri get url => _raw.requestedUri;

  /// The path portion of [url], always starting with `/`.
  String get path => _raw.uri.path;

  /// The query parameters, later duplicates winning.
  Map<String, String> get query => _raw.uri.queryParameters;

  /// The request headers, lowercased, joined with `, ` when repeated.
  Map<String, String> get headers {
    final out = <String, String>{};
    _raw.headers.forEach((name, values) {
      out[name.toLowerCase()] = values.join(', ');
    });
    return out;
  }

  /// The method, or [HttpMethod.get] for one this library does not name.
  HttpMethod get method {
    final wire = _raw.method.toUpperCase();
    for (final candidate in HttpMethod.values) {
      if (candidate.wire == wire) return candidate;
    }
    return HttpMethod.get;
  }

  /// The request body as raw bytes. Cached, so repeat reads are free.
  Future<List<int>> bytes() async {
    if (_bytes case final cached?) return cached;
    final chunks = <int>[];
    await for (final chunk in _raw) {
      chunks.addAll(chunk);
    }
    return _bytes = chunks;
  }

  /// The request body decoded as UTF-8 text.
  Future<String> text() async =>
      utf8.decode(await bytes(), allowMalformed: true);

  /// The request body as a [Json] cursor.
  ///
  /// A body that is not JSON reads as the empty cursor rather than throwing,
  /// which is what a webhook receiver wants: a malformed POST is a `400` to
  /// return, not an exception to catch.
  Future<Json> json() async => Json(JsonText.decode(await text()));

  @override
  String toString() => 'Asked(${method.wire} $path)';
}

/// One outgoing reply.
///
/// Every constructor names the shape of the answer, so a handler says what it
/// is returning rather than assembling headers:
///
/// ```dart
/// Served.text('done');
/// Served.json({'ok': true});
/// Served.file('output/report.html');
/// Served.status(404);
/// Served.redirect('/done'.url);
/// ```
final class Served {
  /// The HTTP status code.
  final int status;

  /// Extra response headers, on top of the content type this reply implies.
  final Map<String, String> headers;

  final String? _text;
  final List<int>? _bytes;
  final String? _file;
  final String? _type;

  const Served._({
    required this.status,
    this.headers = const {},
    String? text,
    List<int>? bytes,
    String? file,
    String? type,
  }) : _text = text,
       _bytes = bytes,
       _file = file,
       _type = type;

  /// A text reply, `text/plain` unless [type] says otherwise.
  ///
  /// Pass `type: 'text/html; charset=utf-8'` for a page — there is no
  /// `Served.html`, because one argument is cheaper than a second name.
  const Served.text(
    String text, {
    int status = 200,
    String type = 'text/plain; charset=utf-8',
    Map<String, String> headers = const {},
  }) : this._(status: status, headers: headers, text: text, type: type);

  /// A JSON reply, encoded from [data].
  Served.json(
    Object? data, {
    int status = 200,
    Map<String, String> headers = const {},
  }) : this._(
         status: status,
         headers: headers,
         text: JsonText.encode(data, indent: 0),
         type: 'application/json; charset=utf-8',
       );

  /// A raw byte reply.
  const Served.bytes(
    List<int> data, {
    int status = 200,
    String type = 'application/octet-stream',
    Map<String, String> headers = const {},
  }) : this._(status: status, headers: headers, bytes: data, type: type);

  /// The file at [path], streamed, with a content type guessed from its
  /// extension.
  ///
  /// A missing file replies `404`, so previewing a directory that has not been
  /// written yet is a status rather than a crash.
  const Served.file(
    String path, {
    int status = 200,
    String? type,
    Map<String, String> headers = const {},
  }) : this._(status: status, headers: headers, file: path, type: type);

  /// A bare status code, with the standard reason phrase as its body.
  const Served.status(int status, {Map<String, String> headers = const {}})
    : this._(
        status: status,
        headers: headers,
        type: 'text/plain; charset=utf-8',
      );

  /// A redirect to [location].
  ///
  /// `302` by default; pass `status: 301` for a permanent one. A relative
  /// reference is as valid a `Location` as an absolute one, so
  /// `Served.redirect('/done'.url)` is the ordinary case.
  ///
  /// Took a `String` through 4.0.0, which Rule 6 opens by forbidding: URLs are
  /// `Uri`, and `.url` exists so that costs six characters.
  Served.redirect(
    Uri location, {
    int status = 302,
    Map<String, String> headers = const {},
  }) : this._(status: status, headers: {'location': '$location', ...headers});

  static const _types = {
    '.html': 'text/html; charset=utf-8',
    '.htm': 'text/html; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.csv': 'text/csv; charset=utf-8',
    '.txt': 'text/plain; charset=utf-8',
    '.xml': 'application/xml; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.pdf': 'application/pdf',
    '.zip': 'application/zip',
  };

  Future<void> _writeTo(HttpResponse out) async {
    final file = _file;
    if (file != null && !File(file).existsSync()) {
      await const Served.status(404)._writeTo(out);
      return;
    }

    out.statusCode = status;
    final type =
        _type ??
        (file == null
            ? 'text/plain; charset=utf-8'
            : _types[p.extension(file).toLowerCase()] ??
                  'application/octet-stream');
    out.headers.set(HttpHeaders.contentTypeHeader, type);
    for (final entry in headers.entries) {
      out.headers.set(entry.key, entry.value);
    }

    if (file != null) {
      await out.addStream(File(file).openRead());
    } else if (_bytes case final bytes?) {
      out.add(bytes);
    } else {
      out.write(_text ?? _reason(status));
    }
    await out.close();
  }

  static String _reason(int status) => switch (status) {
    200 => 'OK',
    201 => 'Created',
    204 => '',
    400 => 'Bad Request',
    401 => 'Unauthorized',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    409 => 'Conflict',
    429 => 'Too Many Requests',
    500 => 'Internal Server Error',
    503 => 'Service Unavailable',
    _ => '$status',
  };

  @override
  String toString() => 'Served($status)';
}

/// A listening server, handed back by `net.serve`.
///
/// Holds the socket open until [close], so a script that serves and then does
/// nothing else stays alive — which is the point for a webhook receiver and a
/// trap for everything else.
final class Server {
  final HttpServer _raw;

  /// The port actually bound.
  ///
  /// Worth reading when the request was port `0`, which asks the OS to pick a
  /// free one — what a test wants, and what an OAuth callback on a machine
  /// with something already on `8080` wants too.
  ///
  /// Read once at bind and kept, so it still answers after [close] — the
  /// underlying socket throws once it is unbound, and a script logging where
  /// it *was* listening should not be the thing that crashes.
  final int port;

  /// The address bound, as given to `net.serve`.
  final String host;

  Server._(this._raw) : port = _raw.port, host = _raw.address.host;

  /// Stops listening.
  ///
  /// Waits for in-flight requests to finish unless [force] is set.
  Future<void> close({bool force = false}) => _raw.close(force: force);

  @override
  String toString() => 'Server($host:$port)';
}

/// Binds [port] and answers every request with [handler].
///
/// See `net.serve`, which is how a script reaches this. [sent] runs once each
/// reply has been flushed, which is what lets [onceOn] close only after its
/// answer has actually reached the client.
Future<Server> serveOn(
  int port,
  FutureOr<Served> Function(Asked req) handler, {
  String host = 'localhost',
  void Function()? sent,
}) async {
  final raw = await HttpServer.bind(host, port);
  raw.listen((request) async {
    Served reply;
    try {
      reply = await handler(Asked._(request));
    } catch (_) {
      // A handler that throws is a 500, not a dead socket: the client is
      // waiting and a hung request is harder to debug than a status.
      reply = const Served.status(500);
    }
    try {
      await reply._writeTo(request.response);
    } catch (_) {
      // The client hung up mid-write. Nothing left to say to it.
    }
    sent?.call();
  }, onError: (Object _) {});
  return Server._(raw);
}

/// Serves [port] until [handler] returns a value, then replies and closes.
///
/// See `net.once`, which is how a script reaches this.
Future<R?> onceOn<R extends Object>(
  int port,
  FutureOr<R?> Function(Asked req) handler, {
  String host = 'localhost',
  Served reply = const Served.text('Done. You can close this tab.'),
  Duration? timeout,
}) async {
  final delivered = Completer<void>();
  R? found;

  // The answer is not "done" the moment the handler produces it — the reply
  // still has to reach the browser waiting on the redirect. Closing on the
  // handler's return raced that write, and the tab saw a refused connection,
  // so the wait ends on `sent`, once the reply has been flushed.
  final server = await serveOn(
    port,
    (req) async {
      if (found != null) return const Served.status(404);
      final value = await handler(req);
      if (value == null) return const Served.status(404);
      found = value;
      return reply;
    },
    host: host,
    sent: () {
      if (found != null && !delivered.isCompleted) delivered.complete();
    },
  );

  Timer? clock;
  if (timeout != null) {
    clock = Timer(timeout, () {
      if (!delivered.isCompleted) delivered.complete();
    });
  }
  try {
    await delivered.future;
    return found;
  } finally {
    clock?.cancel();
    await server.close(force: true);
  }
}
