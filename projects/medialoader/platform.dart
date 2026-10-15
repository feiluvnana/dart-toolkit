// Pluggable platform interface and registry for medialoader.
library;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';

import 'dashboard.dart';
import 'download.dart';
import 'facebook.dart' as facebook;
import 'instagram.dart' as instagram;
import 'twitter.dart' as twitter;

/// A media category supported by a platform (e.g. post, profile, story, highlight).
final class Category {
  const Category(
    this.name, {
    String? folder,
    this.help = '',
  }) : folder = folder ?? '${name}s';

  /// Category name used in CLI flags (e.g. 'post', 'profile', 'story').
  final String name;

  /// Folder name on disk under `downloads/<platform>/<user>/` (e.g. 'posts', 'profiles').
  final String folder;

  /// Optional brief description.
  final String help;

  bool matches(String input) {
    final s = input.trim().toLowerCase();
    return name.toLowerCase() == s || folder.toLowerCase() == s;
  }

  @override
  bool operator ==(Object other) => other is Category && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => name;
}

/// A target user to download from a specific platform.
final class Target {
  const Target(this.platform, this.user);
  final Platform platform;
  final String user;

  @override
  bool operator ==(Object other) =>
      other is Target && other.platform.code == platform.code && other.user.toLowerCase() == user.toLowerCase();

  @override
  int get hashCode => Object.hash(platform.code, user.toLowerCase());

  @override
  String toString() => '${platform.code}:$user';
}

/// Abstract contract for a media source platform (e.g. ins, twt, fbk).
abstract interface class Platform {
  /// 3-letter lowercase platform code (e.g. 'ins', 'twt', 'fbk').
  String get code;

  /// Display name of the platform (e.g. 'instagram', 'twitter', 'facebook').
  String get name;

  /// Categories supported by this platform.
  List<Category> get categories;

  /// Whether an input URL or string belongs to this platform.
  bool matches(String input);

  /// Extracts the canonical username from a handle or URL.
  String parseUser(String input);

  /// Authenticates using the platform's session file (.<code >.session) if present.
  Future<Client?> login();

  /// Closes the client session and releases sockets.
  Future<void> close(Client? api);

  /// Formats platform-specific errors into plain words.
  Object explain(Object error);

  /// Explores user media categories and queues files for download.
  Future<void> exploreUser({
    required User u,
    required Set<String> categories,
    required Client? api,
    required Dir userDir,
    required Index index,
    required Queue queue,
    required bool all,
    required List<Future<Results>> batches,
    required void Function(List<Part> parts, String what, {bool done}) phase,
    required void Function(String change) changed,
  });
}

/// All registered platforms.
final platforms = <Platform>[
  instagram.platform,
  twitter.platform,
  facebook.platform,
];

/// Finds a registered platform by its 3-letter code.
Platform platformByCode(String code) {
  final match = platforms.firstWhere(
    (p) => p.code.toLowerCase() == code.toLowerCase(),
    orElse: () => throw FormatException('Unknown platform code "$code". Available: ${platforms.map((p) => p.code).join(', ')}'),
  );
  return match;
}

/// Parses a user input (URL, prefixed handle like 'twt:elonmusk', or username) into a [Target].
Target parseTarget(String input, [String? defaultPlatform]) {
  final trimmed = input.trim();

  // 1. Explicit 3-letter prefix (e.g. "ins:user", "twt:user", "fbk:user")
  for (final p in platforms) {
    if (trimmed.toLowerCase().startsWith('${p.code}:')) {
      return Target(p, p.parseUser(trimmed.substring(p.code.length + 1)));
    }
  }

  // 2. URL matching
  for (final p in platforms) {
    if (p.matches(trimmed)) {
      return Target(p, p.parseUser(trimmed));
    }
  }

  // 3. Explicit default platform flag
  if (defaultPlatform != null && defaultPlatform.trim().isNotEmpty) {
    final p = platformByCode(defaultPlatform.trim());
    return Target(p, p.parseUser(trimmed));
  }

  // 4. Default fallback: instagram
  return Target(instagram.platform, instagram.platform.parseUser(trimmed));
}
