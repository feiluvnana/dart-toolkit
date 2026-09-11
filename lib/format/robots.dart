/// # robots.txt (`format.robots.*`)
///
/// The format codec, spelled exactly like [JsonAccessor] and the rest:
/// `parse`, `read`, `write`, `format`. A `robots.txt` arrives from outside
/// Dart with its own words — `User-agent`, `Disallow`, `Crawl-delay` — which
/// is Rule 1's definition of a subject, and Rule 2's fifth test puts a
/// subject with siblings in the family its siblings are in.
///
/// It was `net.robots(content)` through 5.5.0, in the domain whose own
/// library doc opens *this domain does not parse anything*.
///
/// ```dart
/// final rules = (await net.http.send(.get, 'https://x.test/robots.txt'.url))
///     .parse(format.robots);
/// rules.allowed('https://x.test/admin'.url, agent: 'MyBot');
/// ```
///
/// Fetching one is the crawl's job: `Crawl.obey()` reads `/robots.txt`
/// through the same [Send] the crawl uses, so politeness works against a
/// fixture transport — which `Robots.load` could not do, because it reached
/// for the shared client itself.
library;

import '../collection/sequence.dart';
import '../src/codec.dart';
import 'format.dart';

// ============================================================================
// ROBOTS.TXT (format.robots.*)
// ============================================================================

/// Entry point for `robots.txt`, reachable as `format.robots`.
class RobotsAccessor with FileCodec<Robots, Robots> implements Codec<Robots> {
  /// Creates the accessor. Prefer the shared `format.robots` instance.
  const RobotsAccessor();

  /// Parses [text] into a [Robots] evaluator.
  ///
  /// Text that is not `robots.txt` gives the empty document, which allows
  /// everything — the contract every reader in this library keeps.
  @override
  Robots parse(String text) => Robots.parse(text);

  /// Renders [value] back to `robots.txt` text.
  ///
  /// One group per user-agent, in the order they were parsed, with the
  /// `Sitemap` lines last. A round trip through [parse] and back gives a
  /// document with the same rules — not the same bytes, since comments and
  /// blank lines are not a robots.txt's content.
  @override
  String format(Robots value) => value.render();
}

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
  Sequence<String> get agents => Sequence(_rules.keys.toList());

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

  /// The rule group that applies to [agent], per RFC 9309 section 2.2.1.
  ///
  /// A declared `User-agent` matches when it is a case-insensitive prefix of
  /// the crawler's product token, so a `MyBot` group governs a crawler calling
  /// itself `MyBot/1.0`. The longest such group wins, falling back to `*`.
  Sequence<RobotsRule> group(String agent) => Sequence(_group(agent));

  List<RobotsRule> _group(String agent) {
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

    final candidateRules = _group(agent);

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

  /// Renders this document back to `robots.txt` text. See
  /// [RobotsAccessor.format].
  String render() {
    final out = StringBuffer();
    for (final entry in _rules.entries) {
      out.writeln('User-agent: ${entry.key}');
      final gap = _delays[entry.key];
      if (gap != null) {
        out.writeln('Crawl-delay: ${gap.inMilliseconds / 1000}');
      }
      for (final rule in entry.value) {
        out.writeln('${rule.allow ? 'Allow' : 'Disallow'}: ${rule.pattern}');
      }
      out.writeln();
    }
    for (final map in sitemaps) {
      out.writeln('Sitemap: $map');
    }
    return out.toString();
  }

  /// The document a host that could not answer is read as having: nothing is
  /// allowed.
  ///
  /// RFC 9309 section 2.3.1.4 — a 5xx means the rules are unreachable, not
  /// absent, so crawling is disallowed outright rather than assumed free. A
  /// crawl reaches this through `Crawl.obey`.
  static final Robots closed = Robots(
    rules: {
      '*': [RobotsRule('/', allow: false)],
    },
  );

  /// The declared crawl delay for [agent], if any.
  ///
  /// Matched by the same product-token rules as [group]. A crawl started
  /// with `Crawl.obey` waits at least this long between requests to the host.
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
