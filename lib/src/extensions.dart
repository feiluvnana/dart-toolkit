/// # Shared Extensions
///
/// Small extensions that let the strongly-typed APIs in this library stay
/// concise at the call site. Every public signature takes a real type — a
/// [Uri], a [Duration], a `String` path — and these extensions make producing
/// one a few characters rather than a full constructor call.
library;

import 'dart:convert';

import '../format/format.dart';
import '../net/net.dart';
import '../src/json.dart';
import '../src/markup.dart';

/// Turns a URL string into a [Uri].
///
/// Every networking entry point in this library takes a [Uri], matching
/// `package:http`. This keeps call sites short:
///
/// ```dart
/// final res = await net.http.send(.get, 'https://example.com'.url);
/// ```
extension UrlString on String {
  /// Parses this string as a [Uri].
  ///
  /// Throws [FormatException] if the string is not a valid URI.
  Uri get url => Uri.parse(this);
}

/// Builds a [Duration] from a plain number.
///
/// Delays and timeouts are always typed as [Duration]; these getters keep
/// them readable:
///
/// ```dart
/// await util.time.wait(250.ms);
/// net.crawl([Fetch('https://example.com'.url)].seq).delay(2.s);
/// final overnight = 8.h;
/// ```
extension DurationInt on int {
  /// This many milliseconds.
  Duration get ms => Duration(milliseconds: this);

  /// This many seconds.
  Duration get s => Duration(seconds: this);

  /// This many minutes.
  Duration get m => Duration(minutes: this);

  /// This many hours.
  Duration get h => Duration(hours: this);

  /// This many days.
  Duration get d => Duration(days: this);
}

/// Fluent HTTP extensions on [Uri].
extension UriHttpExtensions on Uri {
  /// Sends a GET request to this URI.
  Future<Reply> get({
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => net.http.get(
    this,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a POST request to this URI.
  Future<Reply> post({
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => net.http.post(
    this,
    body: body,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a PUT request to this URI.
  Future<Reply> put({
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => net.http.put(
    this,
    body: body,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a DELETE request to this URI.
  Future<Reply> delete({
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => net.http.delete(
    this,
    body: body,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a PATCH request to this URI.
  Future<Reply> patch({
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => net.http.patch(
    this,
    body: body,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a HEAD request to this URI.
  Future<Reply> head({
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Fetch? fetch,
  }) => net.http.head(
    this,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    fetch: fetch,
  );
}

/// Quick document parsing extensions on [String].
extension StringParseExtensions on String {
  /// Parses this string as a JSON document cursor.
  Json parseJson() => format.json.parse(this);

  /// Parses this string as an HTML markup cursor.
  Markup parseHtml() => format.html.parse(this);
}

/// Direct document and selector extensions on [Reply].
extension ReplyDocumentExtensions on Reply {
  /// Parsed HTML markup cursor.
  Markup get html => parse(format.html);

  /// jQuery-style selector shorthand over the parsed HTML document.
  Markup $(String selector) => html.$(selector);

  /// XPath selector shorthand over the parsed HTML document.
  Markup $xpath(String path) => html.$xpath(path);
}

/// Fluent HTTP extensions directly on URL strings.
extension StringHttpExtensions on String {
  /// Sends a GET request to this URL.
  Future<Reply> get({
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => url.get(
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a POST request to this URL.
  Future<Reply> post({
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => url.post(
    body: body,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a PUT request to this URL.
  Future<Reply> put({
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => url.put(
    body: body,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a DELETE request to this URL.
  Future<Reply> delete({
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => url.delete(
    body: body,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a PATCH request to this URL.
  Future<Reply> patch({
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => url.patch(
    body: body,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a HEAD request to this URL.
  Future<Reply> head({
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Fetch? fetch,
  }) => url.head(
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    fetch: fetch,
  );
}
