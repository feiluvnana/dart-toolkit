/// # Robots.txt Parser & Matcher
///
/// Parses `robots.txt` files according to RFC 9309 (Robots Exclusion Protocol).
/// Supports User-agent matching, Allow and Disallow directives with wildcards (`*`)
/// and end-of-pattern anchors (`$`), Crawl-delay, and Sitemap directives.
library;

import 'dart:async';

import 'net.dart';

/// A single Allow or Disallow rule in a `robots.txt` file.
class RobotsRule {
  /// The pattern to match against target URL paths.
  final String pattern;

  /// Whether this is an Allow rule (`true`) or Disallow rule (`false`).
  final bool allow;

  final RegExp _regex;

  /// Creates a robots rule.
  RobotsRule(this.pattern, {required this.allow})
    : _regex = _compilePattern(pattern);

  /// Path length used for specificity tie-breaking in RFC 9309.
  int get length => pattern.length;

  /// Whether [path] matches this rule.
  bool matches(String path) {
    if (pattern.isEmpty) {
      // Empty Disallow means "allow all", empty Allow means nothing.
      return false;
    }
    return _regex.hasMatch(path);
  }

  static RegExp _compilePattern(String raw) {
    if (raw.isEmpty) return RegExp(r'^$');
    final buffer = StringBuffer('^');
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      if (ch == '*') {
        buffer.write('.*');
      } else if (ch == r'$' && i == raw.length - 1) {
        buffer.write(r'$');
      } else {
        buffer.write(RegExp.escape(ch));
      }
    }
    return RegExp(buffer.toString());
  }
}

/// A parsed `robots.txt` document.
class Robots {
  final Map<String, List<RobotsRule>> _rules;
  final Map<String, Duration> _delays;

  /// All Sitemap URLs declared in the document.
  final List<Uri> sitemaps;

  /// Creates a Robots instance with pre-parsed rules and sitemaps.
  Robots({
    Map<String, List<RobotsRule>> rules = const {},
    Map<String, Duration> delays = const {},
    this.sitemaps = const [],
  }) : _rules = rules,
       _delays = delays;

  /// All user agents explicitly declared in the robots file.
  List<String> get agents => _rules.keys.toList();

  /// Parses [content] of a `robots.txt` file.
  factory Robots.parse(String content) {
    final rules = <String, List<RobotsRule>>{};
    final delays = <String, Duration>{};
    final sitemaps = <Uri>[];

    final lines = content.split(RegExp(r'\r?\n'));
    var currentAgents = <String>[];
    // Consecutive `User-agent` lines share one group; the first directive of
    // any other kind closes it, so the next `User-agent` starts a fresh group.
    // Tracking that explicitly — rather than inferring it from whether rules
    // were collected — keeps a group holding only `Crawl-delay` from absorbing
    // the rules of the group that follows it.
    var groupOpen = false;

    for (var line in lines) {
      // Strip comments
      final hashIdx = line.indexOf('#');
      if (hashIdx != -1) line = line.substring(0, hashIdx);
      line = line.trim();
      if (line.isEmpty) continue;

      final colonIdx = line.indexOf(':');
      if (colonIdx == -1) continue;

      final directive = line.substring(0, colonIdx).trim().toLowerCase();
      final value = line.substring(colonIdx + 1).trim();

      switch (directive) {
        case 'user-agent':
          final agent = value.toLowerCase();
          if (!groupOpen) currentAgents = <String>[];
          groupOpen = true;
          currentAgents.add(agent);
          for (final a in currentAgents) {
            rules.putIfAbsent(a, () => []);
          }

        case 'disallow':
          groupOpen = false;
          if (currentAgents.isEmpty) currentAgents = ['*'];
          for (final a in currentAgents) {
            rules.putIfAbsent(a, () => []).add(RobotsRule(value, allow: false));
          }

        case 'allow':
          groupOpen = false;
          if (currentAgents.isEmpty) currentAgents = ['*'];
          for (final a in currentAgents) {
            rules.putIfAbsent(a, () => []).add(RobotsRule(value, allow: true));
          }

        case 'crawl-delay':
          groupOpen = false;
          if (currentAgents.isEmpty) currentAgents = ['*'];
          final seconds = double.tryParse(value);
          if (seconds != null && seconds >= 0) {
            final dur = Duration(milliseconds: (seconds * 1000).round());
            for (final a in currentAgents) {
              delays[a] = dur;
            }
          }

        case 'sitemap':
          final uri = Uri.tryParse(value);
          if (uri != null && uri.hasScheme) {
            sitemaps.add(uri);
          }
      }
    }

    return Robots(
      rules: rules,
      delays: delays,
      sitemaps: List.unmodifiable(sitemaps),
    );
  }

