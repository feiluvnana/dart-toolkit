// Downloads Instagram profiles: photos, reels, stories, highlights and
// profile pictures.
//
//   dart run projects/instaloader/instaloader.dart download
//       [--category=photo,reel,story,highlight,profile] <user>... [--all] [--reset]
//
// Every user and category is fetched at once, and files download 8 at a
// time. A full-screen dashboard shows each user's folders (bar, new/had/
// failed, size, what its explorer is doing), every file in flight with its
// bytes and speed, and a log. Keys: r retries every failure, l saves the
// log to .instaloader.log next to this script, q quits; clicking the log's
// header shows only failures; drag to select and copy, wheel or scrollbar
// to scroll. A table per user prints after. Without a terminal, the log prints line by line.
// Tracking files are .instaloader*: each user's .instaloader.json (what the
// runs saw) and .instaloader-cursor-* (where a listing stopped).
//
// Files go to downloads/<user>/ next to this script: photos/<day>/ and
// reels/<day>/ (each post's caption beside it as <code>.txt), stories/<day>/,
// highlights/<title>/, and profiles/ (every profile picture seen, HD with a
// login). A rerun only lists posts newer than what's on disk, and picks up an
// interrupted run where it stopped; --all lists every post again.
//
// Once a week (and with --all) every post is listed to catch hidden or
// re-shown ones; those, edited albums (new items take the next file
// numbers), changed highlights and a new profile picture are reported and
// notified. Nothing is ever deleted, except by --reset (it asks first).
//
// Without a login you only get the latest 12 posts. To log in, export your
// instagram.com cookies as cookies.txt into .session (next to this script)
// and add a line `user-agent: <navigator.userAgent>` of the same browser.
//
// If Instagram wants you to verify the account, the script stops: do it in
// the browser or the app, then run again. Requests are paced like Python's
// Instaloader; after a 429, wait about 15 minutes and don't run two at once.
library;

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';

import 'dashboard.dart' as dashboard;
import 'download.dart' as download;
import 'instagram.dart' as instagram;

String name(String input) =>
    RegExp(r'^(?:.*instagram\.com/)?@?([A-Za-z0-9_.]+)').firstMatch(input.trim())?[1] ??
    (throw FormatException('expected a username or profile URL, got "$input"'));

final users = Rest('user', 'Usernames or profile URLs.', required: true, parse: name);
final kinds = Multi('category', 'What to grab.', values: download.Kind.values, or: [download.Kind.all]);
final all = Flag('all', 'List every post again, not only the new ones.');
final reset = Flag('reset', 'Delete the chosen categories (after asking) and download them again.');

Future<void> main(List<String> args) => Command(
  'instaloader',
  'Download Instagram profiles.',
  commands: [
    Command(
      'download',
      'Download photos, reels, stories or highlights.',
      params: [kinds, all, reset, users],
      handler: run,
    ),
  ],
).run(args);

Future<void> run(Context c) async {
  final api = await instagram.login();
  // all: whatever the login allows.
  final want = {
    for (final k in c(kinds))
      ...(k == .all ? download.Kind.values.where((k) => k != .all && (api != null || !k.login)) : [k]),
  };
  if (api == null && want.any((k) => k.login)) {
    throw const UsageException('Stories and highlights need a login: see .session in instaloader.dart.');
  }
  await dashboard.watch(() async {
    final added = await download.run(
      c(users),
      want,
      api,
      Fs.scriptDir().dir('downloads'),
      all: c(all),
      reset: c(reset),
    );
    Console.notify('instaloader: done, $added new files');
  });
}
