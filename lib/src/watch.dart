/// # Filesystem Watching (internal)
///
/// The machinery behind `Path.watch`: one subscription per watched directory,
/// a debounce per path, and the platform asymmetry hidden.
library;

import 'dart:async';
import 'dart:io';

// ============================================================================
// FILESYSTEM WATCHING (internal)
// ============================================================================

/// Watches a path for changes, coalescing the bursts an editor produces.
class Watch {
  Watch._();

  /// Whether `FileSystemEntity.watch` recurses on this platform.
  ///
  /// macOS and Windows do it in the OS; Linux's inotify watches one directory
  /// at a time, so a recursive watch there means walking the tree and adding a
  /// subscription per directory — including for directories created later.
  static bool get nativeRecursion => Platform.isMacOS || Platform.isWindows;

  /// Starts watching [path]; returns the function that stops it.
  static Future<void> Function() start(
    String path,
    void Function(String path) onChange, {
    Pattern? pattern,
    Duration settle = const Duration(milliseconds: 200),
    bool recursive = true,
    void Function(Object error, StackTrace stack)? onError,
  }) {
    final subscriptions = <String, StreamSubscription<FileSystemEvent>>{};
    final pending = <String, Timer>{};
    var stopped = false;

    bool wanted(String candidate) {
      if (pattern == null) return true;
      return pattern.allMatches(candidate).isNotEmpty;
    }

    // A callback that throws does it inside a debounce timer, where there is
    // no caller left to catch it: unreported, it takes down the isolate.
    void deliver(String changed) {
      try {
        onChange(changed);
      } catch (error, stack) {
        onError?.call(error, stack);
      }
    }

    void fire(String changed) {
      if (stopped) return;
      if (settle <= Duration.zero) {
        deliver(changed);
        return;
      }
      // An editor writes a file two or three times per save; without this the
      // naive version fires three builds. The timer restarts on every event
      // for the same path, so a burst collapses into the one call after it.
      pending[changed]?.cancel();
      pending[changed] = Timer(settle, () {
        pending.remove(changed);
        if (!stopped) deliver(changed);
      });
    }

    // Declared ahead of `listen`, which drops directories as their events say
    // they are gone.
    late final void Function(String directory) forget;

    void listen(String directory) {
      if (stopped || subscriptions.containsKey(directory)) return;
      final dir = Directory(directory);
      if (!dir.existsSync()) return;
      final native = recursive && nativeRecursion;
      try {
        subscriptions[directory] = dir
            .watch(recursive: native)
            .listen(
              (event) {
                // A new directory under a hand-rolled recursive watch needs its
                // own subscription, or nothing inside it is ever seen.
                if (recursive && !native && event.isDirectory) {
                  if (event.type == FileSystemEvent.create) {
                    listen(event.path);
                  } else if (event.type == FileSystemEvent.delete ||
                      event.type == FileSystemEvent.move) {
                    // The subscription for a directory that is gone is dead but
                    // still in the map, so a directory recreated under the same
                    // name was never watched again.
                    forget(event.path);
                  }
                }
                if (event.isDirectory) return;
                if (wanted(event.path)) fire(event.path);
              },
              onError: (Object error, StackTrace stack) {
                // An inotify overflow or a permission change ends the subscription.
                // Swallowed, a watcher looked idle forever; reported, the caller can
                // restart it.
                subscriptions.remove(directory);
                onError?.call(error, stack);
              },
              // inotify closes the watch when the directory is removed. Left in
              // the map, that name could never be watched again.
              onDone: () => subscriptions.remove(directory),
            );
      } on FileSystemException {
        // A directory that vanished between the walk and the watch is not an
        // error worth propagating out of a watcher.
        return;
      }
      if (recursive && !native) {
        for (final entity in dir.listSync(followLinks: false)) {
          if (entity is Directory) listen(entity.path);
        }
      }
    }

    forget = (directory) {
      // The subtree goes with it: inotify watches on children of a removed
      // directory are just as dead.
      final gone = subscriptions.keys
          .where(
            (watched) =>
                watched == directory || watched.startsWith('$directory/'),
          )
          .toList();
      for (final watched in gone) {
        subscriptions.remove(watched)?.cancel();
      }
    };

    if (FileSystemEntity.isDirectorySync(path)) {
      listen(path);
    } else {
      // Watching a single file through its directory: the events an editor
      // produces are a create-and-rename in the parent, which a watch on the
      // file itself misses entirely.
      final parent = File(path).parent.path;
      final target = File(path).absolute.path;
      final dir = Directory(parent);
      if (dir.existsSync()) {
        subscriptions[parent] = dir.watch().listen((event) {
          if (File(event.path).absolute.path == target && wanted(event.path)) {
            fire(event.path);
          }
        }, onError: (Object _) {});
      }
    }

    return () async {
      stopped = true;
      for (final timer in pending.values) {
        timer.cancel();
      }
      pending.clear();
      for (final subscription in subscriptions.values) {
        await subscription.cancel();
      }
      subscriptions.clear();
    };
  }
}
