// The cookie jar of `Http.scope(cookies:)`: RFC 6265 storage and matching, less the
// public-suffix list (`a.example.com` cannot set a cookie for `other.com`, but can for `com`).

part of '../http.dart';

/// The cookies a session has: what a scope (and the crawls in it) keeps, and what
/// `chrome.cookies()` hands over. Iterating it reads them (expired ones are dropped); [add] puts
/// one in; [save] and [CookieJar.read] write and read a cookie file: Netscape `cookies.txt` for
/// a `.txt` (curl, yt-dlp), else JSON.
///
/// ```dart
/// final jar = await chrome.cookies();                 // a browser login
/// await Http.scope(cookies: jar, () => api.get().json); // carried on at socket speed
/// await jar.save('cookies.txt');                      // for yt-dlp too
/// ```
///
/// {@category Networking}
final class CookieJar extends Iterable<HttpCookie> implements Saveable {
  /// The most a jar keeps for one domain, and in all, as a browser caps them: past either the
  /// oldest set goes, so a site setting a new name on every page cannot grow it without end.
  static const _perDomain = 180, _most = 3000;

  /// Every cookie, oldest set first.
  final _order = LinkedHashSet<_Jarred>.identity();

  /// The same by domain, oldest set first: a request looks at its host's and its parents' only.
  final _byDomain = <String, List<_Jarred>>{};
  var _sets = 0;

  /// A jar holding [cookies]; see [add].
  CookieJar([Iterable<HttpCookie> cookies = const []]) {
    cookies.forEach(add);
  }

  /// The jar in the cookie file [path]: Netscape `cookies.txt` for a `.txt`, else [toJson]'s
  /// JSON. A missing file is a [PathNotFoundException]; one that does not read a
  /// [FormatException] naming it.
  static Future<CookieJar> read(String path) async => _parsedCookies(path, await File(path).readAsString());

  /// Writes this jar to the cookie file [to], as [read] reads it, atomically.
  @override
  Task<Path> save(String to, {Conflict conflict = Conflict.overwrite}) =>
      FileBridge.save(to, conflict, 'cookies', () => [utf8.encode(_savedCookies(this, to))]);

  /// The jar [json] holds, as [toJson] wrote it; a [FormatException] if it is not that shape.
  factory CookieJar.fromJson(Object? json) {
    if (json is! List) throw const FormatException('Invalid cookie file: expected a JSON list of cookies');
    final jar = CookieJar();
    for (final item in json) {
      if (item is! Map) throw const FormatException('Invalid cookie entry: expected a JSON map');
      final name = item['name'];
      final value = item['value'];
      final domain = item['domain'];
      if (name is! String || value is! String || domain is! String || domain.isEmpty) {
        throw const FormatException('Invalid cookie entry: missing name, value or domain');
      }
      jar.add(
        HttpCookie(
          name,
          value,
          domain: domain,
          path: item['path'] as String? ?? '/',
          expires: DateTime.tryParse(item['expires'] as String? ?? ''),
          secure: item['secure'] == true,
          hostOnly: item['hostOnly'] == true,
          httpOnly: item['httpOnly'] == true,
        ),
      );
    }
    return jar;
  }

  /// Stores [cookie], replacing the one of the same name, domain and path; past 180 for its domain
  /// or 3000 in all the oldest set goes. One already expired (on `Clock.current`) is not kept, and still
  /// removes its namesake.
  void add(HttpCookie cookie) {
    if (_find(cookie) case final old?) _drop(old);
    if (_lapsed(cookie, Clock.current.now())) return;
    final entry = _Jarred(cookie, _sets++);
    final mine = _byDomain[cookie.domain] ??= [];
    mine.add(entry);
    _order.add(entry);
    if (mine.length > _perDomain) _drop(mine.first);
    if (_order.length > _most) _drop(_order.first);
  }

  /// Removes the cookies named [name], of [domain] only when given.
  void remove(String name, {String? domain}) {
    final lower = domain?.toLowerCase();
    for (final e in [..._order]) {
      if (e.cookie.name == name && (lower == null || e.cookie.domain == lower)) _drop(e);
    }
  }

  /// Removes every cookie: the session starts over.
  void clear() {
    _order.clear();
    _byDomain.clear();
  }

  @override
  Iterator<HttpCookie> get iterator {
    _sweep();
    return [for (final e in _order) e.cookie].iterator;
  }

  /// The cookies as JSON, for [CookieJar.fromJson]: what `jsonEncode(jar)` writes.
  List<Map<String, Object?>> toJson() => [
    for (final c in this)
      {
        'name': c.name,
        'value': c.value,
        'domain': c.domain,
        'path': c.path,
        'expires': c.expires?.toIso8601String(),
        'secure': c.secure,
        'hostOnly': c.hostOnly,
        'httpOnly': c.httpOnly,
      },
  ];

  void _sweep() {
    final now = Clock.current.now();
    for (final e in [..._order]) {
      if (_lapsed(e.cookie, now)) _drop(e);
    }
  }

  /// The kept cookie [cookie] would replace, if any.
  _Jarred? _find(HttpCookie cookie) {
    for (final e in _byDomain[cookie.domain] ?? const <_Jarred>[]) {
      if (_same(e.cookie, cookie)) return e;
    }
    return null;
  }

  void _drop(_Jarred e) {
    _order.remove(e);
    final mine = _byDomain[e.cookie.domain]!..remove(e);
    if (mine.isEmpty) _byDomain.remove(e.cookie.domain);
  }

