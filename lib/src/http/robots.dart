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
    final target = url.path.isEmpty ? '/' : '${url.path}${url.hasQuery ? '?${url.query}' : ''}';
    for (final (prefix, allowed) in _rules) {
      if (_matches(prefix, target)) return allowed;
    }
    return true;
  }

  /// A robots path against a URL path, with `*` for any run and `$` for the end.
  static bool _matches(String pattern, String target) {
    if (!pattern.contains('*') && !pattern.endsWith(r'$')) return target.startsWith(pattern);
    final anchored = pattern.endsWith(r'$');
    final parts = (anchored ? pattern.substring(0, pattern.length - 1) : pattern).split('*');
    var at = 0;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.isEmpty) continue;
      final found = i == 0 ? (target.startsWith(part) ? 0 : -1) : target.indexOf(part, at);
      if (found == -1) return false;
      at = found + part.length;
    }
    return !anchored || at == target.length;
  }

  /// Parses [text] for [agent], falling back to the `*` group when it names no other.
  ///
  /// A group is its `User-agent` lines and the rules under them; a blank line or a new
  /// `User-agent` after a rule starts the next group.
  static _Robots parse(String text, String agent) {
    final wanted = agent.toLowerCase();
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
          if (value.isNotEmpty) rules.add((value, false));
        case 'allow':
          sawRule = true;
          if (value.isNotEmpty) rules.add((value, true));
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
        if (g.agents.any((a) => a != '*' && wanted.contains(a))) g,
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
