part of '../../http.dart';

/// HTTP requests and JSON on [Uri].
///
/// {@category Networking}
extension UriExtensions on Uri {
  /// Appends [part] as a path segment, treating this URI as a directory.
  ///
  /// `'https://x.com/api'.url / 'users'` is `https://x.com/api/users`. An absolute or
  /// `..` [part] still resolves as an href would.
  Uri operator /(String part) => (path.endsWith('/') ? this : replace(path: '$path/')).resolve(part);

  /// This URI with [params] added to its query; a `null` value removes the parameter.
  ///
  /// `url.withQuery({'page': 2, 'q': 'dart'})`.
  Uri withQuery(Map<String, Object?> params) => replace(
    queryParameters: {
      ...queryParameters,
      for (final MapEntry(:key, :value) in params.entries)
        if (value != null) key: '$value',
    }..removeWhere((k, _) => params.containsKey(k) && params[k] == null),
  );

  /// Sends [request] through the enclosing [Http.scope]'s client, or a fresh one, and
  /// buffers the body.
  ///
  /// A program that wants a particular client — a mock, a proxy, one with a timeout — says
  /// so once by wrapping its work in [Http.scope], or holds the client and calls
  /// [ClientExtensions.get] and its siblings on it.
  ///
  /// [request] is copied before it goes out, so the caller's object comes back untouched
  /// and sending it twice sends it twice — a scope stamps its `cookie` and default headers
  /// onto what it sends, and without the copy the second send would carry the first send's
  /// jar and skip the refresh. [Response.request] is the copy that went on the wire.
  ///
  /// Inside `Http.scope(retries:)`, a body cut off half-way is fetched again like any other
  /// transport failure — for a method that may be sent twice; see [Http.scope].
  Future<Response> send(Request request) async {
    final lease = _clientFor();
    final budget = _replays(request);
    try {
      for (var attempt = 0; ; attempt++) {
        // The send retries its own failures; what is left to this loop is the body.
        final res = await lease.client.send(request.copy());
        try {
          return await res.read();
        } catch (e) {
          if (attempt >= budget || !_transient(e) || Cancel.isCancelled) rethrow;
          await _sleep((200 * (attempt + 1)).ms);
        }
      }
    } finally {
      lease.close();
    }
  }

  /// GET.
  Future<Response> get({Map<String, String>? headers}) => send(Request('GET', this, headers: headers));

  /// HEAD: the headers without the body.
  Future<Response> head({Map<String, String>? headers}) => send(Request('HEAD', this, headers: headers));

  /// POST. The body is named by what it is — at most one of [text] (UTF-8), [bytes],
  /// [form] (url-encoded), [json] or [files] — and carries the matching `content-type`. The
  /// same words name a body on [Request] and on `follow`.
  ///
  /// [files] is `multipart/form-data`, read off disk as it goes out and never held, so the
  /// size of an upload is not the size of the program's heap. It is the one that pairs: with
  /// [form] it sends the fields and the files together, which is a browser submitting a form
  /// that has a file input on it.
  ///
  /// ```dart
  /// await api.post(json: {'name': 'x'});
  /// await api.post(form: {'q': 'dart'});
  /// await api.post(form: {'title': 'holiday'}, files: {'photo': '~/beach.jpg'.path});
  /// ```
  Future<Response> post({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    Map<String, Path>? files,
  }) => send(Request('POST', this, headers: headers, text: text, bytes: bytes, form: form, json: json, files: files));

  /// PUT; see [post] for the body.
  Future<Response> put({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    Map<String, Path>? files,
  }) => send(Request('PUT', this, headers: headers, text: text, bytes: bytes, form: form, json: json, files: files));

  /// PATCH; see [post] for the body.
  Future<Response> patch({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    Map<String, Path>? files,
  }) => send(Request('PATCH', this, headers: headers, text: text, bytes: bytes, form: form, json: json, files: files));

  /// DELETE; see [post] for the body.
  Future<Response> delete({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    Map<String, Path>? files,
  }) => send(Request('DELETE', this, headers: headers, text: text, bytes: bytes, form: form, json: json, files: files));