  static bool _lapsed(HttpCookie c, DateTime now) => c.expires != null && !c.expires!.isAfter(now);

  /// Per RFC 6265, setting one replaces the other.
  static bool _same(HttpCookie a, HttpCookie b) => a.name == b.name && a.domain == b.domain && a.path == b.path;

  /// Takes what a response from [from] set: [header] is its `set-cookie`s, one per line.
  void _store(Uri from, String header) {
    for (final line in header.split('\n')) {
      final cookie = MessageInternals.setCookie(line, from);
      if (cookie == null) continue;
      // Nor may plain http replace one that is `Secure` (RFC 6265bis §5.7).
      if (from.scheme != 'https' && (_find(cookie)?.cookie.secure ?? false)) continue;
      add(cookie);
    }
  }

  /// Takes what [res], the answer to [sent], set.
  void _keep(StreamedResponse res, Request sent) {
    if (res.headers['set-cookie'] case final header?) _store(res.url ?? sent.url, header);
  }

  /// The `cookie` header for [url], longest path first (RFC 6265) and else in the order set,
  /// or `null`. Only the host's domain and its parents' are looked at.
  String? _headerFor(Uri url) {
    if (_order.isEmpty) return null;
    final now = Clock.current.now();
    final host = url.host.toLowerCase();
    final matching = <_Jarred>[];
    final lapsed = <_Jarred>[];
    for (var domain = host; ;) {
      for (final e in _byDomain[domain] ?? const <_Jarred>[]) {
        final c = e.cookie;
        if (_lapsed(c, now)) {
          lapsed.add(e);
        } else if (HttpBridge.sendsTo(url, domain: c.domain, path: c.path, secure: c.secure, hostOnly: c.hostOnly)) {
          matching.add(e);
        }
      }
      final dot = domain.indexOf('.');
      if (dot == -1) break;
      domain = domain.substring(dot + 1);
    }
    lapsed.forEach(_drop);
    if (matching.isEmpty) return null;
    matching.sort((a, b) {
      final byPath = b.cookie.path.length.compareTo(a.cookie.path.length);
      return byPath != 0 ? byPath : a.set.compareTo(b.set);
    });
    return [for (final e in matching) '${e.cookie.name}=${e.cookie.value}'].join('; ');
  }
}

/// A cookie in a jar, with when it was set among the others.
final class _Jarred {
  final HttpCookie cookie;
  final int set;
  _Jarred(this.cookie, this.set);
}

/// The jar [text], the cookie file [path], holds.
CookieJar _parsedCookies(String path, String text) {
  try {
    return _isNetscape(path) ? _fromNetscape(text) : CookieJar.fromJson(json.decode(text));
  } on FormatException catch (e) {
    throw FormatException('Invalid cookie file in $path: ${e.message}');
  }
}

/// [jar] as the cookie file [path] holds it; see [CookieJar.read].
String _savedCookies(CookieJar jar, String path) =>
    _isNetscape(path) ? _toNetscape(jar) : '${const JsonEncoder.withIndent('  ').convert(jar.toJson())}\n';

bool _isNetscape(String path) => path.toLowerCase().endsWith('.txt');

/// A Netscape `cookies.txt`: per line, tab-separated, the domain (`#HttpOnly_` before it for an
/// `HttpOnly` one), whether subdomains match, the path, `Secure`, the expiry in Unix seconds
/// (`0` for a session cookie), the name and the value. Other `#` lines are comments.
CookieJar _fromNetscape(String text) {
  final jar = CookieJar();
  final lines = const LineSplitter().convert(text);
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    final httpOnly = line.startsWith('#HttpOnly_');
    if (httpOnly) line = line.substring('#HttpOnly_'.length);
    if (line.trim().isEmpty || line.startsWith('#')) continue;
    final fields = line.split('\t');
    if (fields.length < 6) throw FormatException('Invalid cookie at line ${i + 1}: expected 7 tab-separated fields');
    final seconds = int.tryParse(fields[4].trim());
    if (seconds == null) throw FormatException('Invalid expiry at line ${i + 1}: ${fields[4]}, expected Unix seconds');
    final domain = fields[0].trim();
    if (domain.isEmpty || domain == '.') throw FormatException('Invalid cookie at line ${i + 1}: no domain');
    jar.add(
      HttpCookie(
        fields[5],
        fields.length > 6 ? fields.sublist(6).join('\t') : '',
        domain: domain,
        path: fields[2].isEmpty ? '/' : fields[2],
        secure: fields[3].toUpperCase() == 'TRUE',
        expires: seconds == 0 ? null : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
        hostOnly: fields[1].toUpperCase() != 'TRUE' && !domain.startsWith('.'),
        httpOnly: httpOnly,
      ),
    );
  }
  return jar;
}

String _toNetscape(CookieJar jar) {
  final out = StringBuffer('# Netscape HTTP Cookie File\n');
  for (final c in jar) {
    final expires = c.expires == null ? 0 : c.expires!.millisecondsSinceEpoch ~/ 1000;
    out.writeln(
      [
        '${c.httpOnly ? '#HttpOnly_' : ''}${c.hostOnly ? '' : '.'}${c.domain}',
        c.hostOnly ? 'FALSE' : 'TRUE',
        c.path,
        c.secure ? 'TRUE' : 'FALSE',
        '$expires',
        c.name,
        c.value,
      ].join('\t'),
    );
  }
  return '$out';
}
