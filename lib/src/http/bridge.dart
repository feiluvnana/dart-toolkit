part of '../http.dart';

/// Not API: what `chrome` shares with `http` (which headers are credentials, which cookie goes
/// where, a proxy's login, a wait the scope's timeout does not cover), public only because those
/// are separate libraries.
abstract final class HttpBridge {
  /// [body], a wait the enclosing request's timeout does not count: a browser's queue for a tab,
  /// a challenge page given time to clear.
  static Future<T> untimed<T>(Future<T> Function() body) async {
    final watch = Zone.current[_watchKey] as _Watch?;
    if (watch == null) return body();
    watch.hold();
    try {
      return await body();
    } finally {
      watch.release();
    }
  }

  /// The `user-agent` a client sends when a request names none, for a crawl to check robots.txt
  /// against: a browser registers its own.
  static final agents = Expando<Future<String?> Function()>('user agent');

  /// Headers that are a credential, and so go to one origin only.
  static const credentials = {'authorization', 'cookie', 'proxy-authorization'};

  /// Whether a cookie for [domain] (no leading dot) and [path] goes to [url], by RFC 6265.
  /// [hostOnly] is a cookie that named no `Domain`, so subdomains do not match.
  static bool sendsTo(
    Uri url, {
    required String domain,
    required String path,
    required bool secure,
    required bool hostOnly,
  }) {
    if (secure && url.scheme != 'https') return false;
    final host = url.host.toLowerCase();
    final isIp = InternetAddress.tryParse(host) != null;
    if (hostOnly || isIp ? host != domain : !(host == domain || host.endsWith('.$domain'))) return false;
    final target = url.path.isEmpty ? '/' : url.path;
    return target == path || (target.startsWith(path) && (path.endsWith('/') || target[path.length] == '/'));
  }

  /// Whether [proxy] is one `IoClient` speaks: `true` for SOCKS5, `false` for HTTP; any other
  /// scheme is an [ArgumentError], before anything is started.
  static bool isSocks(Uri proxy) => switch (proxy.scheme) {
    'socks5' || 'socks5h' => true,
    'http' => false,
    _ => throw ArgumentError.value(proxy, 'proxy', 'Invalid proxy, expected http://, socks5:// or socks5h://'),
  };

  /// [name], chosen by a server, as one file name safe on every OS, or `''`; see `Uri.name`.
  static String fileName(String name) => MessageInternals.safeName(name);

  /// [proxy]'s user and password, percent-decoded, or `null` when it names none.
  static (String user, Secret password)? login(Uri proxy) {
    final info = proxy.userInfo;
    if (info.isEmpty) return null;
    final colon = info.indexOf(':');
    return colon == -1
        ? (Uri.decodeComponent(info), const Secret(''))
        : (Uri.decodeComponent(info.substring(0, colon)), Secret(Uri.decodeComponent(info.substring(colon + 1))));
  }
}
