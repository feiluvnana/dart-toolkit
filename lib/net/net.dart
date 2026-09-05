import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http_lib;

import 'crawl.dart';
import 'http.dart' as http_module;

export 'crawl.dart';
export 'downloader.dart';
export 'engine.dart';
export 'http.dart';
export 'pipeline.dart';
export 'selector.dart';

// ============================================================================
// NET DOMAIN (net.*) - HTTP Requests, Web Scraping, Crawler Engine & Selectors
// ============================================================================

final http_module.HttpAccessor _netHttp = http_module.HttpAccessor();

/// Top-level Network & Web accessor singleton (`net.*`).
///
/// Provides unified access to HTTP requests, streaming downloads, web crawling, and DOM selectors.
///
/// ```dart
/// // Quick HTTP requests
/// final res = await net.get('https://example.com');
///
/// // Web crawling & scraping
/// await net.crawl('https://example.com').run((res) {
///   print(res.text);
/// });
///
/// // CSS selector query
/// final title = net.$('h1', html).text;
/// ```
const NetAccessor net = NetAccessor();

/// Top-level Network and Web domain accessor.
class NetAccessor {
  const NetAccessor();

  /// Sub-namespace for HTTP client and request operations (`net.http.*`).
  http_module.HttpAccessor get http => _netHttp;

  /// Sub-namespace for web scraping and crawler workflows (`net.crawl.*`).
  Crawl get crawl => const Crawl();

  /// Queries an HTML document, element, or string using a CSS selector (`net.$(...)`).
  QueryResult $(Object? target, [Object? context]) =>
      query(target, context);

  /// Queries an HTML document, element, or string using a CSS selector (`net.query(...)`).
  QueryResult query(Object? target, [Object? context]) =>
      crawl.query(target, context);

  // --- Forwarded HTTP methods for direct net.* access ---

  /// Performs an HTTP GET request (1-word).
  Future<http_module.HttpResponse> get(
    Object url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) => _netHttp.get(
    url,
    headers: headers,
    timeout: timeout,
  );

  /// Performs an HTTP POST request (1-word).
  Future<http_module.HttpResponse> post(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) => _netHttp.post(
    url,
    body: body,
    headers: headers,
    timeout: timeout,
  );

  /// Performs an HTTP PUT request (1-word).
  Future<http_module.HttpResponse> put(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) => _netHttp.put(url, body: body, headers: headers, timeout: timeout);

  /// Performs an HTTP DELETE request (1-word).
  Future<http_module.HttpResponse> delete(
    Object url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) => _netHttp.delete(url, headers: headers, timeout: timeout);

  /// Performs an HTTP PATCH request (1-word).
  Future<http_module.HttpResponse> patch(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) => _netHttp.patch(url, body: body, headers: headers, timeout: timeout);

  /// Performs an HTTP HEAD request (1-word).
  Future<http_module.HttpResponse> head(
    Object url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) => _netHttp.head(url, headers: headers, timeout: timeout);

  /// Downloads a remote [url] and streams it directly to local [dest] (1-word).
  Future<File> download(
    Object url,
    Object dest, {
    Map<String, String>? headers,
    void Function(int received, int total)? onProgress,
    String part = '.part',
    bool match = true,
  }) => _netHttp.download(
    url,
    dest,
    headers: headers,
    onProgress: onProgress,
    part: part,
    match: match,
  );

  /// Concurrently synchronizes a batch of asset download tasks (1-word).
  Future<void> sync(
    Object tasks, {
    String? base,
    String? prefix,
    int concurrency = 4,
    bool match = true,
  }) => _netHttp.sync(
    tasks,
    base: base,
    prefix: prefix,
    concurrency: concurrency,
    match: match,
  );

  /// Creates a configured standalone [HttpClient] (1-word).
  http_module.HttpClient client({
    http_lib.Client? client,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 30),
    int retries = 2,
    Duration backoff = const Duration(milliseconds: 500),
    String? base,
  }) => _netHttp.client(
    client: client,
    headers: headers,
    timeout: timeout,
    retries: retries,
    backoff: backoff,
    base: base,
  );
}
