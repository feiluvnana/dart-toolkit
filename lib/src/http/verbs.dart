part of '../../http.dart';

/// The verbs of [UriExtensions], on a client you are holding — shorter than a scope around
/// one call, and the compiler sees what that client can do beyond the seam.
///
/// ```dart
/// final chrome = await ChromeClient.launch();    // package:dart_toolkit/chrome.dart
///
/// await chrome.get(url);                       // the page, rendered
/// await chrome.page(url, (p) => p.click('.dl'));  // the tab, live
/// ```
///
/// Calls nested inside one of these reuse the same client.
///
/// {@category Networking}
extension ClientExtensions on Client {
  /// Sends a copy of [request] through this client and buffers the body.
  Fetch fire(Request request) => _withClient(this, request.send);

  /// GET.
  Fetch get(Uri url, {Map<String, String>? headers}) => _withClient(this, () => url.get(headers: headers));

  /// HEAD: the headers without the body.
  Fetch head(Uri url, {Map<String, String>? headers}) => _withClient(this, () => url.head(headers: headers));

  /// POST; see [UriExtensions.post] for the body.
  Fetch post(
    Uri url, {
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    Map<String, Path>? files,
  }) => _withClient(
    this,
    () => url.post(headers: headers, text: text, bytes: bytes, form: form, json: json, files: files),
  );

  /// PUT; see [UriExtensions.post] for the body.
  Fetch put(
    Uri url, {
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    Map<String, Path>? files,
  }) => _withClient(
    this,
    () => url.put(headers: headers, text: text, bytes: bytes, form: form, json: json, files: files),
  );

  /// PATCH; see [UriExtensions.post] for the body.
  Fetch patch(
    Uri url, {
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    Map<String, Path>? files,
  }) => _withClient(
    this,
    () => url.patch(headers: headers, text: text, bytes: bytes, form: form, json: json, files: files),
  );

  /// DELETE; see [UriExtensions.post] for the body.
  Fetch delete(
    Uri url, {
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    Map<String, Path>? files,
  }) => _withClient(
    this,
    () => url.delete(headers: headers, text: text, bytes: bytes, form: form, json: json, files: files),
  );

  /// What [url] streams, an event at a time; see [UriExtensions.events].
  Stream<ServerEvent> events(Uri url, {Map<String, String>? headers, Object? json}) =>
      _events(url, this, headers: headers, json: json);

  /// Downloads [url] to [destination] (a [Path] or [String]) through this client.
  Stream<BatchDownloadProgress> download(
    Uri url,
    Object destination, {
    Map<String, String>? headers,
    bool overwrite = false,
    bool resume = true,
    bool ifModified = false,
    (Hash algorithm, String hex)? checksum,
  }) => _withClient(
    this,
    () => (destination is Path ? destination : Path(destination.toString())).download(
      url,
      headers: headers,
      overwrite: overwrite,
      resume: resume,
      ifModified: ifModified,
      checksum: checksum,
    ),
  );

  /// A crawl on this client, seeded with a [Uri], an `Iterable<Uri>` or an
  /// `Iterable<Request>`. The client rides on the crawl rather than the zone, since a
  /// [Scrape] starts wherever it is listened to.
  Scrape<T> scrape<T>(Object seeds) => Scrape<T>._of(switch (seeds) {
    Uri() => [Request('GET', _page(seeds))],
    Iterable<Request>() => seeds,
    Iterable<Uri>() => [for (final url in seeds) Request('GET', _page(url))],
    _ => throw ArgumentError.value(seeds, 'seeds', 'Must be a Uri, an Iterable<Uri> or an Iterable<Request>'),
  }, client: this);
}
