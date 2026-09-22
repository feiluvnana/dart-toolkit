part of '../../http.dart';

/// The same verbs [UriExtensions] puts on a `Uri`, on a client you are holding.
///
/// [Http.scope] is how a client reaches code that has no client to hand — a download deep
/// in a call chain, a crawl assembled somewhere else. This is the other case: the client is
/// right there, and saying so is shorter than opening a scope around one call.
///
/// ```dart
/// final chrome = await ChromeClient.connect();
///
/// await chrome.get(url);                       // the page, rendered
/// await chrome.page(url, (p) => p.click('.dl'));  // the tab, live
/// ```
///
/// The difference that matters is not brevity. A scope holds a [Client], and a `Client` is
/// `send` and `close` — so through a scope, everything a particular client can do *beyond*
/// the seam is invisible. Held, it is the receiver, and [ChromeClient.page] sits beside
/// [get] with the compiler deciding whether it exists. Nothing probes, nothing casts, and
/// nothing throws at runtime for asking a socket to click a button.
///
/// Calls nested inside one of these reuse the same client, so a hook that fetches a detail
/// page opens no connection of its own.
///
/// {@category Networking}
extension ClientExtensions on Client {
  /// Sends [request] through this client and buffers the body.
  ///
  /// The request is copied before it goes out; see [UriExtensions.send].
  Future<Response> fire(Request request) => _withClient(this, () => request.url.send(request));

  /// GET.
  Future<Response> get(Uri url, {Map<String, String>? headers}) => _withClient(this, () => url.get(headers: headers));

  /// HEAD: the headers without the body.
  Future<Response> head(Uri url, {Map<String, String>? headers}) => _withClient(this, () => url.head(headers: headers));

  /// POST; see [UriExtensions.post] for the body.
  Future<Response> post(
    Uri url, {
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
  }) => _withClient(this, () => url.post(headers: headers, text: text, bytes: bytes, form: form, json: json));

  /// PUT; see [UriExtensions.post] for the body.
  Future<Response> put(
    Uri url, {
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
  }) => _withClient(this, () => url.put(headers: headers, text: text, bytes: bytes, form: form, json: json));

  /// PATCH; see [UriExtensions.post] for the body.
  Future<Response> patch(
    Uri url, {
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
  }) => _withClient(this, () => url.patch(headers: headers, text: text, bytes: bytes, form: form, json: json));

  /// DELETE; see [UriExtensions.post] for the body.
  Future<Response> delete(
    Uri url, {
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
  }) => _withClient(this, () => url.delete(headers: headers, text: text, bytes: bytes, form: form, json: json));

  /// GETs [url] and throws [HttpException] unless the status is 2xx.
  Future<Response> fetch(Uri url, {Map<String, String>? headers}) =>
      _withClient(this, () => url.fetch(headers: headers));

  /// [fetch], parsed as JSON.
  Future<JsonDocument> json(Uri url, {Map<String, String>? headers}) =>
      _withClient(this, () => url.json(headers: headers));

  /// [fetch], parsed as HTML.
  Future<HtmlDocument> html(Uri url, {Map<String, String>? headers}) =>
      _withClient(this, () => url.html(headers: headers));

  /// [fetch], parsed as XML.
  Future<XmlDocument> xml(Uri url, {Map<String, String>? headers}) =>
      _withClient(this, () => url.xml(headers: headers));

  /// A crawl seeded at [url], running on this client.
  ///
  /// Unlike the verbs, this one cannot go through the zone: a [Scrape] is lazy, and its
  /// engine starts in whichever zone finally listens to it. The client is carried on the
  /// crawl instead, so the stream may be built here and consumed anywhere.
  Scrape<T> scrape<T>(Uri url) => Scrape<T>._of([Request('GET', url.removeFragment())], client: this);

  /// A crawl seeded with [requests] — any method, body or headers — running on this client.
  Scrape<T> crawl<T>(Iterable<Request> requests) => Scrape<T>._of(requests, client: this);
}
