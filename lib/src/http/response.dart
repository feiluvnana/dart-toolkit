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

  /// Sends [request] through [client], the session's client, or a fresh one, and buffers the body.
  Future<Response> send(Request request, {Client? client}) async {
    final lease = _clientFor(client);
    try {
      return await (await lease.client.send(request)).read();
    } finally {
      lease.close();
    }
  }

  /// Performs an HTTP GET request to this URI.
  Future<Response> get({Map<String, String>? headers, Client? client}) =>
      send(Request('GET', this, headers: headers), client: client);

  /// Performs an HTTP POST request to this URI.
  ///
  /// [body] is a [String] (sent as UTF-8 text), a `List<int>`, or a `Map<String, String>`
  /// (sent form-encoded).
  Future<Response> post({Map<String, String>? headers, Object? body, Client? client}) {
    final request = Request('POST', this, headers: headers);
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
    return send(request, client: client);
  }

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
}
