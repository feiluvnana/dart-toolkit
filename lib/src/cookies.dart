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

  /// What [encode] wrote; a line that does not parse is skipped.
  static Cookies parse(String text) {
    final jar = Cookies();
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      try {
        final m = jsonDecode(line) as Map<String, Object?>;
        final domain = m['domain'] as String;
        final expiry = m['expiry'] as int?;
        jar._put(
          _Cookie(
            m['name'] as String,
            m['value'] as String,
            domain: domain.startsWith('.') ? domain.substring(1) : domain,
            hostOnly: !domain.startsWith('.'),
            path: m['path'] as String? ?? '/',
            secure: m['secure'] as bool? ?? false,
            expires: expiry == null ? null : DateTime.fromMillisecondsSinceEpoch(expiry),
          ),
        );
      } catch (_) {}
    }
    return jar;
  }

  final _cookies = <String, _Cookie>{};

  /// JSON lines: `name`, `value`, `domain` (a leading dot for a domain
  /// cookie, none for host-only), `path`, `expiry` (epoch ms or null),
  /// `secure`. Expired cookies are left out.
  String encode() {
    _sweep();
    return [
      for (final c in _cookies.values)
        jsonEncode({
          'name': c.name,
          'value': c.value,
          'domain': c.hostOnly ? c.domain : '.${c.domain}',
          'path': c.path,
          'expiry': c.expires?.millisecondsSinceEpoch,
          'secure': c.secure,
        }),
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

/// Store the `set-cookie` [values] a response to [url] sent. A malformed
/// value skips only itself; a `Domain=` must contain a dot, be the host or a
/// parent of it, and is never honoured on an IP address.
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
    } else if (ip || !domain.contains('.') || !host.endsWith('.$domain')) {
      continue; // not this host's to set
    }
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
  if (jar._cookies.isEmpty) return null;
  jar._sweep();
  final host = url.host.toLowerCase();
  final path = url.path.isEmpty ? '/' : url.path;
  final out = <_Cookie>[];
  for (final c in jar._cookies.values) {
    final domainOk = c.hostOnly ? host == c.domain : host == c.domain || host.endsWith('.${c.domain}');
    final pathOk = path == c.path || path.startsWith(c.path.endsWith('/') ? c.path : '${c.path}/');
    if (domainOk && pathOk && (!c.secure || url.scheme == 'https')) out.add(c);
  }
  if (out.isEmpty) return null;
  out.sort((a, b) => b.path.length.compareTo(a.path.length));
  return out.map((c) => '${c.name}=${c.value}').join('; ');
}
