// Downloads Instagram, Twitter and Facebook profiles (photos, videos,
// stories, albums, highlights, profile pictures) or single posts.
//
//   dart run projects/medialoader/medialoader.dart download <user|url>...
//       [--platform=ins|twt|fbk] [--category=posts,stories,…] [--since=2024-05-01]
//       [--compress | --quality=<1-100> | --image-quality=<1-100> --video-quality=<1-100>]
//       [--all] [--reset] [--dry-run]
//   dart run projects/medialoader/medialoader.dart update [same options]
//
// Categories are shared by every platform; each has the ones it offers:
// Instagram posts, stories, highlights, profiles; Twitter posts, profiles;
// Facebook all seven (posts, stories, highlights, photos, videos, albums,
// profiles). A post URL (instagram.com/p/…, x.com/<user>/status/…)
// downloads that post.
//
// Every platform needs a login session next to this script: .ins.session,
// .twt.session, .fbk.session (a cookies.txt export of the site plus a
// "user-agent: <ua>" line).
//
// `update` downloads every user in downloads/ again with the categories it
// has folders for.
//
// Every user and category is fetched at once, and files download 8 at a
// time. A full-screen dashboard shows each user's folders (bar, new/had/
// failed, size, what its explorer is doing), every file in flight with its
// speed, and a log. Keys: r retries every failure, l saves the log to
// .medialoader.log next to this script, f shows only failures and rate
// limits, q quits; drag to select and copy. A table per user prints after. Without a terminal the log prints line by
// line and failures are retried once.
//
// Files go to downloads/<platform>/<user>/<category>/ next to this script:
// posts, photos, videos and stories by month, highlights/<title>/,
// albums/<title>/, and profiles/ (every picture seen), each dated to its
// post. Each user's .<platform>.json remembers what the runs saw and
// .<platform>-cursor-<category> where a listing stopped: a rerun lists only
// what is newer than the files on disk and continues an interrupted run;
// --all lists everything again.
library;

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';

import 'job.dart';
import 'platform.dart';
import 'platforms.dart';
import 'run.dart' as run;

final platformOpt = Opt<String?>(
  'platform',
  'Platform of plain usernames: ${platforms.map((p) => '${p.code} (${p.name})').join(', ')}; default ${platforms.first.code}.',
);
final users = Rest<String>('user', 'Usernames, profile or post URLs, or prefixed handles (twt:user).', required: true);
final categories = Multi<Kind>(
  'category',
  'What to grab; a platform takes the ones it has.',
  values: Kind.values,
  or: Kind.values,
);
final since = Opt<DateTime?>(
  'since',
  'Only what was posted on or after this date (2024-05-01).',
  parse: DateTime.parse,
);
final all = Flag('all', 'List every post again, not only the new ones.');
final reset = Flag('reset', 'Delete the chosen categories (after asking) and download them again.');
final dryRun = Flag('dry-run', 'List what would download; write nothing.');
final compress = Flag('compress', 'Compress with the recommended qualities (image 85, video 80).');
final quality = Opt<int?>('quality', 'Compression quality of images and videos.', min: 1, max: 100);
final imageQuality = Opt<int?>('image-quality', 'Image compression quality.', min: 1, max: 100);
final videoQuality = Opt<int?>('video-quality', 'Video compression quality.', min: 1, max: 100);
final shared = <Param<Object?>>[since, compress, quality, imageQuality, videoQuality, all, reset, dryRun];

Options options(Context c) => (
  all: c(all),
  reset: c(reset),
  dry: c(dryRun),
  since: c(since),
  image: c(imageQuality) ?? c(quality) ?? (c(compress) ? 85 : null),
  video: c(videoQuality) ?? c(quality) ?? (c(compress) ? 80 : null),
);

final root = Fs.scriptDir().dir('downloads');

Future<void> main(List<String> args) async {
  await Command(
    'medialoader',
    'Download ${platforms.map((p) => p.name).join(', ')} profiles.',
    version: '1.1.0',
    commands: [
      Command(
        'download',
        'Download profiles or single posts.',
        params: [platformOpt, categories, ...shared, users],
        handler: get,
      ),
      Command(
        'update',
        'Update every downloaded user with the categories it already has.',
        params: shared,
        handler: (c) async {
          final wants = await run.discover(root);
          if (wants.isEmpty) return Console.log('medialoader: nothing downloaded yet, nothing to update.');
          await run.run(wants, root, options(c));
        },
      ),
    ],
  ).run(args);
}

Future<void> get(Context c) async {
  final List<Target> targets;
  try {
    targets = [for (final u in c(users)) parseTarget(u, c(platformOpt))];
  } on FormatException catch (e) {
    throw UsageException(e.message);
  }
  final chosen = c(categories).toSet();
  final wants = {
    for (final t in targets) t: t.post != null ? {Kind.posts} : {...t.platform.kinds.where(chosen.contains)},
  };
  // A user whose platform has none of the categories is skipped, unless all are.
  String offers(Target t) => '${t.platform.name} has ${t.platform.kinds.map((k) => k.name).join(', ')}';
  final none = [
    for (final MapEntry(:key, :value) in wants.entries)
      if (value.isEmpty) key,
  ];
  if (none.length == wants.length) {
    throw UsageException('nothing to download: ${{for (final t in none) offers(t)}.join('; ')}');
  }
  for (final t in none) {
    Console.log('skipping @${t.user}: ${offers(t)}');
    wants.remove(t);
  }
  await run.run(wants, root, options(c));
}
