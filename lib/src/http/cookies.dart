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
    final isIp = InternetAddress.tryParse(host) != null;
    if (hostOnly || isIp ? host != domain : !(host == domain || host.endsWith('.$domain'))) return false;
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
      // Nor may plain http replace one that is `Secure` (RFC 6265bis §5.7).
      if (from.scheme != 'https' && _cookies.any((c) => c.secure && c.sameAs(cookie))) continue;
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

  /// A cookie as the DevTools protocol describes one, for [ChromeClient] to match by the
  /// same rules as this jar: a leading dot on the domain is what makes it not host-only.
  static _Cookie _of(Map<String, Object?> cdp) {
    final domain = (cdp['domain'] as String? ?? '').toLowerCase();
    return _Cookie(
      name: cdp['name'] as String? ?? '',
      value: cdp['value'] as String? ?? '',
      domain: domain.startsWith('.') ? domain.substring(1) : domain,
      path: cdp['path'] as String? ?? '/',
      expires: null,
      secure: cdp['secure'] == true,
      hostOnly: !domain.startsWith('.'),
    );
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
          // An empty one is ignored, not obeyed: RFC 6265 §5.2.3 drops the attribute, and
          // the cookie stays host-only.
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
    // A `Secure` cookie set over plain http is refused, as RFC 6265bis asks: anyone on the
    // path could have set it, and it would then be trusted over https.
    if (secure && from.scheme != 'https') return null;
    // Max-Age wins over Expires, and a zero or negative one expires the cookie now. One
    // too large for a `Duration` is as good as forever.
    if (maxAge != null) {
      expires = maxAge > 0x7fffffff ? DateTime.utc(9999) : DateTime.now().add(Duration(seconds: maxAge));
    }
    // A cookie may widen its domain to a parent of the host it came from, never to
    // another site and never to a bare suffix. An IP host requires domain == host.
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

  /// The directory of the request's path, which is where a cookie without a `Path` lives.
  static String _defaultPath(Uri url) {
    final path = url.path;
    if (!path.startsWith('/')) return '/';
    final slash = path.lastIndexOf('/');
    return slash < 1 ? '/' : path.substring(0, slash);
  }
}

/// An `Expires` or a `Retry-After` date, read the way a browser reads one — RFC 6265 §5.1.1 —
/// or `null` when it is not a date at all.
///
/// `HttpDate.parse` takes the three forms RFC 9110 lists and throws an `HttpException` for the
/// rest, and what servers actually send is the rest: `Wed, 21-Oct-2026 07:28:00 GMT`, which is
/// PHP's, and the `01-Jan-1970` a logout uses to delete its cookie. The algorithm reads a date
/// as tokens — a time, a day, a month, a year, in whatever order — which is every form at once.
DateTime? _httpDate(String text) {
  int? hour, minute, second, day, month, year;
  for (final token in text.split(_dateDelimiters)) {
    if (token.isEmpty) continue;
    if (hour == null) {
      if (_dateTime.matchAsPrefix(token) case final m?) {
        hour = int.parse(m[1]!);
        minute = int.parse(m[2]!);
        second = int.parse(m[3]!);
        continue;
      }
    }
    if (day == null) {
      if (_dateDay.matchAsPrefix(token) case final m?) {
        day = int.parse(m[1]!);
        continue;
      }
    }
    if (month == null && token.length >= 3) {
      final index = _months.indexOf(token.substring(0, 3).toLowerCase());
      if (index != -1) {
        month = index + 1;
        continue;
      }
    }
    if (year == null) {
      if (_dateYear.matchAsPrefix(token) case final m?) year = int.parse(m[1]!);
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

/// Everything RFC 6265 calls a delimiter: the controls it allows, and punctuation but `:`.
final _dateDelimiters = RegExp(r'[\x09\x20-\x2F\x3B-\x40\x5B-\x60\x7B-\x7E]+');
final _dateTime = RegExp(r'(\d{1,2}):(\d{1,2}):(\d{1,2})(?:\D|$)');
final _dateDay = RegExp(r'(\d{1,2})(?:\D|$)');
final _dateYear = RegExp(r'(\d{2,4})(?:\D|$)');
const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
