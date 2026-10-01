// What a site's /robots.txt allows, for the crawl engine's `ctx.robots`.
//
// RFC 9309: the groups whose `User-agent` matches, the longest matching `Allow` or
// `Disallow` wins, and a tie goes to `Allow`. `Crawl-delay` is not in the RFC and every
// major crawler honours it anyway, so it is read and handed to the engine's own delay.
//
// Nothing here is public: a crawl either respects robots or does not, and
// `ctx.robots = true` is the whole vocabulary.

part of '../../http.dart';

/// One site's rules, as they apply to one user agent.
final class _Robots {
  /// Path prefixes and whether they are allowed, longest first so the first match wins.
  final List<(String prefix, bool allowed)> _rules;

  /// What the site asked for between requests, or `null`.
  final Duration? crawlDelay;

  const _Robots(this._rules, this.crawlDelay);

  /// Nothing forbidden — what a site with no `robots.txt`, or one that cannot be read,
  /// is taken to mean.
  static const open = _Robots([], null);

  /// Whether [url]'s path may be fetched.
  bool allows(Uri url) {
    final target = _normal(url.path.isEmpty ? '/' : '${url.path}${url.hasQuery ? '?${url.query}' : ''}');
    for (final (prefix, allowed) in _rules) {
      if (_matches(prefix, target)) return allowed;
    }
    return true;
  }

  /// A robots path against a URL path, with `*` for any run and `$` for the end.
  ///
  /// The first piece is a prefix and the pieces between stars are found leftmost, which is
  /// never wrong for them; an anchored last piece is the one that is not, since
  /// `/*.php$` has to find the `.php` at the end of `/a.php/b.php` and not the first one, so
  /// it is matched as a suffix instead.
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

  /// [path] spelled one way, so a rule and a URL that mean the same bytes compare equal
  /// (RFC 9309 §2.2.2): anything outside printable ASCII percent-encoded as UTF-8, every
  /// escape in upper case, and an escaped unreserved character — which `Uri` writes bare —
  /// written bare. `Disallow: /café` then forbids `/caf%C3%A9`, and `%3c` is `%3C`.
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

  /// The product tokens [agent] names: `Googlebot` and `Mozilla` in `Mozilla/5.0
  /// (compatible; Googlebot/2.1)`, `mybot` in `mybot/1.0`. RFC 9309 §2.2.1 matches a group
  /// against these whole, so a `User-agent: bot` group is not `mybot`'s.
  static Set<String> _products(String agent) {
    final lower = agent.toLowerCase();
    return {
      for (final m in _productSlash.allMatches(lower)) m[1]!,
      if (_productStart.firstMatch(lower) case final first?) first[0]!,
    };
  }

  /// The sitemaps [text] lists on `Sitemap:` lines, resolved against [site].
  ///
  /// They belong to no group — a `Sitemap:` line applies to every agent wherever it sits —
  /// so they are read apart from the rules.
  static List<Uri> sitemaps(String text, Uri site) => [
    for (final raw in text.split('\n'))
      if (raw.split('#').first.trim() case final line when line.toLowerCase().startsWith('sitemap:'))
        if (Uri.tryParse(line.substring('sitemap:'.length).trim()) case final url? when url.path.isNotEmpty)
          site.resolveUri(url),
  ];

  /// Parses [text] for [agent], falling back to the `*` group when it names no other.
  ///
  /// A group is its `User-agent` lines and the rules under them; a `User-agent` after a
  /// rule starts the next group. Blank lines are skipped rather than read as the end of one,
  /// as RFC 9309's parsers do: a file with a blank line between an agent and its rules means
  /// the rules for that agent.
  static _Robots parse(String text, String agent) {
    final wanted = _products(agent);
    final groups = <({Set<String> agents, List<(String, bool)> rules, Duration? delay})>[];
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

    for (final raw in text.split('\n')) {
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
          // An empty `Disallow` forbids nothing, which is how a group says "everything".
          if (value.isNotEmpty) rules.add((_normal(value), false));
        case 'allow':
          sawRule = true;
          if (value.isNotEmpty) rules.add((_normal(value), true));
        case 'crawl-delay':
          sawRule = true;
          final seconds = double.tryParse(value);
          if (seconds != null && seconds > 0) delay = Duration(microseconds: (seconds * 1e6).round());
      }
    }
    flush();

    // The most specific group that names this agent, else the `*` one.
    final mine = [
      for (final g in groups)
        if (g.agents.any(wanted.contains)) g,
    ];
    final chosen = mine.isNotEmpty
        ? mine
        : [
            for (final g in groups)
              if (g.agents.contains('*')) g,
          ];
    if (chosen.isEmpty) return open;

    // Longest match wins, and a tie goes to Allow.
    final all = [for (final g in chosen) ...g.rules]
      ..sort((a, b) {
        final byLength = b.$1.length.compareTo(a.$1.length);
        return byLength != 0 ? byLength : (a.$2 == b.$2 ? 0 : (a.$2 ? -1 : 1));
      });
    return _Robots(all, chosen.map((g) => g.delay).nonNulls.firstOrNull);
  }
}
