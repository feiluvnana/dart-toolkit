// What a platform is: the kinds of media it has, how its handles and URLs
// read, how it logs in and how it explores a user. A new site (TikTok,
// Bluesky, …) is one file in platforms/ extending [Platform], listed in
// platforms.dart; nothing else changes.
library;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';

import 'dashboard.dart';
import 'job.dart';

/// The kinds of media every platform shares: the `--category` values and
/// the folders under each user. A platform offers the ones it has.
enum Kind {
  posts('the feed: photos, videos, carousels, tweets'),
  stories('what is up now'),
  highlights('saved stories'),
  photos('the photos tab'),
  videos('the videos and reels tabs'),
  albums('photo albums'),
  profiles('profile pictures, banners and covers');

  const Kind(this.about);
  final String about;

  /// The folder under the user: the kind's name.
  String get folder => name;
}

/// A user (or, with [post], one post of theirs) on [platform].
final class Target {
  const Target(this.platform, this.user, {this.post});
  final Platform platform;
  final String user;
  final String? post;

  @override
  bool operator ==(Object other) =>
      other is Target &&
      other.platform == platform &&
      other.user.toLowerCase() == user.toLowerCase() &&
      other.post == post;

  @override
  int get hashCode => Object.hash(platform, user.toLowerCase(), post);

  @override
  String toString() => '${platform.code}:$user';
}

abstract class Platform {
  /// `ins`, `twt`, `fbk`: the handle prefix (`twt:user`), the downloads/
  /// folder, and the session file `.<code>.session` next to the script.
  String get code;

  /// How people call it: `Instagram`.
  String get name;

  /// The site, sent as the CDN referer.
  String get site;

  /// What it offers, in the order the dashboard shows them.
  List<Kind> get kinds;

  /// Folders older runs used, renamed into a kind's on the next run.
  Map<String, Kind> get renamed => const {};

  /// Whether [input] is one of its URLs.
  bool matches(String input);

  /// A handle or URL as a [Target]; a [FormatException] when it names no user.
  Target parse(String input);

  /// Cookies one of which proves a login (`sessionid`).
  Set<String> get loginCookies;

  /// The API client over the session [jar].
  Client client(Cookies jar);

  /// Looks the target up ([Job.open]), then lists what [Job.wants] into [Job.add].
  Future<void> explore(Job j);

  /// The client from `.<code>.session` (a cookies.txt export plus a
  /// "user-agent: …" line), or null without a login.
  Future<Client?> login() async {
    final jar = await Cookies.load(Fs.scriptDir().file('.$code.session'));
    return loginCookies.any((c) => jar[c] != null) ? client(jar) : null;
  }

  /// [calls] per [per] with a [pause] between calls; waits show on the board.
  Rate rate(int calls, Duration per, {Duration pause = const Duration(seconds: 2)}) => Rate(
    calls,
    per,
    pause: pause,
    onWait: (w) => board.holdPause('$name rate limit: waiting ${w.human()}', w, platform: code),
  );

  /// [e] in plain words.
  Object explain(Object e) => switch (e) {
    HttpStatusException(status: 404, :final url) => 'not found: $url',
    HttpStatusException(status: final status && (401 || 403), :final url) =>
      '$name refused (HTTP $status): the login in .$code.session may have expired ($url)',
    HttpStatusException(status: 429, :final url) => '$name rate limit (HTTP 429): try again in 15 minutes ($url)',
    _ => e,
  };
}

/// `@name`, `name/`, `name?x` → `name`; [what] names the platform in the error.
String username(String input, String what) {
  final h = input.trim().replaceFirst(RegExp(r'^@'), '').split(RegExp('[/?#]')).first;
  if (h.isEmpty) throw FormatException('expected a $what username or profile URL, got "$input"');
  return h;
}
