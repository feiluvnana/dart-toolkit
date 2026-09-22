// The cookie jar a scope keeps, so a login and the pages behind it are one crawl.
//
// RFC 6265's storage and matching rules, less the public-suffix list: a `Domain` is
// accepted when the host it came from is inside it, which stops `a.example.com` setting a
// cookie for `other.com` but not for `com`. Nothing here is public — a scope either
// keeps cookies or does not, and `Http.scope(cookies: true)` is the whole vocabulary.

part of '../../http.dart';

/// One stored cookie.
final class _Cookie {
  final String name;
  final String value;

  /// The host it was set from, or the `Domain` it asked for, without a leading dot.
  final String domain;
  final String path;
  final DateTime? expires;
  final bool secure;

  /// Whether only [domain] itself matches, rather than its subdomains too. True unless
  /// the cookie named a `Domain`.
  final bool hostOnly;

  const _Cookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.expires,
    required this.secure,
    required this.hostOnly,
  });

  /// Two cookies are the same cookie when they agree on all three, per RFC 6265; setting
  /// one replaces the other.
  bool sameAs(_Cookie other) => other.name == name && other.domain == domain && other.path == path;

  bool isExpiredAt(DateTime now) => expires != null && !expires!.isAfter(now);

  /// Whether this cookie goes to [url].
  bool sendsTo(Uri url) {
    if (secure && url.scheme != 'https') return false;
    final host = url.host.toLowerCase();
    if (hostOnly ? host != domain : !(host == domain || host.endsWith('.$domain'))) return false;
    final target = url.path.isEmpty ? '/' : url.path;
    return target == path || (target.startsWith(path) && (path.endsWith('/') || target[path.length] == '/'));
  }
}

/// The cookies one [Http.scope] has been given, and the `cookie` header they make.
///
/// A jar belongs to a scope and nothing else: it is the scope that already holds the
/// client, so a login and the requests after it share connections and cookies alike.
final class _Jar {
  final List<_Cookie> _cookies = [];

  /// Takes what a response set. [header] is every `set-cookie` the response carried, one
  /// per line; see [IoClient.send].
  void store(Uri from, String header) {
    for (final line in header.split('\n')) {
      final cookie = _parse(line, from);
      if (cookie == null) continue;
      _cookies.removeWhere((c) => c.sameAs(cookie));
      // A cookie already past its expiry is a deletion, which the removal above has done.
      if (!cookie.isExpiredAt(DateTime.now())) _cookies.add(cookie);
    }
  }

  /// The `cookie` header for [url], or `null` when nothing matches.
  ///
  /// Longest path first, as RFC 6265 asks, so a `/admin` cookie precedes the `/` one.
  String? headerFor(Uri url) {
    final now = DateTime.now();
    _cookies.removeWhere((c) => c.isExpiredAt(now));
    final matching = [
      for (final c in _cookies)
        if (c.sendsTo(url)) c,
    ]..sort((a, b) => b.path.length.compareTo(a.path.length));
    return matching.isEmpty ? null : [for (final c in matching) '${c.name}=${c.value}'].join('; ');
  }

  /// One `set-cookie` value, or `null` when it is not one.
  static _Cookie? _parse(String line, Uri from) {
    final parts = line.split(';');
    final pair = parts.first;
    final eq = pair.indexOf('=');
    if (eq <= 0) return null;
    final host = from.host.toLowerCase();

    String? domain;
    var path = '';
    DateTime? expires;
    int? maxAge;
    var secure = false;
    for (final attribute in parts.skip(1)) {
      final split = attribute.indexOf('=');
      final key = (split == -1 ? attribute : attribute.substring(0, split)).trim().toLowerCase();
      final value = split == -1 ? '' : attribute.substring(split + 1).trim();
      switch (key) {
        case 'domain':
          domain = value.toLowerCase().replaceFirst(RegExp('^\\.'), '');
        case 'path':
          path = value;
        case 'expires':
          try {
            expires = HttpDate.parse(value);
          } on FormatException {
            // Unparseable: the cookie stays for the browser session, as a browser keeps it.
          }
        case 'max-age':
          maxAge = int.tryParse(value);
        case 'secure':
          secure = true;
      }
    }
    // Max-Age wins over Expires, and a zero or negative one expires the cookie now.
    if (maxAge != null) expires = DateTime.now().add(Duration(seconds: maxAge));
    // A cookie may widen its domain to a parent of the host it came from, never to
    // another site and never to a bare suffix.
    if (domain != null && !(host == domain || (host.endsWith('.$domain') && domain.contains('.')))) return null;

    return _Cookie(
      name: pair.substring(0, eq).trim(),
      value: pair.substring(eq + 1).trim(),
      domain: domain ?? host,
      path: path.startsWith('/') ? path : _defaultPath(from),
      expires: expires,
      secure: secure,
      hostOnly: domain == null,
    );
  }

  /// The directory of the request's path, which is where a cookie without a `Path` lives.
  static String _defaultPath(Uri url) {
    final path = url.path;
    if (!path.startsWith('/')) return '/';
    final slash = path.lastIndexOf('/');
    return slash < 1 ? '/' : path.substring(0, slash);
  }
}
