/// The cookie jar shared by `chrome` (which produces it) and `http` (which
/// consumes it). `utils` exports [Cookies] only; the helpers below are for
/// the modules that fill a jar from `set-cookie` headers or a browser.
library;

import 'dart:convert';
import 'dart:io' as io;

import '../core.dart' show ContentException;

/// A cookie jar: domain, path, expiry and `secure` per cookie, which a
/// `Cookie:` header string loses, plus the session's `User-Agent`.
///
/// ```dart
/// await file.write(cookies.encode());               // persist a session
/// final jar = await Fs.file('.session').cookies(or: Cookies());
/// final client = Http.client(cookies: jar);         // sends the session's user-agent too
/// ```
final class Cookies {
  /// An empty jar.
  Cookies();

  /// A Netscape `cookies.txt`: what [encode] writes, and what browser
  /// cookie-export extensions, curl and yt-dlp use. Comments and lines that
  /// do not parse are skipped (`#HttpOnly_` lines are cookies). A
  /// `user-agent: …` line (or `# user-agent: …`) names the session's
  /// browser, which a client with this jar sends. Text with
  /// content lines but none that parses (a space-separated paste, a JSON
  /// export) is a [ContentException].
  static Cookies parse(String text) {
    final jar = Cookies();
    var content = 0, parsed = 0;
    for (var line in const LineSplitter().convert(text)) {
      line = line.trim();
      if (_agentLine.firstMatch(line) case final m?) {
        final ua = m[1]!.trim();
        if (ua.isNotEmpty) jar._agent = ua;
        continue;
      }
      if (line.startsWith('#HttpOnly_')) line = line.substring('#HttpOnly_'.length);
      if (line.isEmpty || line.startsWith('#')) continue;
      content++;
      final f = line.split('\t');
      if (f.length != 7 || f[0].isEmpty || f[5].isEmpty) continue;
      final seconds = num.tryParse(f[4]);
      if (seconds == null) continue;
      final domain = f[0].toLowerCase();
      parsed++;
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
    if (content > 0 && parsed == 0) {
      throw ContentException('not a Netscape cookies.txt: no line has 7 tab-separated fields');
    }
    return jar;
  }

  String? _agent;

  final _cookies = <String, _Cookie>{};

  /// A Netscape `cookies.txt` (expiry 0 for a session cookie), with the
  /// session's user-agent as a `# user-agent:` comment. Expired cookies
  /// are left out.
  String encode() {
    _sweep();
    String flag(bool b) => b ? 'TRUE' : 'FALSE';
    return [
      '# Netscape HTTP Cookie File',
      if (_agent case final ua?) '# user-agent: $ua',
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

/// The `User-Agent` [jar]'s session was exported with, or null. A client
/// sends it unless a `user-agent` header is given: a session replayed under
/// another browser's name is often logged out.
String? agentOf(Cookies jar) => jar._agent;

final _agentLine = RegExp(r'^#?\s*user-agent\s*:(.*)$', caseSensitive: false);

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

/// A public suffix no site may set cookies for: a country-code registry
/// (`co.uk`, `com.au`, `ac.jp`, `tokyo.jp`, any `x.za`), or a shared host
/// where every subdomain is someone else's site (`github.io`,
/// `blogspot.de`, `s3.eu-west-1.amazonaws.com`, `uk.com`). A heuristic
/// stand-in for the Public Suffix List.
bool isPublicSuffix(String domain) {
  if (_suffixes.contains(domain)) return true;
  final parts = domain.split('.');
  if (parts.first == 'blogspot') return true;
  if (parts.length >= 2 && parts[parts.length - 2] == 'amazonaws' && parts.last == 'com') {
    return parts.length <= 3 || _awsShared.hasMatch(parts.first);
  }
  if (parts.length != 2 || parts[1].length != 2) return false;
  return _registries.contains(parts[0]) ||
      _thirdLevelOnly.contains(parts[1]) ||
      parts[1] == 'jp' && _prefectures.contains(parts[0]);
}

/// The first label of an AWS name shared by every customer's site.
final _awsShared = RegExp(r'^(s3|compute|execute-api|elb|elasticbeanstalk)\b');

/// Country codes registering only below a category (`co.za`, `com.br`).
const _thirdLevelOnly = {'br', 'za', 'th', 'bd', 'ck', 'er', 'fk', 'jm', 'kh', 'mm', 'np', 'pg'};

/// Japan's geographic registries (`tokyo.jp`).
const _prefectures = {
  'aichi', 'akita', 'aomori', 'chiba', 'ehime', 'fukui', 'fukuoka', 'fukushima', 'gifu', 'gunma', 'hiroshima', //
  'hokkaido', 'hyogo', 'ibaraki', 'ishikawa', 'iwate', 'kagawa', 'kagoshima', 'kanagawa', 'kochi', 'kumamoto', //
  'kyoto', 'mie', 'miyagi', 'miyazaki', 'nagano', 'nagasaki', 'nara', 'niigata', 'oita', 'okayama', 'okinawa', //
  'osaka', 'saga', 'saitama', 'shiga', 'shimane', 'shizuoka', 'tochigi', 'tokushima', 'tokyo', 'tottori', //
  'toyama', 'wakayama', 'yamagata', 'yamaguchi', 'yamanashi',
};

const _registries = {
  'co', 'com', 'net', 'org', 'gov', 'edu', 'ac', 'ne', 'or', 'go', 'gob', 'mil', 'nic', 'ltd', 'plc', 'me', //
  'sch', 'nom', 'gen', 'int', 'gr', 'lg', 'ed', 'ad', 'nhs', 'police', 'info', 'biz',
};

const _suffixes = {
  'github.io', 'githubusercontent.com', 'gitlab.io', 'bitbucket.io', 'codeberg.page', 'readthedocs.io', //
  'gitbook.io', 'blogspot.com', 'wordpress.com', 'tumblr.com', 'myshopify.com', 'herokuapp.com', //
  'vercel.app', 'netlify.app', 'pages.dev', 'workers.dev', 'r2.dev', 'trycloudflare.com', 'appspot.com', //
  'web.app', 'firebaseapp.com', 'cloudfront.net', 'azurewebsites.net', 'azureedge.net', 's3.amazonaws.com', //
  'elasticbeanstalk.com', 'fly.dev', 'onrender.com', 'deno.dev', 'glitch.me', 'repl.co', 'ngrok.io', //
  'ngrok-free.app', 'surge.sh', 'neocities.org', 'duckdns.org', 'dyndns.org', 'no-ip.org', //
  // CentralNic's country-like names, each sold by subdomain.
  'uk.com', 'us.com', 'eu.com', 'de.com', 'br.com', 'cn.com', 'ru.com', 'sa.com', 'za.com', 'kr.com', 'jpn.com', //
  'gr.com', 'it.com', 'mex.com', 'no.com', 'qc.com', 'gb.net', 'uk.net', 'hu.net', 'se.net', 'in.net', 'jp.net', //
  'us.org', 'ae.org',
};

/// One `set-cookie` value, parsed leniently as browsers do (RFC 6265
/// §5.2): any value without `;` (spaces, quotes, commas), an attribute
/// that does not parse ignored. Null only without a `name=`.
({String name, String value, String? domain, String? path, bool secure, DateTime? expires})? parseSetCookie(
  String raw,
) {
  final parts = raw.split(';');
  final pair = parts.first;
  final eq = pair.indexOf('=');
  if (eq <= 0) return null;
  final name = pair.substring(0, eq).trim();
  if (name.isEmpty || name.codeUnits.any((c) => c < 0x20 || c == 0x7F)) return null;
  final value = pair.substring(eq + 1).trim();
  String? domain, path;
  var secure = false;
  DateTime? expires;
  int? maxAge;
  for (final attr in parts.skip(1)) {
    final i = attr.indexOf('=');
    final key = (i < 0 ? attr : attr.substring(0, i)).trim().toLowerCase();
    final v = i < 0 ? '' : attr.substring(i + 1).trim();
    switch (key) {
      case 'expires':
        expires = cookieDate(v) ?? expires;
      case 'max-age':
        if (int.tryParse(v) case final n?) maxAge = n.clamp(-1, 999999999);
      case 'domain':
        if (v.isNotEmpty) domain = v;
      case 'path':
        path = v;
      case 'secure':
        secure = true;
    }
  }
  if (maxAge != null) {
    expires = maxAge <= 0 ? DateTime.fromMillisecondsSinceEpoch(0) : DateTime.now().add(Duration(seconds: maxAge));
  }
  return (name: name, value: value, domain: domain, path: path, secure: secure, expires: expires);
}

/// An `Expires` date by the RFC 6265 §5.1.1 algorithm: any order, any
/// delimiters (`Wed, 21-Oct-2026 07:28:00 GMT`, `21 Oct 26 07:28:00`).
DateTime? cookieDate(String text) {
  int? hour, minute, second, day, month, year;
  for (final token in text.split(_dateDelimiters)) {
    if (token.isEmpty) continue;
    if (hour == null) {
      final m = _time.firstMatch(token);
      if (m != null) {
        hour = int.parse(m[1]!);
        minute = int.parse(m[2]!);
        second = int.parse(m[3]!);
        continue;
      }
    }
    if (day == null) {
      final m = _day.firstMatch(token);
      if (m != null) {
        day = int.parse(m[1]!);
        continue;
      }
    }
    if (month == null && token.length >= 3) {
      final i = _months.indexOf(token.substring(0, 3).toLowerCase());
      if (i >= 0) {
        month = i + 1;
        continue;
      }
    }
    if (year == null) {
      final m = _year.firstMatch(token);
      if (m != null) {
        year = int.parse(m[1]!);
        if (year >= 70 && year <= 99) year += 1900;
        if (year <= 69) year += 2000;
        continue;
      }
    }
  }
  if (hour == null || day == null || month == null || year == null) return null;
  if (day < 1 || day > 31 || year < 1601 || hour > 23 || minute! > 59 || second! > 59) return null;
  return DateTime.utc(year, month, day, hour, minute, second);
}

final _dateDelimiters = RegExp(r'[\x09\x20-\x2F\x3B-\x40\x5B-\x60\x7B-\x7E]+');
final _time = RegExp(r'^(\d{1,2}):(\d{1,2}):(\d{1,2})(?:\D.*)?$');
final _day = RegExp(r'^(\d{1,2})(?:\D.*)?$');
final _year = RegExp(r'^(\d{2,4})(?:\D.*)?$');
const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

/// Store the `set-cookie` [values] a response to [url] sent. A malformed
/// value skips only itself; a `Domain=` must contain a dot, be the host or a
/// parent of it (not a public suffix like `co.uk` or `github.io`), and is
/// never honoured on an IP address; a `Secure` cookie needs https.
void storeSetCookies(Cookies jar, Uri url, List<String> values) {
  final host = url.host.toLowerCase();
  final ip = io.InternetAddress.tryParse(host) != null;
  for (final raw in values) {
    final c = parseSetCookie(raw);
    if (c == null) continue;
    var domain = (c.domain ?? '').toLowerCase();
    if (domain.startsWith('.')) domain = domain.substring(1);
    var hostOnly = domain.isEmpty || domain == host;
    if (hostOnly) {
      domain = host;
    } else if (ip || !domain.contains('.') || !host.endsWith('.$domain') || isPublicSuffix(domain)) {
      continue; // not this host's to set
    }
    // A Secure cookie from plain http could overwrite the https one, and a
    // plain one must not shadow a Secure one (RFC 6265bis §5.7).
    if (url.scheme != 'https' && (c.secure || _shadowsSecure(jar, c.name, domain, c.path ?? '/'))) continue;
    if (ip) hostOnly = true;
    var path = c.path ?? '';
    if (!path.startsWith('/')) {
      final p = url.path;
      final slash = p.lastIndexOf('/');
      path = slash <= 0 ? '/' : p.substring(0, slash);
    }
    jar._put(
      _Cookie(c.name, c.value, domain: domain, hostOnly: hostOnly, path: path, secure: c.secure, expires: c.expires),
    );
  }
}

/// Whether [jar] holds a Secure cookie [name] whose domain matches [domain]
/// either way and whose path covers [path]: plain http may not replace it.
bool _shadowsSecure(Cookies jar, String name, String domain, String path) {
  for (final c in jar._cookies.values) {
    if (!c.secure || c.name != name) continue;
    final related = c.domain == domain || c.domain.endsWith('.$domain') || domain.endsWith('.${c.domain}');
    final covers = path == c.path || path.startsWith(c.path.endsWith('/') ? c.path : '${c.path}/');
    if (related && covers) return true;
  }
  return false;
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