  /// GETs this URI and throws [HttpException] unless the status is 2xx.
  ///
  /// `url.json()`, `url.html()` and `url.xml()` are `fetch` plus a parse; use [get] with
  /// [Response.isOk] to handle a failure yourself.
  ///
  /// The exception reads as the status line does — `404 Not Found` — and carries this URI,
  /// so a script that lets it reach `Cli.run` has already reported the failure.
  Future<Response> fetch({Map<String, String>? headers}) async {
    final res = await get(headers: headers);
    if (!res.isOk) throw HttpException(_status(res.statusCode, res.reasonPhrase), uri: this);
    return res;
  }

  /// Fetches this URI and parses the response body as JSON; see [fetch].
  Future<JsonDocument> json({Map<String, String>? headers}) async => (await fetch(headers: headers)).json;

  /// What this URI streams, an event at a time: server-sent events, or anything else a line
  /// at a time — NDJSON, a log.
  ///
  /// A `text/event-stream` is read as the HTML standard reads one: `data:` lines joined by
  /// newlines, `event:` defaulting to `message`, `id:` kept until the next one, comments
  /// skipped. Any other body is one event per non-empty line. Giving [json] makes it a POST
  /// with that body, which is how a streaming API is asked.
  ///
  /// ```dart
  /// await for (final e in api.events(json: {'stream': true, 'prompt': 'hi'})) {
  ///   stdout.write(e.data.json['text'].to<String>());
  /// }
  /// ```
  ///
  /// It goes through the scope's client, so its headers and timeout apply; a status that is
  /// not 2xx throws as [fetch] does. Stopping the loop closes the connection.
  Stream<ServerEvent> events({Map<String, String>? headers, Object? json}) =>
      _events(this, Http.client, headers: headers, json: json);
}

/// [UriExtensions.events] on [client] — the scope's, taken when the stream was asked for
/// rather than wherever it is listened to — or on a fresh one of its own when `null`.
Stream<ServerEvent> _events(Uri url, Client? client, {Map<String, String>? headers, Object? json}) async* {
  final request = Request(json == null ? 'GET' : 'POST', url, headers: headers, json: json);
  request.headers.putIfAbsent('accept', () => 'text/event-stream');
  final lease = client == null ? _ClientLease(IoClient(), true) : _ClientLease(client, false);
  try {
    final res = await lease.client.send(request);
    if (!res.isOk) {
      unawaited(_drain(res));
      throw HttpException(_status(res.statusCode, res.reasonPhrase), uri: url);
    }
    final lines = res.stream.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter());
    if (!(res.headers['content-type'] ?? '').toLowerCase().startsWith('text/event-stream')) {
      await for (final line in lines) {
        if (line.trim().isNotEmpty) yield (event: 'message', data: line, id: null);
      }
      return;
    }
    var event = 'message';
    String? id;
    final data = StringBuffer();
    var pending = false;
    await for (final line in lines) {
      if (line.isEmpty) {
        if (pending) yield (event: event, data: data.toString(), id: id);
        event = 'message';
        data.clear();
        pending = false;
        continue;
      }
      if (line.startsWith(':')) continue;
      final colon = line.indexOf(':');
      final field = colon == -1 ? line : line.substring(0, colon);
      var value = colon == -1 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'data':
          if (pending) data.write('\n');
          data.write(value);
          pending = true;
        case 'event':
          event = value.isEmpty ? 'message' : value;
        case 'id' when !value.contains('\u0000'):
          id = value;
      }
    }
    // An event the stream ended in the middle of is not dispatched, as a browser drops it.
  } finally {
    lease.close();
  }
}

/// One event of [UriExtensions.events]: its name, its data, and the last `id` the stream
/// gave. A line of NDJSON is a `message` whose data is the line.
///
/// {@category Networking}
typedef ServerEvent = ({String event, String data, String? id});

/// How many times a scope may fetch [request]'s body again after it breaks off, which is the
/// scope's `retries:` for a method that may be sent twice and none for one that may not.
int _replays(Request request) => switch (Http.client) {
  final _ScopeClient scope when _Retry.none(request) != true && _replayable(request.method) => scope._retries,
  _ => 0,
};

/// Whether sending a [method] twice is what sending it once is. POST and PATCH are not: a
/// retried POST is a second order.
bool _replayable(String method) => method != 'POST' && method != 'PATCH';
