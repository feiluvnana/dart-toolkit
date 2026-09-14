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
/// final res = await get('https://example.com'.url);
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
/// await delay(250.ms);
/// final timeout = 5.seconds;
/// final overnight = 8.hours;
/// ```
extension DurationInt on int {
  /// This many milliseconds.
  Duration get ms => Duration(milliseconds: this);

  /// This many milliseconds.
  Duration get milliseconds => Duration(milliseconds: this);

  /// This many seconds.
  Duration get s => Duration(seconds: this);

  /// This many seconds.
  Duration get seconds => Duration(seconds: this);

  /// This many minutes.
  Duration get m => Duration(minutes: this);

  /// This many minutes.
  Duration get minutes => Duration(minutes: this);

  /// This many hours.
  Duration get h => Duration(hours: this);

  /// This many hours.
  Duration get hours => Duration(hours: this);

  /// This many days.
  Duration get d => Duration(days: this);

  /// This many days.
  Duration get days => Duration(days: this);
}

/// Fluent HTTP extensions on [Uri].
extension UriHttpExtensions on Uri {
  /// Sends a GET request to this URI.
  Future<Response> get({
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => httpClient.get(
    this,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a POST request to this URI.
  Future<Response> post({
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => httpClient.post(
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
  Future<Response> put({
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => httpClient.put(
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
  Future<Response> delete({
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => httpClient.delete(
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
  Future<Response> patch({
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => httpClient.patch(
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
  Future<Response> head({
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Fetch? fetch,
  }) => httpClient.head(
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
  Json parseJson() => const JsonFormat().parse(this);

  /// Parses this string as an HTML markup cursor.
  Markup parseHtml() => const HtmlFormat().parse(this);
}

/// Direct document and selector extensions on [Response].
extension ReplyDocumentExtensions on Response {
  /// Parsed HTML markup cursor.
  Markup get html => parse(const HtmlFormat());

  /// jQuery-style selector shorthand over the parsed HTML document.
  Markup $(String selector) => html.$(selector);

  /// Returns all matching elements in the parsed HTML document as a list of [Markup] cursors.
  List<Markup> $$(String selector) => html.$$(selector);

  /// XPath selector shorthand over the parsed HTML document.
  Markup $xpath(String path) => html.$xpath(path);
}

/// Fluent HTTP extensions directly on URL strings.
extension StringHttpExtensions on String {
  /// Sends a GET request to this URL.
  Future<Response> get({
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
  Future<Response> post({
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
  Future<Response> put({
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
  Future<Response> delete({
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
  Future<Response> patch({
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
  Future<Response> head({
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
