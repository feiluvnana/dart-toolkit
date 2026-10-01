// The cookie jar of `Http.scope(cookies:)`: RFC 6265 storage and matching, less the
// public-suffix list — `a.example.com` cannot set a cookie for `other.com`, but can for `com`.

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

  /// Whether only [domain] itself matches: the cookie named no `Domain`.
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

  /// Per RFC 6265, setting one replaces the other.
  bool sameAs(_Cookie other) => other.name == name && other.domain == domain && other.path == path;

  bool isExpiredAt(DateTime now) => expires != null && !expires!.isAfter(now);

  bool sendsTo(Uri url) {
    if (secure && url.scheme != 'https') return false;
    final host = url.host.toLowerCase();
    final isIp = InternetAddress.tryParse(host) != null;
    if (hostOnly || isIp ? host != domain : !(host == domain || host.endsWith('.$domain'))) return false;
    final target = url.path.isEmpty ? '/' : url.path;
    return target == path || (target.startsWith(path) && (path.endsWith('/') || target[path.length] == '/'));
  }
}

/// The cookies one [Http.scope] has been given, and the `cookie` header they make.
final class _Jar {
  final List<_Cookie> _cookies = [];

  /// Takes what a response set: [header] is its `set-cookie`s, one per line.
  void store(Uri from, String header) {
    for (final line in header.split('\n')) {
      final cookie = _parse(line, from);
      if (cookie == null) continue;
      // Nor may plain http replace one that is `Secure` (RFC 6265bis §5.7).
      if (from.scheme != 'https' && _cookies.any((c) => c.secure && c.sameAs(cookie))) continue;
      _cookies.removeWhere((c) => c.sameAs(cookie));
      // A cookie already past its expiry is a deletion, which the removal above has done.
      if (!cookie.isExpiredAt(DateTime.now())) _cookies.add(cookie);
    }
  }

  /// Takes cookies handed over whole (a browser's). One with no domain is skipped; a leading
  /// dot means subdomains.
  void seed(Iterable<Cookie> given) {
    final now = DateTime.now();
    for (final c in given) {
      final raw = c.domain?.toLowerCase();
      if (raw == null || raw.isEmpty) continue;
      final cookie = _Cookie(
        name: c.name,
        value: c.value,
        domain: raw.startsWith('.') ? raw.substring(1) : raw,
        path: c.path ?? '/',
        expires: c.expires,
        secure: c.secure,
        hostOnly: !raw.startsWith('.'),
      );
      if (cookie.isExpiredAt(now)) continue;
      _cookies
        ..removeWhere((k) => k.sameAs(cookie))
        ..add(cookie);
    }
  }

  /// The `cookie` header for [url], longest path first (RFC 6265), or `null`.
  String? headerFor(Uri url) {
    final now = DateTime.now();
    _cookies.removeWhere((c) => c.isExpiredAt(now));
    final matching = [
      for (final c in _cookies)
        if (c.sendsTo(url)) c,
    ]..sort((a, b) => b.path.length.compareTo(a.path.length));
    return matching.isEmpty ? null : [for (final c in matching) '${c.name}=${c.value}'].join('; ');
  }

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
          // An empty one is dropped and the cookie stays host-only (RFC 6265 §5.2.3).
          final lower = value.toLowerCase();
          final named = lower.startsWith('.') ? lower.substring(1) : lower;
          if (named.isNotEmpty) domain = named;
        case 'path':
          path = value;
        case 'expires':
          // Unparseable: the cookie stays for the browser session, as a browser keeps it.
          expires = _httpDate(value) ?? expires;
        case 'max-age':
          maxAge = int.tryParse(value);
        case 'secure':
          secure = true;
      }
    }
    // A `Secure` cookie over plain http is refused (RFC 6265bis): anyone on the path could
    // have set it.
    if (secure && from.scheme != 'https') return null;
    // Max-Age wins over Expires; one too large for a `Duration` is forever.
    if (maxAge != null) {
      expires = maxAge > 0x7fffffff ? DateTime.utc(9999) : DateTime.now().add(Duration(seconds: maxAge));
    }
    // A domain may widen to a parent of the host, never another site or a bare suffix; an IP
    // must match exactly.
    final isIp = InternetAddress.tryParse(host) != null;
    if (domain != null &&
        (isIp ? host != domain : !(host == domain || (host.endsWith('.$domain') && domain.contains('.'))))) {
      return null;
    }

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

  /// Where a cookie without a `Path` lives: the request path's directory.
  static String _defaultPath(Uri url) {
    final path = url.path;
    if (!path.startsWith('/')) return '/';
    final slash = path.lastIndexOf('/');
    return slash < 1 ? '/' : path.substring(0, slash);
  }
}

/// An `Expires` or `Retry-After` date read as a browser does (RFC 6265 §5.1.1), or `null`.
///
/// Not `HttpDate.parse`, which refuses what servers send — PHP's `Wed, 21-Oct-2026 07:28:00
/// GMT`, a logout's `01-Jan-1970`: this reads tokens in any order, every form at once.
DateTime? _httpDate(String text) {
  int? hour, minute, second, day, month, year;
  for (final token in text.split(_dateDelimiters)) {
    if (token.isEmpty) continue;
    if (_dateTime.matchAsPrefix(token) case final m? when hour == null) {
      hour = int.parse(m[1]!);
      minute = int.parse(m[2]!);
      second = int.parse(m[3]!);
    } else if (_dateDay.matchAsPrefix(token) case final m? when day == null) {
      day = int.parse(m[1]!);
    } else if (month == null && token.length >= 3 && _months.contains(token.substring(0, 3).toLowerCase())) {
      month = _months.indexOf(token.substring(0, 3).toLowerCase()) + 1;
    } else if (_dateYear.matchAsPrefix(token) case final m? when year == null) {
      year = int.parse(m[1]!);
    }
  }
  if (hour == null || minute == null || second == null || day == null || month == null || year == null) return null;
  if (year >= 70 && year <= 99) year += 1900;
  if (year >= 0 && year <= 69) year += 2000;
  if (day < 1 || day > 31 || year < 1601 || hour > 23 || minute > 59 || second > 59) return null;
  final date = DateTime.utc(year, month, day, hour, minute, second);
  // `DateTime` rolls 31 February over into March; a browser refuses it.
  return date.day == day ? date : null;
}

/// RFC 6265's delimiters: tab, space, and punctuation but `:`.
final _dateDelimiters = RegExp(r'[\x09\x20-\x2F\x3B-\x40\x5B-\x60\x7B-\x7E]+');
final _dateTime = RegExp(r'(\d{1,2}):(\d{1,2}):(\d{1,2})(?:\D|$)');
final _dateDay = RegExp(r'(\d{1,2})(?:\D|$)');
final _dateYear = RegExp(r'(\d{2,4})(?:\D|$)');
const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
