/// The OS user cache directory for downloaded artifacts (ffmpeg, 7-Zip,
/// Chrome for Testing) and spooled media, and the isolate that downloads
/// them.
///
/// One home for the `~/Library/Caches` / `%LOCALAPPDATA%` /
/// `$XDG_CACHE_HOME` (else `~/.cache`) rules so facades never branch on
/// `Platform`: they call [userCacheDir].
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../core.dart' show SetupException;
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
    throw SetupException(
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
/// without a reply is a failure). Throws [SetupException] when it cannot
/// spawn: "a compiled exe" only when it is one (AOT, or no package sources).
Future<String?> fetchInIsolate(String library, List<String> args, {required String label}) async {
  Uri? entry;
  try {
    entry = await Isolate.resolvePackageUri(Uri.parse('package:dart_toolkit/src/$library'));
  } catch (_) {}
  if (entry == null || const bool.fromEnvironment('dart.vm.product')) {
    throw SetupException('a compiled exe cannot download $label (it has no package sources)');
  }
  final reply = ReceivePort();
  try {
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
    throw SetupException('could not start the download of $label: $e', cause: e);
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

/// Runs [body] holding the download lock at [path]: one downloader per
/// machine, the rest wait. The OS lock (fcntl) excludes other processes
/// but not other isolates of this one (`Pool(isolates: true)` on a fresh
/// machine), so a `<path>.<pid>` sentinel, created exclusively and touched
/// while held, goes first; one untouched for a minute is a crashed run's.
Future<T> downloadLock<T>(String path, Future<T> Function() body) async {
  final sentinel = io.File('$path.${io.pid}');
  while (true) {
    try {
      await sentinel.create(exclusive: true);
      break;
    } on io.FileSystemException {
      try {
        if (DateTime.now().difference(await sentinel.lastModified()) > const Duration(minutes: 1)) {
          await sentinel.delete();
        }
      } on io.FileSystemException {
        // released meanwhile
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  final beat = Timer.periodic(const Duration(seconds: 10), (_) => sentinel.setLastModified(DateTime.now()).ignore());
  try {
    final lock = await io.File(path).open(mode: io.FileMode.append);
    try {
      await lock.lock(io.FileLock.blockingExclusive);
      return await body();
    } finally {
      await lock.close(); // closing releases the lock
    }
  } finally {
    beat.cancel();
    await sentinel.delete().catchError((_) => sentinel);
  }
}

/// Prune older versions/builds in [parentDir], preserving [keepName] and any active lock files.
Future<void> pruneOld(String parentDir, String keepName) async {
  try {
    final parent = io.Directory(parentDir);
    if (!await parent.exists()) return;
    await for (final entity in parent.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name == keepName || name.endsWith('.lock') || name.contains('.lock.')) continue;
      try {
        await entity.delete(recursive: true);
      } catch (_) {}
    }
  } catch (_) {}
}
