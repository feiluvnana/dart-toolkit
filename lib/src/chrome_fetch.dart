/// The one-time Chrome for Testing download, run in its own isolate by
/// `chrome_find.dart` (spawned by URI, so `chrome` never compiles http or
/// archive at startup).
///
/// Arguments: the pinned zip's URL, its sha256, the target folder. Replies
/// `ok` on success, else the error text. The zip resumes across runs
/// (`<dir>.zip.part`) and must match its hash before anything is unpacked;
/// the folder appears by an atomic rename, so a reader never sees half of
/// it.
library;

import 'dart:io' as io;
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../archive.dart';
import '../fs.dart';
import '../hash.dart';
import '../http.dart';

Future<void> main(List<String> args, SendPort reply) async {
  try {
    await fetch(args[0], args[1], args[2]);
    reply.send('ok');
  } catch (e) {
    reply.send('$e');
  }
}

/// Download [url], check [sha256], unpack it into [dir].
Future<void> fetch(String url, String sha256, String dir) async {
  final http = Http.client(retries: 3, check: true, resume: true, timeout: const Duration(minutes: 2));
  final zip = '$dir.zip';
  await io.Directory(p.dirname(dir)).create(recursive: true);
  await (http.get(url) | Hash.sha256(expect: sha256) > Fs.file(zip));
  final tmp = (await io.Directory(p.dirname(dir)).createTemp('${p.basename(dir)}.tmp-')).path;
  try {
    await (Fs.file(zip) > Archive.unarchive(tmp)); // keeps modes and the app bundle's links
    // Hash-checked above: the quarantine would only stop an unsigned app.
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
