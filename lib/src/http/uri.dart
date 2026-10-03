part of '../../http.dart';

/// A colon before any `/`, `?` or `#`, not starting `://`: an href would read it as a scheme.
final _schemeLike = RegExp(r'^[^/?#:]+:(?!//)');

/// HTTP requests on [Uri].
///
/// {@category Networking}
extension UriExtensions on Uri {
  /// Appends [part] as a path segment: `'https://x.com/api'.url / 'users'` is
  /// `https://x.com/api/users`. An absolute or `..` [part] resolves as an href would; a
  /// `projects:batchGet` stays a segment.
  Uri operator /(String part) {
    final dir = path.endsWith('/') ? this : replace(path: '$path/');
    // Appended, not resolved: a relative `./a:b` would come back as `a%3Ab`.
    return _schemeLike.hasMatch(part) ? Uri.parse('${dir.removeFragment().removeQuery()}$part') : dir.resolve(part);
  }

  /// The last non-empty path segment, decoded, as `Path.name`: `song.mp3` for
  /// `…/tracks/song.mp3?x=1`, `tracks` for `…/tracks/`, `''` for a bare host.
  String get name => pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');

  /// This URI with [params] added to its query; a `null` value removes the parameter:
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
    return Uri.parse(s.substring(0, q) + (f < 0 ? '' : s.substring(f)));
  }

  /// A canonical representation of this URI for deduplication and crawling:
  /// - Scheme and host are lowercased.
  /// - Default ports (80 for http, 443 for https) are removed.
  /// - Empty query parameters (`&&`), empty values (`key=`), and duplicate keys are cleaned.
  /// - Query parameters are sorted alphabetically by key.
  /// - Fragments (`#...`) are removed by default unless [stripFragment] is false.
  Uri canonicalize({bool stripFragment = true, bool sortQuery = true}) {
    final scheme = this.scheme.toLowerCase();
    final host = this.host.toLowerCase();
    final isDefaultPort = (scheme == 'http' && port == 80) || (scheme == 'https' && port == 443);
    final cleanPort = isDefaultPort ? null : (hasPort ? port : null);

    String? cleanQuery;
    if (hasQuery && query.isNotEmpty) {
      final parts = query.split('&').map((p) => p.trim()).where((p) => p.isNotEmpty);
      final queryMap = <String, List<String>>{};
      for (final part in parts) {
        final eq = part.indexOf('=');
        final key = eq == -1 ? part : part.substring(0, eq);
        final val = eq == -1 ? '' : part.substring(eq + 1);
        if (key.isEmpty || val.isEmpty) continue;
        final list = queryMap.putIfAbsent(key, () => []);
        if (!list.contains(val)) list.add(val);
      }
      if (queryMap.isNotEmpty) {
        final keys = queryMap.keys.toList();
        if (sortQuery) keys.sort();
        final buf = StringBuffer();
        var first = true;
        for (final k in keys) {
          for (final v in queryMap[k]!) {
            if (!first) buf.write('&');
            first = false;
            buf.write(k);
            buf.write('=');
            buf.write(v);
          }
        }
        cleanQuery = buf.toString();
      }
    }

    var result = replace(
      scheme: scheme.isEmpty ? null : scheme,
      host: host.isEmpty ? null : host,
      port: cleanPort,
      query: cleanQuery,
    );
    if (cleanQuery == null) {
      result = result.removeQuery();
    }
    if (stripFragment || fragment.isEmpty) {
      result = result.removeFragment();
    }
    return result;
  }

  /// A canonical representation of this URI with lowercased host, cleaned and sorted query
  /// parameters, default ports removed, and fragment stripped.
  Uri get canonical => canonicalize();

  /// GET. Awaited, the [Response] whatever the status; read through [Fetch], 2xx or a throw.
  ///
  /// ```dart
  /// final res = await url.get();          // any status
  /// final doc = await url.get().json;     // 2xx, or HttpException: 404 Not Found
  /// ```
  Fetch get({Map<String, String>? headers}) => Request('GET', this, headers: headers).send();

  /// HEAD: the headers without the body.
  Fetch head({Map<String, String>? headers}) => Request('HEAD', this, headers: headers).send();

  /// POST, with at most one of [text], [bytes], [form] (url-encoded), [json] or [files] and
  /// its `content-type`. [files] is `multipart/form-data` streamed off disk; with [form] it
  /// sends fields and files together.
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

  /// What this URI streams, an event at a time: server-sent events (read as the HTML
  /// standard does), or else one event per non-empty line — NDJSON, a log. [json] makes it a
  /// POST, as a streaming API is asked.
  ///
  /// ```dart
  /// await for (final e in api.events(json: {'stream': true, 'prompt': 'hi'})) {
  ///   stdout.write(e.data.json['text'].to<String>());
  /// }
  /// ```
  ///
  /// A non-2xx throws as [Fetch.json] does; stopping the loop closes the connection.
  Stream<ServerEvent> events({Map<String, String>? headers, Object? json}) =>
      _events(this, Http.client, headers: headers, json: json);

  /// Downloads this URI to [destination] (a [Path] or [String]).
  Stream<BatchDownloadProgress> download(
    Object destination, {
    Map<String, String>? headers,
    bool overwrite = false,
    bool resume = true,
    bool ifModified = false,
    (Hash algorithm, String hex)? checksum,
  }) {
    final dest = destination is Path ? destination : Path(destination.toString());
    return dest.download(
      this,
      headers: headers,
      overwrite: overwrite,
      resume: resume,
      ifModified: ifModified,
      checksum: checksum,
    );
  }
}

/// [UriExtensions.events] on [client] (the scope's when asked for), or a fresh one.
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
    // An event cut off by the end is dropped, as a browser does.
  } finally {
    lease.close();
  }
}

/// One event of [UriExtensions.events]: its name, its data, and the last `id` the stream
/// gave. A line of NDJSON is a `message` whose data is the line.
///
/// {@category Networking}
typedef ServerEvent = ({String event, String data, String? id});

/// How often a scope may refetch [request]'s broken-off body: its `retries:` if replayable.
int _replays(Request request) => switch (Http.client) {
  final _ScopeClient scope when _Retry.none(request) != true && _replayable(request.method) => scope._retries,
  _ => 0,
};

/// Whether [method] may be sent twice: a retried POST is a second order.
bool _replayable(String method) => method != 'POST' && method != 'PATCH';
