// Downloads every photo, reel, story or highlight of an Instagram profile.
//
//   dart run projects/instaloader/instaloader.dart <username> [photos|reels|stories|highlights]
//
// Files go to downloads/<user>/<section>/ next to this script. A rerun only
// lists posts newer than what's on disk, and picks up an interrupted run where
// it stopped. Pass --all to list every post again.
//
// Without a login you only get the first 12 posts, and no stories or
// highlights. To log in, export your instagram.com cookies from your normal
// browser as cookies.txt into .session (next to this script), then add a line
// `user-agent: <navigator.userAgent>` so the requests look like they come
// from that same browser.
//
// If Instagram wants you to verify the account, it redirects every request to
// that page. The script stops there: do the check in the browser or the app,
// then run it again.
//
// Requests are paced like Python's Instaloader. If you still get a 429, wait
// about 15 minutes before trying again, and don't run two at once.
library;

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/pool.dart';

import 'instagram.dart';
import 'media.dart';

final userArg = Arg(
  'username',
  'Instagram username or profile URL.',
  required: true,
  parse: (input) {
    final match = RegExp(r'^(?:.*instagram\.com/)?@?([A-Za-z0-9_.]+)').firstMatch(input.trim());
    if (match == null) throw FormatException('expected a username or profile URL, got "$input"');
    return match[1]!;
  },
);
final sectionArg = Arg('section', 'What to grab.', values: Section.values, or: Section.photos);
final allFlag = Flag('all', 'List every post again, not only the new ones.');

Future<void> main(List<String> args) => Command(
  'instaloader',
  'Download all photos, reels, stories or highlights.',
  params: [userArg, sectionArg, allFlag],
  handler: run,
).run(args);

Future<void> run(Context c) async {
  final username = c(userArg);
  final section = c(sectionArg);
  final session = await loadSession();
  if (session == null && (section == Section.stories || section == Section.highlights)) {
    throw const UsageException('Stories and highlights need a login: see .session at the top of this script.');
  }

  try {
    await download(username, section, session == null ? null : apiClient(session), all: c(allFlag));
  } on HttpStatusException catch (e) {
    if (e.status == 404) throw Exception('User not found: "$username".');
    if (e.status == 401 || e.status == 403 || e.status == 429) {
      throw Exception(
        'Instagram refused ${e.method} ${e.url} (HTTP ${e.status}). Your IP is probably rate limited: '
        'wait about 15 minutes, then try again.',
      );
    }
    rethrow;
  }
}

Future<void> download(String username, Section section, Client? api, {bool all = false}) async {
  final profile = await Console.spin('looking up @$username', loadProfile(username));
  final user = profile.username;
  final dir = Fs.scriptDir().dir('downloads').dir(Fs.sanitize(user)).dir(section.name);
  Console.log('@$user: saving ${section.name} to ${dir.path()}');

  // Files already on disk are skipped; the bool says whether one was new.
  // Each download gets its own line with its size and speed.
  Future<bool> save(Download f) async {
    if (await f.to.exists()) return false;
    await (cdn.get(f.url) | Console.bar(null, label: '  ${f.to.name()}', keep: false) > f.to);
    return true;
  }

  final bar = Console.bar(null, label: 'files done');
  final batches = <Future<List<Outcome<Download, bool>>>>[];
  // One post at a time (a carousel's files in parallel), so the screen only
  // shows the post being downloaded. The listing goes ahead meanwhile.
  var previous = Future<void>.value();
  Future<List<Outcome<Download, bool>>> start(List<List<Download>> posts) {
    final batch = previous.then((_) async {
      final results = <Outcome<Download, bool>>[];
      for (final files in posts) {
        results.addAll(await Pool.settle(files, save, limit: 10, onDone: bar.tick));
      }
      return results;
    });
    previous = batch;
    batches.add(batch);
    return batch;
  }

  final List<Outcome<Download, bool>> results;
  try {
    switch (section) {
      case Section.photos || Section.reels:
        if (api == null) {
          Console.log('@$user: not logged in, so only the latest 12 posts (see .session in the script header)');
          final files = postFiles(profile.posts, dir, section);
          Console.log('${describe(profile.posts)}, ${fileCount(files)} files');
          start(files);
          break;
        }
        await listPosts(api.copy(rate: feedRate), user, dir, section, start, all: all);
      case Section.stories:
        final items = await fetchReel(api!, profile.id, user);
        Console.log('@$user: ${items.length} stories right now');
        start(storyFiles(items, dir, section));
      case Section.highlights:
        Console.log('@$user: ${profile.highlights.length} highlights');
        for (final highlight in profile.highlights) {
          final items = await fetchReel(api!, 'highlight:${highlight.id}', user);
          Console.log('highlight "${highlight.title}": ${items.length} items');
          start(storyFiles(items, dir.dir(Fs.sanitize(highlight.title)), section));
        }
    }
    results = [for (final batch in await Future.wait(batches)) ...batch];
  } finally {
    await bar.close();
  }

  if (results.isEmpty) return Console.log('@$user has no ${section.name}');
  final failed = results.failures();
  for (final f in failed) {
    Console.log('✗ ${f.item.to.name()}: ${f.error}');
  }
  final saved = results.values();
  final added = saved.where((isNew) => isNew).length;
  final parts = [
    '$added new',
    if (saved.length > added) '${saved.length - added} already downloaded',
    if (failed.isNotEmpty) '${failed.length} failed (run again to retry them)',
  ];
  Console.log('@$user ${section.name}: ${parts.join(', ')}');
  Console.notify('instaloader: @$user ${section.name} done, $added new');
}