  /// Fetches `/robots.txt` from the host in [url] and parses it.
  ///
  /// The answer to a robots.txt that is not there is not the same as the
  /// answer to one that could not be fetched, and RFC 9309 section 2.3.1 says
  /// so:
  ///
  /// - **2xx** — the rules in the body apply.
  /// - **4xx** (2.3.1.3) — the host has no rules, so everything is allowed.
  /// - **5xx** (2.3.1.4) — the rules are unreachable, not absent. Crawling is
  ///   disallowed outright rather than assumed free, so a server having a bad
  ///   day is not read as an invitation.
  ///
  /// A transport error — DNS, a refused connection, a timeout — is treated as
  /// 4xx rather than 5xx. That is a deliberate departure: the RFC's
  /// "unreachable" case is about a server that answered badly, and stopping a
  /// whole crawl over one failed lookup costs more than it protects.
  static Future<Robots> load(Uri url, {HttpClient? client}) async {
    final robotsUrl = Uri(
      scheme: url.scheme.isNotEmpty ? url.scheme : 'https',
      userInfo: url.userInfo,
      host: url.host,
      port: url.hasPort ? url.port : null,
      path: '/robots.txt',
    );

    try {
      final c = client ?? net.http;
      final res = await c.get(robotsUrl);
      if (res.ok) {
        return Robots.parse(res.body);
      }
      if (res.status >= 500) return _closed;
    } catch (_) {
      // Ignore network errors, fall back to allow-all.
    }
    return Robots();
  }

  /// The document a host that could not answer is read as having: nothing is
  /// allowed. See [load].
  static final Robots _closed = Robots(
    rules: {
      '*': [RobotsRule('/', allow: false)],
    },
  );

  /// The rule group that applies to [agent], per RFC 9309 section 2.2.1.
  ///
  /// A declared `User-agent` matches when it is a case-insensitive prefix of
  /// the crawler's product token, so a `MyBot` group governs a crawler calling
  /// itself `MyBot/1.0`. The longest such group wins, falling back to `*`.
  List<RobotsRule> group(String agent) {
    final full = agent.toLowerCase().trim();
    final exact = _rules[full];
    if (exact != null) return exact;

    final token = full.split('/').first.split(' ').first.trim();
    final byToken = _rules[token];
    if (byToken != null) return byToken;

    List<RobotsRule>? best;
    var bestLength = -1;
    for (final entry in _rules.entries) {
      if (entry.key == '*') continue;
      if (token.startsWith(entry.key) && entry.key.length > bestLength) {
        best = entry.value;
        bestLength = entry.key.length;
      }
    }
    return best ?? _rules['*'] ?? const [];
  }

  /// Whether [url] is allowed to be crawled by [agent].
  ///
  /// Evaluates specificity rules per RFC 9309: the longest matching rule wins.
  /// If an Allow and Disallow rule have the exact same match length, Allow wins.
  /// If no rules match, the URL is allowed.
  bool allowed(Uri url, {String agent = '*'}) {
    final targetPath = url.hasQuery ? '${url.path}?${url.query}' : url.path;
    final path = targetPath.isEmpty ? '/' : targetPath;

    final candidateRules = group(agent);

    RobotsRule? bestMatch;

    for (final rule in candidateRules) {
      if (rule.matches(path)) {
        if (bestMatch == null || rule.length > bestMatch.length) {
          bestMatch = rule;
        } else if (rule.length == bestMatch.length &&
            rule.allow &&
            !bestMatch.allow) {
          // Allow wins ties
          bestMatch = rule;
        }
      }
    }

    if (bestMatch != null) {
      return bestMatch.allow;
    }
    return true;
  }

  /// The declared crawl delay for [agent], if any.
  ///
  /// Matched by the same product-token rules as [group]. A crawl started
  /// with `.robots()` waits at least this long between requests to the host.
  Duration? delay({String agent = '*'}) {
    final full = agent.toLowerCase().trim();
    final exact = _delays[full];
    if (exact != null) return exact;

    final token = full.split('/').first.split(' ').first.trim();
    final byToken = _delays[token];
    if (byToken != null) return byToken;

    Duration? best;
    var bestLength = -1;
    for (final entry in _delays.entries) {
      if (entry.key == '*') continue;
      if (token.startsWith(entry.key) && entry.key.length > bestLength) {
        best = entry.value;
        bestLength = entry.key.length;
      }
    }
    return best ?? _delays['*'];
  }
}
