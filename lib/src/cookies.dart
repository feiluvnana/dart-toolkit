/// The cookie jar shared by `chrome` (which produces it) and `http` (which
/// consumes it). `core` exports [Cookies] only; the helpers below are for
/// the modules that fill a jar from `set-cookie` headers or a browser.
library;

import 'dart:convert';
import 'dart:io' as io;

/// A cookie jar: domain, path, expiry and `secure` per cookie, which a
/// `Cookie:` header string loses.
///
/// ```dart
/// await file.write(cookies.encode());               // persist a session
/// final jar = Cookies.parse(await file.text(or: ''));
/// final client = Http.client(cookies: jar);
/// ```
final class Cookies {
  Cookies();

  /// A Netscape `cookies.txt`: what [encode] writes, and what browser
  /// cookie-export extensions, curl and yt-dlp use. Comments and lines that
  /// do not parse are skipped (`#HttpOnly_` lines are cookies).
  static Cookies parse(String text) {
    final jar = Cookies();
    for (var line in const LineSplitter().convert(text)) {
      line = line.trim();
      if (line.startsWith('#HttpOnly_')) line = line.substring('#HttpOnly_'.length);
      if (line.isEmpty || line.startsWith('#')) continue;
      final f = line.split('\t');
      if (f.length != 7 || f[0].isEmpty || f[5].isEmpty) continue;
      final seconds = num.tryParse(f[4]);
      if (seconds == null) continue;
      final domain = f[0].toLowerCase();
      jar._put(
        _Cookie(
          f[5],
          f[6],
          domain: domain.startsWith('.') ? domain.substring(1) : domain,
          hostOnly: !domain.startsWith('.') && f[1].toUpperCase() != 'TRUE',
          path: f[2].isEmpty ? '/' : f[2],
          secure: f[3].toUpperCase() == 'TRUE',
          expires: seconds <= 0 ? null : DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round()),
        ),
      );
    }
    return jar;
  }

  final _cookies = <String, _Cookie>{};

  /// A Netscape `cookies.txt` (expiry 0 for a session cookie). Expired
  /// cookies are left out.
  String encode() {
    _sweep();
    String flag(bool b) => b ? 'TRUE' : 'FALSE';
    return [
      '# Netscape HTTP Cookie File',
      for (final c in _cookies.values)
        [
          c.hostOnly ? c.domain : '.${c.domain}',
          flag(!c.hostOnly),
          c.path,
          flag(c.secure),
          '${(c.expires?.millisecondsSinceEpoch ?? 0) ~/ 1000}',
          c.name,
          c.value,
        ].join('\t'),
    ].join('\n');
  }

  /// The most specific live value for [name] (longest domain, then longest
  /// path), or null.
  String? operator [](String name) {
    _sweep();
    _Cookie? best;
    for (final c in _cookies.values) {
      if (c.name != name) continue;
      if (best == null ||
          c.domain.length > best.domain.length ||
          (c.domain.length == best.domain.length && c.path.length > best.path.length)) {
        best = c;
      }
    }
    return best?.value;
  }

  /// The `Cookie` header a request to [url] would send, longest path first;
  /// null when none match.
  String? header(String url) => headerFor(this, Uri.parse(url));

  /// Set a host-only cookie for [url]'s host on path `/`. Returns this jar.
  Cookies set(String name, String value, {required String url}) {
    final host = Uri.parse(url).host.toLowerCase();
    _put(_Cookie(name, value, domain: host, hostOnly: true, path: '/', secure: false));
    return this;
  }

  void _put(_Cookie c) {
    final key = '${c.domain};${c.path};${c.name}';
    if (c.expires != null && !c.expires!.isAfter(DateTime.now())) {
      _cookies.remove(key);
    } else {
      _cookies[key] = c;
    }
  }

  void _sweep() {
    final now = DateTime.now();
    _cookies.removeWhere((_, c) => c.expires != null && !c.expires!.isAfter(now));
  }

  @override
  String toString() => 'Cookies(${_cookies.values.map((c) => c.name).join(', ')})';
}

final class _Cookie {
  _Cookie(
    this.name,
    this.value, {
    required this.domain,
    required this.hostOnly,
    required this.path,
    required this.secure,
    this.expires,
  });

