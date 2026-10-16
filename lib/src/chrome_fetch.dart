/// The one-time Chrome for Testing download, run in its own isolate by
/// `chrome_find.dart` (spawned by URI, so `chrome` never compiles http or
/// archive at startup).
///
/// Arguments: kind (`chrome` or `chrome-headless-shell`), platform
/// (`mac-arm64`…), the target folder. Replies `null` on success, else the
/// error text. The zip resumes across runs (`<dir>.zip.part`); the folder
/// appears by an atomic rename, so a reader never sees half of it.
library;

import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../archive.dart';
import '../fs.dart';
import '../http.dart';

const _index = 'https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json';

Future<void> main(List<String> args, SendPort reply) async {
  try {
    await fetch(args[0], args[1], args[2]);
    reply.send(null);
  } catch (e) {
    reply.send('$e');
  }
}

/// Download and unpack [kind] for [platform] into [dir].
Future<void> fetch(String kind, String platform, String dir) async {
  final http = Http.client(retries: 3, check: true, resume: true, timeout: const Duration(minutes: 2));
  final index = jsonDecode(await http.get(_index).text()) as Map<String, Object?>;
  final stable = (index['channels']! as Map)['Stable']! as Map;
  final url = [
    for (final d in ((stable['downloads']! as Map)[kind]! as List).cast<Map<String, Object?>>())
      if (d['platform'] == platform) d['url'] as String,
  ].firstOrNull;
  if (url == null) throw StateError('no $kind build for $platform');
  final zip = '$dir.zip';
  await io.Directory(p.dirname(dir)).create(recursive: true);
  await (http.get(url) > Fs.file(zip));
  final tmp = '$dir.${io.pid}.tmp';
  try {
    await (Fs.file(zip) > Archive.unarchive(tmp)); // keeps modes and the app bundle's links
    if (io.Platform.isMacOS) await io.Process.run('xattr', ['-dr', 'com.apple.quarantine', tmp]);
    try {
      await io.Directory(tmp).rename(dir);
    } on io.FileSystemException {
      if (!io.Directory(dir).existsSync()) rethrow; // another run won the race
    }
  } finally {
    if (io.Directory(tmp).existsSync()) await io.Directory(tmp).delete(recursive: true);
  }
  await io.File(zip).delete();
}
