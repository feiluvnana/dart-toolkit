/// The OS user cache directory for downloaded artifacts (Chromium).
///
/// One home for the `~/Library/Caches` / `%LOCALAPPDATA%` /
/// `$XDG_CACHE_HOME` (else `~/.cache`) rules so facades never branch on
/// `Platform`: they call [userCacheDir]. Used by `chrome` for the
/// machine-wide Chromium download (one per machine, not per project).
library;

import 'dart:io' as io;

import 'package:path/path.dart' as p;

/// The OS user cache directory, falling back to the system temp dir when no
/// home/cache env var names one.
String userCacheDir() {
  final env = io.Platform.environment;
  if (io.Platform.isMacOS) {
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      return p.join(home, 'Library', 'Caches');
    }
  } else if (io.Platform.isWindows) {
    final local = env['LOCALAPPDATA'];
    if (local != null && local.isNotEmpty) return local;
  } else {
    final xdg = env['XDG_CACHE_HOME'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      return p.join(home, '.cache');
    }
  }
  return io.Directory.systemTemp.path;
}
