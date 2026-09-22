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

  /// Sends [request] through the enclosing [Http.session]'s client, or a fresh one, and
  /// buffers the body.
  ///
  /// There is no `client:` argument anywhere in this module: a program that wants a
  /// particular client — a mock, a proxy, one with a timeout — says so once, by wrapping
  /// its work in [Http.session].
  Future<Response> send(Request request) async {
    final lease = _clientFor();
    try {
      return await (await lease.client.send(request)).read();
    } finally {
      lease.close();
    }
  }

  /// GET.
  Future<Response> get({Map<String, String>? headers}) => send(Request('GET', this, headers: headers));

  /// HEAD: the headers without the body.
  Future<Response> head({Map<String, String>? headers}) => send(Request('HEAD', this, headers: headers));

  /// POST. The body is named by what it is — at most one of [text] (UTF-8), [bytes],
  /// [form] (url-encoded) or [json] — and carries the matching `content-type`. The same
  /// four words name a body on [Request] and on `follow`.
  ///
  /// ```dart
  /// await api.post(json: {'name': 'x'});
  /// await api.post(form: {'q': 'dart'});
  /// ```
  Future<Response> post({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
  }) => send(Request('POST', this, headers: headers, text: text, bytes: bytes, form: form, json: json));

  /// PUT; see [post] for the body.
  Future<Response> put({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
  }) => send(Request('PUT', this, headers: headers, text: text, bytes: bytes, form: form, json: json));

  /// PATCH; see [post] for the body.
  Future<Response> patch({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
  }) => send(Request('PATCH', this, headers: headers, text: text, bytes: bytes, form: form, json: json));

  /// DELETE; see [post] for the body.
  Future<Response> delete({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
  }) => send(Request('DELETE', this, headers: headers, text: text, bytes: bytes, form: form, json: json));

  /// GETs this URI and throws [HttpException] unless the status is 2xx.
  ///
  /// `url.json()`, `url.html()` and `url.xml()` are `fetch` plus a parse; use [get] with
  /// [Response.isOk] to handle a failure yourself.
  Future<Response> fetch({Map<String, String>? headers}) async {
    final res = await get(headers: headers);
    if (!res.isOk) throw HttpException('GET failed with status ${res.statusCode}', uri: this);
    return res;
  }

  /// Fetches this URI and parses the response body as JSON; see [fetch].
  Future<JsonDocument> json({Map<String, String>? headers}) async => (await fetch(headers: headers)).json;
}
