// What a site's /robots.txt allows, for `ctx.robots`. RFC 9309: the matching groups' longest
// `Allow`/`Disallow` wins, a tie to `Allow`. `Crawl-delay` is not in the RFC, but every major
// crawler honours it.

part of '../../scrape.dart';

/// One site's rules, as they apply to one user agent.
final class _Robots {
  /// Longest first, so the first match wins.
  final List<(String prefix, bool allowed)> _rules;

  final Duration? crawlDelay;

  const _Robots(this._rules, this.crawlDelay);

  /// Nothing forbidden: no `robots.txt`, or an unreadable one.
  static const open = _Robots([], null);

  bool allows(Uri url) {
    final target = _normal(url.path.isEmpty ? '/' : '${url.path}${url.hasQuery ? '?${url.query}' : ''}');
    for (final (prefix, allowed) in _rules) {
      if (_matches(prefix, target)) return allowed;
    }
    return true;
  }

  /// A robots path (`*` any run, `$` the end) against a URL path. Middle pieces match
  /// leftmost; an anchored last piece is a suffix, so `/*.php$` matches `/a.php/b.php`.
  static bool _matches(String pattern, String target) {
    if (!pattern.contains('*') && !pattern.endsWith(r'$')) return target.startsWith(pattern);
    final anchored = pattern.endsWith(r'$');
    final parts = (anchored ? pattern.substring(0, pattern.length - 1) : pattern).split('*');
    if (parts.length == 1) return target == parts.first;
    if (!target.startsWith(parts.first)) return false;
    var at = parts.first.length;
    final last = parts.length - 1;
    for (var i = 1; i < last; i++) {
      final part = parts[i];
      if (part.isEmpty) continue;
      final found = target.indexOf(part, at);
      if (found == -1) return false;
      at = found + part.length;
    }
    final tail = parts[last];
    if (!anchored) return tail.isEmpty || target.indexOf(tail, at) != -1;
    return target.length - tail.length >= at && target.endsWith(tail);
  }

  /// [path] spelled one way (RFC 9309 §2.2.2): non-ASCII percent-encoded as UTF-8, escapes
  /// upper-cased, unreserved ones unescaped — so `/café` is `/caf%C3%A9` and `%3c` is `%3C`.
  static String _normal(String path) {
    final out = StringBuffer();
    final bytes = utf8.encode(path);
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b == 0x25 && i + 2 < bytes.length && _hex(bytes[i + 1]) && _hex(bytes[i + 2])) {
        final value = int.parse(String.fromCharCodes([bytes[i + 1], bytes[i + 2]]), radix: 16);
        if (_unreserved(value)) {
          out.writeCharCode(value);
        } else {
          out.write('%${String.fromCharCodes([bytes[i + 1], bytes[i + 2]]).toUpperCase()}');
        }
        i += 2;
      } else if (b <= 0x20 || b >= 0x7f) {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      } else {
        out.writeCharCode(b);
      }
    }
    return out.toString();
  }

  static bool _hex(int c) => (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);

  static bool _unreserved(int c) =>
      (c >= 0x41 && c <= 0x5a) ||
      (c >= 0x61 && c <= 0x7a) ||
      (c >= 0x30 && c <= 0x39) ||
      c == 0x2d ||
      c == 0x2e ||
      c == 0x5f ||
      c == 0x7e;

  static final _productSlash = RegExp(r'([a-z0-9_-]+)/');
  static final _productStart = RegExp(r'^[a-z0-9_-]+');

  /// The product tokens [agent] names — `mozilla` and `googlebot` in `Mozilla/5.0
  /// (compatible; Googlebot/2.1)` — matched whole (RFC 9309 §2.2.1): `bot` is not `mybot`.
  static Set<String> _products(String agent) {
    final lower = agent.toLowerCase();
    return {
      for (final m in _productSlash.allMatches(lower)) m[1]!,
      if (_productStart.firstMatch(lower) case final first?) first[0]!,
    };
  }
}

typedef _Group = ({Set<String> agents, List<(String, bool)> rules, Duration? delay});

/// A site's parsed robots.txt — never the text, which may be half a megabyte.
final class _RobotsTxt {
  final List<_Group> _groups;

  /// `Sitemap:` lines, resolved; they belong to no group.
  final List<Uri> sitemaps;

  const _RobotsTxt(this._groups, this.sitemaps);

  /// A `User-agent` after a rule starts the next group; blank lines do not end one, as in
  /// RFC 9309's parsers.
  factory _RobotsTxt.parse(String text, Uri site) {
    final groups = <_Group>[];
    final sitemaps = <Uri>[];
    var agents = <String>{};
    var rules = <(String, bool)>[];
    Duration? delay;
    var sawRule = false;

    void flush() {
      if (agents.isNotEmpty) groups.add((agents: agents, rules: rules, delay: delay));
      agents = <String>{};
      rules = <(String, bool)>[];
      delay = null;
      sawRule = false;
    }

    // RFC 9309 §2.2: a line ends in LF, CR or CRLF.
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.split('#').first.trim();
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon == -1) continue;
      final field = line.substring(0, colon).trim().toLowerCase();
      final value = line.substring(colon + 1).trim();
      switch (field) {
        case 'user-agent':
          if (sawRule) flush();
          agents.add(value.toLowerCase());
        case 'disallow':
          sawRule = true;
          // An empty `Disallow` forbids nothing.
          if (value.isNotEmpty) rules.add((_Robots._normal(value), false));
        case 'allow':
          sawRule = true;
          if (value.isNotEmpty) rules.add((_Robots._normal(value), true));
        case 'crawl-delay':
          sawRule = true;
          final seconds = double.tryParse(value);
          if (seconds != null && seconds > 0) delay = Duration(microseconds: (seconds * 1e6).round());
        case 'sitemap':
          if (Uri.tryParse(value) case final url? when url.path.isNotEmpty) sitemaps.add(site.resolveUri(url));
      }
    }
    flush();
    return _RobotsTxt(groups, sitemaps);
  }

  /// The rules for [agent]: the groups that name it, else the `*` ones.
  _Robots forAgent(String agent) {
    final wanted = _Robots._products(agent);
    List<_Group> where(bool Function(Set<String>) test) => [
      for (final g in _groups)
        if (test(g.agents)) g,
    ];
    final mine = where((agents) => agents.any(wanted.contains));
    final chosen = mine.isNotEmpty ? mine : where((agents) => agents.contains('*'));
    if (chosen.isEmpty) return _Robots.open;

    // Longest match wins, and a tie goes to Allow.
    final all = [for (final g in chosen) ...g.rules]
      ..sort((a, b) {
        final byLength = b.$1.length.compareTo(a.$1.length);
        return byLength != 0 ? byLength : (a.$2 == b.$2 ? 0 : (a.$2 ? -1 : 1));
      });
    return _Robots(all, chosen.map((g) => g.delay).nonNulls.firstOrNull);
  }
}
