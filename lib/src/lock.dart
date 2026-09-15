/// # Inter-process Locking (internal)
///
/// The machinery behind [withLock]: an exclusively created lock file holding
/// the pid that took it, a liveness check so a stale lock is diagnosable
/// rather than permanent, and release on normal return, on throw, and on
/// Ctrl-C.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'fs.dart';
import 'proc.dart';

// ============================================================================
// INTER-PROCESS LOCKING (internal)
// ============================================================================

/// Raised when a lock is held by another live process.
///
/// Carries the path and, when the lock file said so, the pid holding it — so
/// the message names the process to look at rather than only the file.
class LockedError implements Exception {
  /// The lock file that is held.
  final String path;

  /// The process holding it, or `null` when the file did not say.
  final int? pid;

  /// When the holder took it, or `null` when the file did not say.
  final DateTime? since;

  /// Creates the error.
  const LockedError(this.path, {this.pid, this.since});

  @override
  String toString() {
    final holder = pid == null ? 'another process' : 'pid $pid';
    final when = since == null ? '' : ' since ${since!.toIso8601String()}';
    return 'LockedError: $path is held by $holder$when';
  }
}

/// Exclusive locking through a lock file.
class Lock {
  Lock._();

  /// How long to wait between attempts while [hold] is waiting for a lock.
  static const Duration retryEvery = Duration(milliseconds: 100);

  /// Runs [action] holding the lock at [path].
  ///
  /// See [withLock], which is how a script reaches this.
  static Future<R> hold<R>(
    String path,
    FutureOr<R> Function() action, {
    Duration? wait,
  }) async {
    final file = File(path);
    final deadline = wait == null ? null : DateTime.now().add(wait);
    ({int pid, DateTime? since, String host})? unreadable;
    var sawUnreadable = false;

    while (!_take(file)) {
      final holder = _read(file);
      if (holder == null) {
        // No pid to ask about: either nobody is there, or a holder is between
        // its exclusive create and its write. Those look identical for an
        // instant, so the second look is what tells them apart.
        if (!file.existsSync()) continue;
        if (sawUnreadable) {
          if (_steal(file)) continue;
          sawUnreadable = false;
        } else {
          sawUnreadable = true;
        }
        if (deadline != null && DateTime.now().isAfter(deadline)) {
          throw LockedError(path);
        }
        await Future<void>.delayed(retryEvery);
        continue;
      }
      sawUnreadable = false;
      if (!_alive(holder)) {
        // The recorded process is gone, so the lock is stale rather than held.
        // Confirming the same pid twice keeps a reclaim from racing a holder
        // that took the lock in between.
        if (unreadable != null &&
            unreadable.pid == holder.pid &&
            unreadable.since == holder.since) {
          if (_steal(file)) continue;
        }
        unreadable = holder;
        await Future<void>.delayed(retryEvery);
        continue;
      }
      unreadable = null;
      if (deadline == null || DateTime.now().isAfter(deadline)) {
        throw LockedError(path, pid: holder.pid, since: holder.since);
      }
      await Future<void>.delayed(retryEvery);
    }

    try {
      return await action();
    } finally {
      _release(file);
    }
  }

  /// Runs [action] synchronously holding the lock at [path].
  static R holdSync<R>(String path, R Function() action) {
    final file = File(path);
    while (!_take(file)) {
      final holder = _read(file);
      if (holder == null && !file.existsSync()) continue;
      if (holder == null || !_alive(holder)) {
        // One confirming look, for the reason [hold] gives: a holder that has
        // created the file but not written it yet is not a stale lock.
        sleep(retryEvery);
        final again = _read(file);
        final settled =
            (again == null && file.existsSync()) ||
            (again != null &&
                again.pid == holder?.pid &&
                again.since == holder?.since &&
                !_alive(again));
        if (settled && _steal(file)) continue;
        throw LockedError(path, pid: holder?.pid, since: holder?.since);
      }
      throw LockedError(path, pid: holder.pid, since: holder.since);
    }
    try {
      return action();
    } finally {
      _release(file);
    }
  }

  /// Whether the lock at [path] is currently held by a live process.
  static bool held(String path) {
    final holder = _read(File(path));
    return holder != null && _alive(holder);
  }

  static bool _take(File file) {
    try {
      Fs.mkparentSync(file.path);
      // `exclusive` is the whole mechanism: the create fails rather than
      // truncating a lock somebody else is holding.
      file.createSync(exclusive: true);
      // Tracked before the write, so a Ctrl-C in the microsecond between the
      // two does not leave a lock nobody can account for.
      Sys.track(file);
      // Flush so another process never observes the exclusive empty file as a
      // permanent unreadable lock.
      file.writeAsStringSync(
        jsonEncode({
          'pid': pid,
          'since': DateTime.now().toUtc().toIso8601String(),
          'host': _hostname(),
        }),
        flush: true,
      );
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Claims a stale lock by renaming it aside, so only one waiter clears it.
  ///
  /// Unlinking directly let two waiters both delete and both create — and let
  /// the loser's delete take the winner's fresh lock with it. A rename fails
  /// for everyone but the first, which is the claim.
  static bool _steal(File file) {
    final aside = File(
      '${file.path}.stale.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      file.renameSync(aside.path);
    } on FileSystemException {
      return false;
    }
    try {
      if (aside.existsSync()) aside.deleteSync();
    } on FileSystemException {
      // The claim is what mattered; a leftover here is not worth failing over.
    }
    return true;
  }

  static void _release(File file) {
    Sys.untrack(file);
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Someone else cleaned it up, which is the outcome either way.
    }
  }

  static ({int pid, DateTime? since, String host})? _read(File file) {
    try {
      if (!file.existsSync()) return null;
      final text = file.readAsStringSync();
      if (text.trim().isEmpty) return null;
      final raw = jsonDecode(text);
      if (raw is! Map) return null;
      final holder = raw['pid'];
      if (holder is! int) return null;
      final since = raw['since'];
      final host = raw['host'];
      return (
        pid: holder,
        since: since is String ? DateTime.tryParse(since) : null,
        host: host is String ? host : '',
      );
    } on Object {
      // An unreadable or half-written lock file names no live process, so the
      // caller should treat it as stale rather than as a hard block.
      return null;
    }
  }

  static final Map<int, (bool alive, int atMs)> _liveness = {};

  /// Whether process [holder] is still running.
  ///
  /// A lock recorded on another host is treated as live: a local PID check
  /// would confuse an unrelated process that reused the same pid number.
  static bool _alive(({int pid, DateTime? since, String host}) holder) {
    if (holder.host.isNotEmpty && holder.host != _hostname()) return true;
    final id = holder.pid;
    if (id == pid) return true;
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _liveness[id];
    if (cached != null && now - cached.$2 < 1000) return cached.$1;
    var alive = true;
    try {
      if (Platform.isWindows) {
        final res = Process.runSync('tasklist', ['/FI', 'PID eq $id', '/NH']);
        alive = '${res.stdout}'.contains('$id');
      } else {
        // Signal 0 asks the kernel whether the process exists without
        // disturbing it. Dart's own killPid has no signal-0 equivalent.
        alive = Process.runSync('kill', ['-0', '$id']).exitCode == 0;
      }
    } on Object {
      // No way to ask: assume the holder is alive, because taking a lock that
      // somebody else holds is the worse of the two mistakes.
      alive = true;
    }
    _liveness[id] = (alive, now);
    return alive;
  }

  static String _hostname() {
    try {
      return Platform.localHostname;
    } on Object {
      return '';
    }
  }
}
