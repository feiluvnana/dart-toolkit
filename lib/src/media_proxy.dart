/// `Video.open(headers:)`: ffmpeg fetches a URL through a loopback proxy
/// that adds the headers only for the source's own origins, so cookies and
/// tokens never sit in argv or reach another host.
///
/// HLS and DASH manifests are rewritten on the way so their same-origin
/// URLs come back through the proxy; other hosts, and redirects to them, are
/// fetched by ffmpeg directly, without the headers. The proxy lives for one
/// ffmpeg or ffprobe run.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

/// Run [body] with [inputs] as ffmpeg should read them: unchanged without
/// [headers] (or for a local path), else rewritten to the proxy.
Future<T> throughProxy<T>(
  List<String> inputs,
  Map<String, String>? headers,
  Future<T> Function(List<String> inputs) body,
) async {
  final origins = {for (final i in inputs) ?_origin(i)}.toList();
  if (headers == null || headers.isEmpty || origins.isEmpty) return body(inputs);
  final proxy = await _Proxy.start(origins, headers);
  try {
    return await body([for (final i in inputs) proxy.map(i)]);
  } finally {
    await proxy.close();
  }
}

/// `scheme://host[:port]` of an http(s) URL, or null.
String? _origin(String url) {
  final u = Uri.tryParse(url);
  if (u == null || (u.scheme != 'http' && u.scheme != 'https') || u.host.isEmpty) return null;
  return '${u.scheme}://${u.authority}';
}

final class _Proxy {
  _Proxy._(this._server, this._origins, this._headers);

  static Future<_Proxy> start(List<String> origins, Map<String, String> headers) async {
    final p = _Proxy._(await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0), origins, headers);
    p._server.listen((req) => unawaited(p._forward(req).catchError((Object _) {})));
    return p;
  }

  final io.HttpServer _server;
  final List<String> _origins;
  final Map<String, String> _headers;
  final _client = io.HttpClient()..autoUncompress = false;

  /// Where ffmpeg asks for origin number [i].
  String _prefix(int i) => 'http://127.0.0.1:${_server.port}/$i';

  /// [url] through the proxy when its origin is one of ours.
  String map(String url) {
    for (final (i, o) in _origins.indexed) {
      if (url == o || url.startsWith('$o/') || url.startsWith('$o?')) return '${_prefix(i)}${url.substring(o.length)}';
    }
    return url;
  }

  /// [text] (a manifest) with our origins' absolute URLs through the proxy.
  String _rewrite(String text) {
    var out = text;
    for (final (i, o) in _origins.indexed) {
      out = out.replaceAll('$o/', '${_prefix(i)}/');
    }
    return out;
  }

  Future<void> _forward(io.HttpRequest req) async {
    final res = req.response;
    final segments = req.uri.pathSegments;
    final i = segments.isEmpty ? null : int.tryParse(segments.first);
    if (i == null || i < 0 || i >= _origins.length) {
      res.statusCode = 404;
      return res.close();
    }
    final rest = req.uri.path.substring(1 + segments.first.length);
    final target = Uri.parse(
      '${_origins[i]}${rest.isEmpty ? '/' : rest}${req.uri.hasQuery ? '?${req.uri.query}' : ''}',
    );
    try {
      final out = await _client.openUrl(req.method, target);
      out.followRedirects = false; // a redirect elsewhere must not carry the headers
      req.headers.forEach((name, values) {
        if (!const {'host', 'connection', 'accept-encoding'}.contains(name)) out.headers.set(name, values);
      });
      _headers.forEach(out.headers.set);
      out.headers.set('accept-encoding', 'identity'); // manifests are rewritten as text
      final up = await out.close();
      res.statusCode = up.statusCode;
      up.headers.forEach((name, values) {
        if (!const {'transfer-encoding', 'connection', 'content-length'}.contains(name)) res.headers.set(name, values);
      });
      final location = up.headers.value('location');
      if (up.isRedirect && location != null) res.headers.set('location', map(target.resolve(location).toString()));
      final type = up.headers.contentType?.mimeType ?? '';
      final manifest =
          type.contains('mpegurl') ||
          type.contains('dash+xml') ||
          target.path.endsWith('.m3u8') ||
          target.path.endsWith('.mpd');
      if (manifest) {
        final text = _rewrite(await utf8.decoder.bind(up).join());
        res.write(text);
      } else {
        if (up.contentLength >= 0) res.contentLength = up.contentLength;
        await res.addStream(up);
      }
    } catch (_) {
      try {
        res.statusCode = 502;
      } catch (_) {}
    }
    await res.close();
  }

  Future<void> close() async {
    _client.close(force: true);
    await _server.close(force: true);
  }
}
