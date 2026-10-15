// Downloads Instagram, Twitter, and Facebook profiles: photos, videos/reels, stories,
// albums, highlights, and profile pictures.
//
//   dart run projects/medialoader/medialoader.dart download
//       [--platform=ins|twt|fbk] [--category=<cat,...>] [--image-quality=<1-100>]
//       [--video-quality=<1-100>] <user>... [--all] [--reset]
//   dart run projects/medialoader/medialoader.dart update
//       [--image-quality=<1-100>] [--video-quality=<1-100>] [--all] [--reset]
//
// Each platform has its own set of categories:
// - Instagram (ins): post, story, highlight, profile
// - Twitter (twt): tweet, profile
// - Facebook (fbk): photo, video, album, story, highlight, profile
//
// All platforms require a valid login session file next to this script:
// - Instagram: .ins.session (export instagram.com cookies + "user-agent: <ua>")
// - Twitter/X: .twt.session (export x.com cookies + "user-agent: <ua>")
// - Facebook: .fbk.session (export facebook.com cookies + "user-agent: <ua>")
//
// `update` re-downloads every user in downloads/ with the categories it
// already has across platforms: a user first downloaded with only some categories keeps only
// those.
//
// Every user and category is fetched at once, and files download 8 at a
// time. A full-screen dashboard shows each user's folders (bar, new/had/
// failed, size, what its explorer is doing), every file in flight with its
// bytes and speed, and a log. Keys: r retries every failure, l saves the
// log to .medialoader.log next to this script, q quits; clicking the log's
// header shows only failures and rate limits; drag to select and copy, wheel or scrollbar
// to scroll. A table per user prints after. Without a terminal, the log prints line by line.
// Tracking files are .<platform>*: each user's .<platform>.json (what the
// runs saw) and .<platform>-cursor-* (where a listing stopped).
//
// Files go to downloads/<platform>/<user>/ next to this script: posts/<month>/,
// tweets/<month>/, photos/<month>/, videos/<month>/, stories/<month>/,
// highlights/<title>/, albums/<title>/, and profiles/ (every profile picture seen). A rerun
// only lists posts/tweets newer than what's on disk, and picks up an interrupted
// run where it stopped; --all lists every post/tweet again.
library;

import 'dart:io' show exit;

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';

import 'dashboard.dart' as dashboard;
import 'download.dart' as download;
import 'platform.dart' as platform;

final platformFlag = Opt<String?>('platform', 'Force platform code (ins, twt, fbk).');
final users = Rest<String>('user', 'Usernames, profile URLs, or prefixed handles (e.g. twt:user, ins:user, fbk:user).', required: true);

final allCategoryNames = {
  'all',
  for (final p in platform.platforms)
    for (final c in p.categories) ...[
      c.name,
      c.folder,
    ],
}.toList()..sort();

final categories = Multi<String>(
  'category',
  'What to grab (platform-specific, or "all").',
  values: allCategoryNames,
  or: const ['all'],
);
final all = Flag('all', 'List every post again, not only the new ones.');
final reset = Flag('reset', 'Delete the chosen categories (after asking) and download them again.');

int _parseQuality(String raw) {
  var s = raw.trim();
  if (s.endsWith('%')) s = s.substring(0, s.length - 1).trim();
  final v = int.tryParse(s);
  if (v == null || v < 1 || v > 100) {
    throw const FormatException('must be between 1 and 100');
  }
  return v;
}

const defaultImageQuality = 85;
const defaultVideoQuality = 80;

final compressFlag = Flag(
  'compress',
  'Enable compression with recommended defaults (image: $defaultImageQuality, video: $defaultVideoQuality).',
);
final qualityOpt = Opt<int?>(
  'quality',
  'Set custom compression quality for both image and video (1-100).',
  parse: _parseQuality,
);
final imageQuality = Opt<int?>(
  'image-quality',
  'Image compression quality (1-100, default: $defaultImageQuality when --compress is set).',
  parse: _parseQuality,
);
final videoQuality = Opt<int?>(
  'video-quality',
  'Video compression quality (1-100, default: $defaultVideoQuality when --compress is set).',
  parse: _parseQuality,
);
final compressImage = Opt<int?>(
  'compress-image',
  'Alias for --image-quality (1-100).',
  parse: _parseQuality,
);
final compressVideo = Opt<int?>(
  'compress-video',
  'Alias for --video-quality (1-100).',
  parse: _parseQuality,
);
final imageCompression = Opt<int?>(
  'image-compression',
  'Alias for --image-quality (1-100).',
  parse: _parseQuality,
);
final videoCompression = Opt<int?>(
  'video-compression',
  'Alias for --video-quality (1-100).',
  parse: _parseQuality,
);

final compressionParams = <Param<Object?>>[
  compressFlag,
  qualityOpt,
  imageQuality,
  videoQuality,
  compressImage,
  compressVideo,
  imageCompression,
  videoCompression,
];

(int?, int?) compressionSettings(Context c) {
  final isCompressed = c(compressFlag);
  final generalQuality = c(qualityOpt);

  final rawImg = c(imageQuality) ?? c(compressImage) ?? c(imageCompression) ?? generalQuality;
  final rawVid = c(videoQuality) ?? c(compressVideo) ?? c(videoCompression) ?? generalQuality;

  final img = rawImg ?? (isCompressed ? defaultImageQuality : null);
  final vid = rawVid ?? (isCompressed ? defaultVideoQuality : null);

  return (img, vid);
}

Future<void> main(List<String> args) async {
  final code = await Command(
    'medialoader',
    'Download Instagram, Twitter, and Facebook profiles.',
    commands: [
      Command(
        'download',
        'Download photos, reels, videos, stories, highlights, albums, or profiles.',
        params: [platformFlag, categories, ...compressionParams, all, reset, users],
        handler: run,
      ),
      Command(
        'update',
        'Update every downloaded user with the categories it already has.',
        params: [...compressionParams, all, reset],
        handler: update,
      ),
    ],
  ).run(args);
  exit(code);
}

Future<void> run(Context c) async {
  final userInputs = c(users);
  final defaultPlatform = c(platformFlag);
  final targets = [for (final input in userInputs) platform.parseTarget(input, defaultPlatform)];
  final chosen = c(categories).toSet();
  final (imgQ, vidQ) = compressionSettings(c);

  await dashboard.watch(() async {
    final added = await download.run(
      targets,
      chosen,
      Fs.scriptDir().dir('downloads'),
      all: c(all),
      reset: c(reset),
      imageQuality: imgQ,
      videoQuality: vidQ,
    );
    Console.notify('medialoader: done, $added new files');
  });
}

// Re-downloads every user in downloads/ with the categories it already has
// (see download.discover): a user first downloaded with only some categories
// keeps only those.
Future<void> update(Context c) async {
  final root = Fs.scriptDir().dir('downloads');
  final wants = await download.discover(root);
  if (wants.isEmpty) {
    Console.log('medialoader: nothing downloaded yet, nothing to update.');
    return;
  }
  final (imgQ, vidQ) = compressionSettings(c);
  await dashboard.watch(() async {
    final added = await download.runEach(
      wants,
      root,
      all: c(all),
      reset: c(reset),
      imageQuality: imgQ,
      videoQuality: vidQ,
    );
    Console.notify('medialoader: done, $added new files');
  });
}
