// Every platform medialoader knows. A new one is a file in platforms/ and a
// line here.
library;

import 'platform.dart';
import 'platforms/facebook.dart' as facebook;
import 'platforms/instagram.dart' as instagram;
import 'platforms/twitter.dart' as twitter;

final platforms = <Platform>[instagram.platform, twitter.platform, facebook.platform];

/// A handle (`twt:user`), URL, or username for [fallback] (default: the first).
Target parseTarget(String input, [String? fallback]) {
  final s = input.trim();
  for (final p in platforms) {
    if (s.toLowerCase().startsWith('${p.code}:')) return p.parse(s.substring(p.code.length + 1));
  }
  for (final p in platforms) {
    if (p.matches(s)) return p.parse(s);
  }
  final p = fallback == null
      ? platforms.first
      : platforms.firstWhere(
          (p) => p.code == fallback.trim().toLowerCase(),
          orElse: () =>
              throw FormatException('unknown platform "$fallback": ${platforms.map((p) => p.code).join(', ')}'),
        );
  return p.parse(s);
}
