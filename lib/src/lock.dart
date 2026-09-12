/// # Inter-process Locking (internal)
///
/// The machinery behind `io.lock`: an exclusively created lock file holding
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
  /// See `io.lock`, which is how a script reaches this.
  static Future<R> hold<R>(
    String path,
    FutureOr<R> Function() action, {
    Duration? wait,
  }) async {
    final file = File(path);
    final deadline = wait == null ? null : DateTime.now().add(wait);

    while (!_take(file)) {
      final holder = _read(file);
      if (holder != null && !_alive(holder.pid)) {
        // The recorded process is gone, so the lock is stale rather than held.
        // A pure age cut-off ('older than an hour is stale') would break the
        // one run that legitimately took ninety minutes.
        _release(file);
        continue;
      }
      if (deadline == null || DateTime.now().isAfter(deadline)) {
        throw LockedError(path, pid: holder?.pid, since: holder?.since);
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
      if (holder != null && !_alive(holder.pid)) {
        _release(file);
        continue;
      }
      throw LockedError(path, pid: holder?.pid, since: holder?.since);
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
    return holder != null && _alive(holder.pid);
  }

  static bool _take(File file) {
    try {
      Fs.mkparentSync(file.path);
      // `exclusive` is the whole mechanism: the create fails rather than
      // truncating a lock somebody else is holding.
      file.createSync(exclusive: true);
      file.writeAsStringSync(
        jsonEncode({
          'pid': pid,
          'since': DateTime.now().toUtc().toIso8601String(),
          'host': _hostname(),
        }),
      );
      // A lock file that survives a Ctrl-C is worse than no lock at all: the
      // next run refuses to start. This is the same registry that removes a
      // half-written `.part` file.
      Sys.track(file);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static void _release(File file) {
    Sys.untrack(file);
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Someone else cleaned it up, which is the outcome either way.
    }
  }

  static ({int pid, DateTime? since})? _read(File file) {
    try {
      if (!file.existsSync()) return null;
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, Object?>) return null;
      final holder = raw['pid'];
      if (holder is! int) return null;
      final since = raw['since'];
      return (
        pid: holder,
        since: since is String ? DateTime.tryParse(since) : null,
      );
    } on Object {
      // An unreadable or half-written lock file names no live process, so the
      // caller should treat it as stale rather than as a hard block.
      return null;
    }
  }

  /// Whether process [holder] is still running.
  static bool _alive(int holder) {
    if (holder == pid) return true;
    try {
      if (Platform.isWindows) {
        final res = Process.runSync('tasklist', [
          '/FI',
          'PID eq $holder',
          '/NH',
        ]);
        return '${res.stdout}'.contains('$holder');
      }
      // Signal 0 asks the kernel whether the process exists without
      // disturbing it. Dart's own killPid has no signal-0 equivalent.
      return Process.runSync('kill', ['-0', '$holder']).exitCode == 0;
    } on Object {
      // No way to ask: assume the holder is alive, because taking a lock that
      // somebody else holds is the worse of the two mistakes.
      return true;
    }
  }

  static String _hostname() {
    try {
      return Platform.localHostname;
    } on Object {
      return '';
    }
  }
}
