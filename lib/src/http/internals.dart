part of '../http.dart';

/// Not API: what `scrape.dart` shares with `http`, so a crawl's requests go out as every other
/// request does. Hidden from `package:dart_toolkit/http.dart`.
abstract final class HttpInternals {
  /// [url]'s origin, `scheme://host:port`: what credentials, robots.txt and per-host limits key on.
  static String origin(Uri url) => _origin(url);

  /// The settings where the caller is, as an opaque value the others take.
  static Object settings() => _settings;

  /// [request] as the scope [s] sends it: one hop when it does not follow redirects.
  static Future<StreamedResponse> exchange(Object s, Request request, {void Function(String step)? step}) =>
      _exchange(s as _Settings, request, step: step);

  /// [once] tried as [s]'s retry policy says for [request].
  static Future<R> retrying<R>(
    Object s,
    Request request,
    Future<R> Function() once, {
    void Function(String step)? step,
    void Function(Duration wait)? onWait,
  }) => _retrying(s as _Settings, request, once, step: step, onWait: onWait);

  static Retry retry(Object s) => (s as _Settings).retry;

  /// How many requests to one host [s]'s limits allow, or `null`.
  static int? perHost(Object s) => (s as _Settings).perHost;

  /// How long until [s]'s limits let a request go to [url]'s host.
  /// Runs [hear] whenever a per-host permit of [s] for [url]'s host frees; returns its stop.
  static void Function() onRoom(Object s, Uri url, void Function() hear) {
    final stops = [for (final limit in (s as _Settings).limits) limit.onRoom(url, hear)];
    return () {
      for (final stop in stops) {
        stop();
      }
    };
  }

  static Duration dueIn(Object s, Uri url) {
    var wait = Duration.zero;
    for (final limit in (s as _Settings).limits) {
      final due = limit.dueIn(url);
      if (due > wait) wait = due;
    }
    return wait;
  }

  /// The `user-agent` [s] sends: its headers', else its client's own (a browser's), else `null`.
  static Future<String?> agent(Object s) async {
    final settings = s as _Settings;
    if (settings.headers['user-agent'] case final named?) return named;
    if (settings.client case final client?) return HttpBridge.agents[client]?.call();
    return null;
  }

  static Future<StatusException> refused(StreamedResponse res, Request request) => _refused(res, request);
  static Future<void> drain(StreamedResponse res) => _drain(res);
  static Future<Uint8List> readCapped(StreamedResponse res, {required int cap, required Uri url, bool cut = false}) =>
      _readCapped(res, cap: cap, url: url, cut: cut);
  static Uri? redirect(int status, Headers headers, Uri from) => _redirect(status, headers, from);
  static Request hop(Request request, Uri to, int status) => request._hopTo(to, status);
  static String label(Uri url) => _label(url);
}
