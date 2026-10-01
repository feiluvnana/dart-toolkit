part of '../../http.dart';

/// HTTP requests on [Uri].
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
  Uri withQuery(Map<String, Object?> params) {
    final all = {...queryParametersAll};
    params.forEach((k, v) => v == null ? all.remove(k) : all[k] = v is Iterable ? [for (final x in v) '$x'] : ['$v']);
    return all.isEmpty ? removeQuery() : replace(queryParameters: all);
  }

  /// This URI without its query string.
  Uri removeQuery() {
    if (!hasQuery) return this;
    final s = toString();
    final q = s.indexOf('?');
    if (q < 0) return this;
    final f = s.indexOf('#', q);
    final rest = f < 0 ? '' : s.substring(f);
    return Uri.parse(s.substring(0, q) + rest);
  }

  /// GET.
  ///
  /// Awaited, it is the [Response] whatever the status; read through [Fetch.json],
  /// [Fetch.text], [Fetch.html], [Fetch.xml] or [Fetch.bytes], it throws unless 2xx:
  ///
  /// ```dart
  /// final res = await url.get();          // any status
  /// final doc = await url.get().json;     // 2xx, or HttpException: 404 Not Found
  /// ```
  Fetch get({Map<String, String>? headers}) => Request('GET', this, headers: headers).send();

  /// HEAD: the headers without the body.
  Fetch head({Map<String, String>? headers}) => Request('HEAD', this, headers: headers).send();

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
  Fetch post({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    Map<String, Path>? files,
  }) => Request('POST', this, headers: headers, text: text, bytes: bytes, form: form, json: json, files: files).send();

  /// PUT; see [post] for the body.
  Fetch put({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    Map<String, Path>? files,
  }) => Request('PUT', this, headers: headers, text: text, bytes: bytes, form: form, json: json, files: files).send();

  /// PATCH; see [post] for the body.
  Fetch patch({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    Map<String, Path>? files,
  }) => Request('PATCH', this, headers: headers, text: text, bytes: bytes, form: form, json: json, files: files).send();

  /// DELETE; see [post] for the body.
  Fetch delete({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    Map<String, Path>? files,
  }) =>
      Request('DELETE', this, headers: headers, text: text, bytes: bytes, form: form, json: json, files: files).send();

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
  /// not 2xx throws as [Fetch.json] does. Stopping the loop closes the connection.
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
