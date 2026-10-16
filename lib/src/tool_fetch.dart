/// The one-time download of a pinned tool, run in its own isolate by
/// `tool.dart` (spawned by URI, so `image`, `video` and `archive` never
/// compile http at startup).
///
/// Arguments: url, sha256, `zip` or `raw`, the target folder. Replies `ok` on
/// success, else the error text. Nothing lands before the hash checks.
library;

import 'dart:io' as io;
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../archive.dart';
import '../hash.dart';
import '../http.dart';
import 'progress.dart' show portProbe;

Future<void> main(List<String> args, SendPort reply) async {
  try {
    await fetch(args[0], args[1], raw: args[2] == 'raw', dir: args[3], name: args[4], progress: portProbe(reply));
    reply.send('ok');
  } catch (e) {
    reply.send('$e');
  }
}

/// Download [url] into [dir]: unpacked, or as the file [name] when [raw].
Future<void> fetch(
  String url,
  String sha256, {
  required bool raw,
  required String dir,
  required String name,
  Probe? progress,
}) async {
  final client = Http.client(retries: 3, check: true);
  try {
    if (raw) {
      final bytes = await (client.get(url) & progress).bytes();
      if (Hash.sha256().addBytes(bytes).hex() != sha256) throw ContentException('$url does not match its sha256');
      await io.File(p.join(dir, name)).writeAsBytes(bytes, flush: true);
    } else {
      // A hash mismatch fails the run before anything is unpacked.
      await (client.get(url) & progress | Hash.sha256(expect: sha256) > Archive.unarchive(dir));
    }
  } finally {
    client.close();
  }
}
