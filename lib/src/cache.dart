/// The OS user cache directory for downloaded artifacts (ffmpeg, 7-Zip,
/// Chrome for Testing) and spooled media, and the isolate that downloads
/// them.
///
/// One home for the `~/Library/Caches` / `%LOCALAPPDATA%` /
/// `$XDG_CACHE_HOME` (else `~/.cache`) rules so facades never branch on
/// `Platform`: they call [userCacheDir].
library;

import 'dart:io' as io;
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'download_line.dart';

/// The OS user cache directory. Throws when no home or cache variable names
/// one (cron, systemd, containers): a shared temp folder would let another
/// user plant the binaries this toolkit runs.
String userCacheDir() {
  final env = io.Platform.environment;
  String? dir;
  if (io.Platform.isWindows) {
    dir = env['LOCALAPPDATA'];
  } else {
    final home = env['HOME'];
    final xdg = env['XDG_CACHE_HOME'];
    if (!io.Platform.isMacOS && xdg != null && xdg.isNotEmpty) {
      dir = xdg;
    } else if (home != null && home.isNotEmpty) {
      dir = io.Platform.isMacOS ? p.join(home, 'Library', 'Caches') : p.join(home, '.cache');
    }
  }
  if (dir == null || dir.isEmpty) {
    throw UnsupportedError(
      io.Platform.isWindows
          ? 'no user cache folder: set LOCALAPPDATA'
          : 'no user cache folder: set HOME (or XDG_CACHE_HOME)',
    );
  }
  return dir;
}

/// Run `package:dart_toolkit/src/[library]` in an isolate spawned by URI
/// (a deferred import still compiles its imports at startup, this does
/// not) with [args]; its `main(args, SendPort)` sends `'ok'` or the error
/// text. Returns null on success, else why it failed (an isolate that dies
/// without a reply is a failure). Throws [UnsupportedError] when it cannot
/// spawn: a compiled exe has no package sources.
Future<String?> fetchInIsolate(String library, List<String> args, {required String label}) async {
  final reply = ReceivePort();
  try {
    final entry = await Isolate.resolvePackageUri(Uri.parse('package:dart_toolkit/src/$library'));
    if (entry == null) throw UnsupportedError('no package config');
    await Isolate.spawnUri(
      entry,
      args,
      reply.sendPort,
      onError: reply.sendPort,
      onExit: reply.sendPort,
      automaticPackageResolution: true,
    );
  } catch (e) {
    reply.close();
    throw UnsupportedError('$e');
  }
  // The isolate posts `[done, total]` while it downloads, then its answer.
  final line = DownloadLine(label);
  String? failed;
  try {
    await for (final m in reply) {
      if (m case [final int done, final int? total]) {
        line.update(done, total);
        continue;
      }
      failed = switch (m) {
        'ok' => null,
        [final error, _] => 'the download isolate failed: $error',
        null => 'the download isolate exited without a reply',
        final other => '$other',
      };
      break;
    }
    return failed;
  } finally {
    line.end(ok: failed == null);
    reply.close();
  }
}