  final String name, value, domain, path;
  final bool hostOnly, secure;
  final DateTime? expires;
}

/// Add a browser cookie (CDP `Network.getCookies`): [domain] with a leading
/// dot is a domain cookie, without one host-only.
void addCookie(
  Cookies jar, {
  required String name,
  required String value,
  required String domain,
  String path = '/',
  bool secure = false,
  DateTime? expires,
}) {
  final d = domain.toLowerCase();
  jar._put(
    _Cookie(
      name,
      value,
      domain: d.startsWith('.') ? d.substring(1) : d,
      hostOnly: !d.startsWith('.'),
      path: path.startsWith('/') ? path : '/',
      secure: secure,
      expires: expires,
    ),
  );
}

/// A country-code registry like `co.uk`, `com.au` or `ac.jp`, which no
/// site may set cookies for (a short stand-in for the public suffix list).
bool _registry(String domain) {
  final parts = domain.split('.');
  return parts.length == 2 &&
      parts[1].length == 2 &&
      const {'co', 'com', 'net', 'org', 'gov', 'edu', 'ac', 'ne', 'or', 'go'}.contains(parts[0]);
}

/// Store the `set-cookie` [values] a response to [url] sent. A malformed
/// value skips only itself; a `Domain=` must contain a dot, be the host or a
/// parent of it (not a registry like `co.uk`), and is never honoured on an
/// IP address; a `Secure` cookie needs https.
void storeSetCookies(Cookies jar, Uri url, List<String> values) {
  final host = url.host.toLowerCase();
  final ip = io.InternetAddress.tryParse(host) != null;
  for (final raw in values) {
    io.Cookie c;
    try {
      c = io.Cookie.fromSetCookieValue(raw);
    } catch (_) {
      continue;
    }
    var domain = (c.domain ?? '').toLowerCase();
    if (domain.startsWith('.')) domain = domain.substring(1);
    var hostOnly = domain.isEmpty || domain == host;
    if (hostOnly) {
      domain = host;
    } else if (ip || !domain.contains('.') || !host.endsWith('.$domain') || _registry(domain)) {
      continue; // not this host's to set
    }
    // A Secure cookie from plain http could overwrite the https one.
    if (c.secure && url.scheme != 'https') continue;
    if (ip) hostOnly = true;
    var path = c.path ?? '';
    if (!path.startsWith('/')) {
      final p = url.path;
      final slash = p.lastIndexOf('/');
      path = slash <= 0 ? '/' : p.substring(0, slash);
    }
    final expires = c.maxAge != null ? DateTime.now().add(Duration(seconds: c.maxAge!)) : c.expires;
    jar._put(
      _Cookie(c.name, c.value, domain: domain, hostOnly: hostOnly, path: path, secure: c.secure, expires: expires),
    );
  }
}

/// The `Cookie` header for [url], longest path first, or null.
String? headerFor(Cookies jar, Uri url) {
  final out = _sentTo(jar, url);
  return out.isEmpty ? null : out.map((c) => '${c.name}=${c.value}').join('; ');
}

/// The value of cookie [name] that [url] would be sent, or null: a token
/// copied into a header (csrf) goes only where the cookie itself would.
String? valueFor(Cookies jar, Uri url, String name) {
  for (final c in _sentTo(jar, url)) {
    if (c.name == name) return c.value;
  }
  return null;
}

/// The cookies [url] is sent, longest path first.
List<_Cookie> _sentTo(Cookies jar, Uri url) {
  if (jar._cookies.isEmpty) return const [];
  jar._sweep();
  final host = url.host.toLowerCase();
  final path = url.path.isEmpty ? '/' : url.path;
  final out = <_Cookie>[];
  for (final c in jar._cookies.values) {
    final domainOk = c.hostOnly ? host == c.domain : host == c.domain || host.endsWith('.${c.domain}');
    final pathOk = path == c.path || path.startsWith(c.path.endsWith('/') ? c.path : '${c.path}/');
    if (domainOk && pathOk && (!c.secure || url.scheme == 'https')) out.add(c);
  }
  out.sort((a, b) => b.path.length.compareTo(a.path.length));
  return out;
}