// Posts come newest first, so listing stops at the first page that is already
// on disk. A run that got cut off saves where it was in .cursor and the next
// run continues from there. The cursor only moves past a page once all of its
// files are downloaded, so a failed file is retried next time.
Future<void> listPosts(
  Client feed,
  String user,
  Dir dir,
  Section section,
  Future<List<Outcome<Download, bool>>> Function(List<List<Download>>) start, {
  required bool all,
}) async {
  final cursorFile = dir.file('.cursor');
  final unfinished = all ? '' : (await cursorFile.text(or: '')).trim();

  var saving = Future<void>.value();
  var ok = true;
  // Downloads run in the background; once a page's files are done (in page
  // order), save the cursor after it, or delete the file when listing is done.
  void queue(List<List<Download>> files, {required bool track, String? next}) {
    final batch = start(files);
    saving = saving.then((_) async {
      if (!track) return;
      if ((await batch).failures().isNotEmpty) ok = false;
      if (!ok) return;
      if (next != null) {
        await cursorFile.write(next);
      } else if (await cursorFile.exists()) {
        await cursorFile.delete();
      }
    });
  }

  Future<bool> onDisk(List<List<Download>> posts) async {
    if (posts.isEmpty) return false;
    for (final f in posts.expand((files) => files)) {
      if (!await f.to.exists()) return false;
    }
    return true;
  }

  // Even when the run fails, let the pages already listed finish and save
  // their cursor, so the next run continues from there.
  try {
    // New posts, down to the first page we already have. While an older listing
    // is still unfinished, its cursor is left alone.
    String? cursor;
    var caughtUp = false;
    var n = 0;
    do {
      final page = await fetchPosts(feed, user, cursor);
      final files = postFiles(page.posts, dir, section);
      caughtUp = !all && await onDisk(files);
      cursor = page.next;
      n++;
      if (caughtUp) {
        Console.log(n == 1 ? '@$user: no new posts since the last run' : 'page $n: already downloaded, stopping here');
      } else {
        Console.log('page $n: ${describe(page.posts)}, ${fileCount(files)} files');
        queue(files, track: unfinished.isEmpty, next: cursor);
      }
    } while (!caughtUp && cursor != null);

    if (unfinished.isEmpty) {
      if (caughtUp) queue([], track: true); // nothing older is missing
    } else {
      Console.log('@$user: continuing the listing where the last run stopped');
      cursor = unfinished;
      do {
        final page = await fetchPosts(feed, user, cursor);
        final files = postFiles(page.posts, dir, section);
        cursor = page.next;
        n++;
        Console.log('page $n: ${describe(page.posts)}, ${fileCount(files)} files');
        queue(files, track: true, next: cursor);
      } while (cursor != null);
    }
  } finally {
    await saving;
  }
}

// "12 posts, 2024-05-01 to 2024-04-18"
String describe(List<Json> posts) {
  String day(Json post) =>
      DateTime.fromMillisecondsSinceEpoch(post.$('taken_at|taken_at_timestamp').or(0) * 1000).format('yyyy-MM-dd');
  if (posts.isEmpty) return 'no posts';
  final count = posts.length == 1 ? '1 post' : '${posts.length} posts';
  final (newest, oldest) = (day(posts.first), day(posts.last));
  return newest == oldest ? '$count, $newest' : '$count, $newest to $oldest';
}
