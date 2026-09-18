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

  /// Sends [request] through [client], the session's client, or a fresh one, and buffers the body.
  Future<Response> send(Request request, {Client? client}) async {
    final lease = _clientFor(client);
    try {
      return await (await lease.client.send(request)).read();
    } finally {
      lease.close();
    }
  }

  /// GET.
  Future<Response> get({Map<String, String>? headers, Client? client}) =>
      send(Request('GET', this, headers: headers), client: client);

  /// HEAD: the headers without the body.
  Future<Response> head({Map<String, String>? headers, Client? client}) =>
      send(Request('HEAD', this, headers: headers), client: client);

  /// POST. [body] is a [String] (UTF-8 text), a `List<int>`, or a `Map<String, String>`
  /// (form-encoded); [json] is any JSON-encodable value, sent as `application/json`.
  Future<Response> post({Map<String, String>? headers, Object? body, Object? json, Client? client}) =>
      send(_withBody('POST', headers, body, json), client: client);

  /// PUT; see [post] for [body] and [json].
  Future<Response> put({Map<String, String>? headers, Object? body, Object? json, Client? client}) =>
      send(_withBody('PUT', headers, body, json), client: client);

  /// PATCH; see [post] for [body] and [json].
  Future<Response> patch({Map<String, String>? headers, Object? body, Object? json, Client? client}) =>
      send(_withBody('PATCH', headers, body, json), client: client);

  /// DELETE; see [post] for [body] and [json].
  Future<Response> delete({Map<String, String>? headers, Object? body, Object? json, Client? client}) =>
      send(_withBody('DELETE', headers, body, json), client: client);

  /// GETs this URI and throws [HttpException] unless the status is 2xx.
  ///
  /// `url.json()`, `url.html()` and `url.xml()` are `fetch` plus a parse; use [get] with
  /// [Response.isOk] to handle a failure yourself.
  Future<Response> fetch({Map<String, String>? headers, Client? client}) async {
    final res = await get(headers: headers, client: client);
    if (!res.isOk) throw HttpException('GET failed with status ${res.statusCode}', uri: this);
    return res;
  }

  /// Fetches this URI and parses the response body as JSON; see [fetch].
  Future<JsonDocument> json({Map<String, String>? headers, Client? client}) async =>
      (await fetch(headers: headers, client: client)).json;

  Request _withBody(String method, Map<String, String>? headers, Object? body, Object? json) {
    if (body != null && json != null) throw ArgumentError('Pass at most one of "body" and "json".');
    final request = Request(method, this, headers: headers);
    if (json != null) {
      request.bytes = utf8.encode(jsonEncode(json));
      request.headers.putIfAbsent('content-type', () => 'application/json; charset=utf-8');
      return request;
    }
    switch (body) {
      case null:
        break;
      case String():
        request.text = body;
      case List<int>():
        request.bytes = Uint8List.fromList(body);
      case Map<String, String>():
        request.fields = body;
      default:
        throw ArgumentError.value(body, 'body', 'Must be a String, a List<int> or a Map<String, String>');
    }
    return request;
  }
}
