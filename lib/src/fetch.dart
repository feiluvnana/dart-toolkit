/// The one-time download of a pinned tool or of Chrome for Testing, run in
/// its own isolate by `tool.dart` and `chrome_find.dart` (spawned by URI, so
/// `image`, `video`, `archive` and `chrome` never compile http or archive
/// at startup).
///
/// Arguments: url, sha256, the mode (see [fetch]), the target folder, and
/// for `raw` the file name. Replies `ok` on success, else the error text.
/// Nothing lands before the hash checks.
library;

import 'dart:io' as io;
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../archive.dart';
import '../fs.dart';
import '../http.dart';
import 'hash.dart';
import 'progress.dart' show portProbe;

Future<void> main(List<String> args, SendPort reply) async {
  try {
    await fetch(args[0], args[1], args[2], args[3], name: args.elementAtOrNull(4), progress: portProbe(reply));
    reply.send('ok');
  } catch (e) {
    reply.send('$e');
  }
}

/// Download [url], check [sha256], then by [mode]: `raw` writes it as
/// [dir]/[name], `zip` unpacks it into [dir], `app` (Chrome) resumes a
/// `<dir>.zip` across runs and unpacks it into a sibling renamed to [dir],
/// so a reader never sees half of it.
Future<void> fetch(String url, String sha256, String mode, String dir, {String? name, Probe? progress}) async {
  final app = mode == 'app';
  final http = Http.client(
    resume: app,
    timeout: Duration(seconds: app ? 120 : 30),
  );
  try {
    // A hash mismatch fails the run before anything is written or unpacked.
    final body = http.get(url) & progress | HashUtils.sha256(expect: sha256);
    switch (mode) {
      case 'raw':
        await (body > Fs.file(p.join(dir, name!)));
      case 'zip':
        await (body > Archive.unarchive(dir));
      default:
        await _app(body, dir);
    }
  } finally {
    http.close();
  }
}

Future<void> _app(Reader body, String dir) async {
  final zip = '$dir.zip';
  await io.Directory(p.dirname(dir)).create(recursive: true);
  await (body > Fs.file(zip));
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
