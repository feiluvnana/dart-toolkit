// What every platform provides, and the registry. Import with `as platform`.
library;

import 'package:dart_toolkit/http.dart';

import 'download.dart';
import 'facebook.dart' as facebook;
import 'instagram.dart' as instagram;
import 'twitter.dart' as twitter;

/// A kind of media: its name on the command line and its folder on disk.
final class Category {
  const Category(this.name, [String? folder]) : folder = folder ?? '${name}s';
  final String name, folder;
}

/// A user (or, with [post], one post of theirs) on [platform].
final class Target {
  const Target(this.platform, this.user, {this.post});
  final Platform platform;
  final String user;
  final String? post;

  @override
  bool operator ==(Object other) =>
      other is Target && other.platform == platform && other.user.toLowerCase() == user.toLowerCase() && other.post == post;

  @override
  int get hashCode => Object.hash(platform, user.toLowerCase(), post);

  @override
  String toString() => '${platform.code}:$user';
}

abstract interface class Platform {
  /// `ins`, `twt`, `fbk`: the prefix, the downloads/ folder and the session file (`.<code>.session`).
  String get code;
  String get name;

  /// The site, sent as the CDN referer.
  String get site;
  List<Category> get categories;
  bool matches(String input);

  /// A handle or URL as a [Target]; a [FormatException] when it names no user.
  Target parse(String input);

  /// The logged-in client from the session file, or null without one.
  Future<Client?> login();

  /// [error] in plain words.
  Object explain(Object error);

  /// Resolves the target ([Job.open]), then lists its media into [Job.add].
  Future<void> explore(Job j);
}

final platforms = <Platform>[instagram.platform, twitter.platform, facebook.platform];

/// A handle (`twt:user`), URL, or username for [fallback] (default Instagram).
Target parseTarget(String input, [String? fallback]) {
  final s = input.trim();
  for (final p in platforms) {
    if (s.toLowerCase().startsWith('${p.code}:')) return p.parse(s.substring(4));
  }
  for (final p in platforms) {
    if (p.matches(s)) return p.parse(s);
  }
  final p = fallback == null
      ? instagram.platform
      : platforms.firstWhere(
          (p) => p.code == fallback.trim().toLowerCase(),
          orElse: () => throw FormatException('unknown platform "$fallback": ${platforms.map((p) => p.code).join(', ')}'),
        );
  return p.parse(s);
}

/// `@name`, `name/`, `name?x` → `name`; [what] names the platform in the error.
String username(String input, String what) {
  final h = input.trim().replaceFirst(RegExp(r'^@'), '').split(RegExp('[/?#]')).first;
  if (h.isEmpty) throw FormatException('expected a $what username or profile URL, got "$input"');
  return h;
}
