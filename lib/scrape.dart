/// A typed work queue for scrapers and batch jobs: seeds go in, a handler
/// per item queues more items and emits results, duplicates are dropped.
/// Pagination is "queue the next page", fan-out is "queue every link".
///
/// ```dart
/// sealed class Job {}
/// final class Listing extends Job { Listing(this.page); final int page; }
/// final class Detail extends Job { Detail(this.url); final String url; }
///
/// final albums = await Scrape<Job, Album>(limit: 4, retries: 3, onProgress: bar.update).run(
///   [Listing(1)],
///   onItem: (v) async {
///     switch (v.item) {
///       case Listing(:final page):
///         final links = await shop.get('list.php', query: {'page': page}).html().$('a.album').attrs('href');
///         final fresh = [for (final l in links) if (v.add(Detail(l))) l];
///         if (fresh.isNotEmpty) v.add(Listing(page + 1));   // stop at a page with nothing new
///       case Detail(:final url):
///         v.emit(readAlbum(await shop.get(url).html(), url));
///     }
///   },
///   onError: (v, e) => Console.log('✗ ${v.item}: $e'),
/// ).toList();
/// ```
///
/// Public surface is exactly: [Scrape], [Visit].
/// - [Scrape] holds the settings (`limit` `retries` `rate` `key` `onProgress`); `run` takes the
///   seeds and the callbacks and returns the emitted results as a stream.
/// - [Visit] is what each callback gets: `item` `add` `emit`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:collection';

import 'core.dart';
export 'core.dart';

import 'src/rate.dart' as rate;
import 'src/retry.dart' as retry;

/// Settings for a run: how many items at once, how they are paced and
/// retried, and what makes two items the same.
///
/// - [limit] handlers run at once (4 by default).
/// - [retries] re-runs a failing `onItem` with the shared jittered backoff
///   (1 s, 2 s … ±25%) before `onError` hears of it.
/// - [rate] paces item starts (each attempt takes a slot).
/// - [key] is the deduplicator: an item whose key was already queued is
///   dropped, so pagination and link cycles end by themselves. Without it
///   the item itself is the key (its `==`: records and enums work as they are).
/// - [onProgress] hears `(done, total)` after every item; the total grows as
///   items are queued (`onProgress: bar.update`).
final class Scrape<T, R> {
  Scrape({this.limit = 4, this.retries = 0, this.rate, this.key, this.onProgress}) {
    if (limit < 1) throw ArgumentError.value(limit, 'limit', 'must be at least 1');
    if (retries < 0) throw ArgumentError.value(retries, 'retries', 'must not be negative');
  }

  final int limit;
  final int retries;
  final Rate? rate;
  final Object? Function(T item)? key;
  final void Function(int done, int total)? onProgress;

  /// Run from [seeds]: [onItem] handles each item, and may `add` more and
  /// `emit` results, which this stream delivers. The run starts when the
  /// stream is listened to and ends when no item is queued or running.
  ///
  /// After the retries, [onError] gets the same [Visit] and the error, so it
  /// can `add` a replacement item or `emit` a placeholder; the run goes on.
  /// Without [onError], the first failure stops new items and is rethrown
  /// from the stream once the items in flight finish (as is an error thrown
  /// by [onError] itself). Pausing the stream stops new items; cancelling
  /// it ends the run (the items in flight finish, their emits are dropped).
  Stream<R> run(
    Iterable<T> seeds, {
    required FutureOr<void> Function(Visit<T, R> visit) onItem,
    FutureOr<void> Function(Visit<T, R> visit, Object error)? onError,
  }) {
    late final _Run<T, R> state;
    final out = StreamController<R>(
      onListen: () => state.start(),
      onPause: () => state.paused = true,
      onResume: () => state
        ..paused = false
        ..pump(),
      onCancel: () => state.cancel(),
    );
    state = _Run(this, out, seeds, onItem, onError);
    return out.stream;
  }
}

/// What a callback gets: the item, and the way to queue more or emit.
final class Visit<T, R> {
  Visit._(this._run, this.item);

  final _Run<T, R> _run;

  /// The item being handled.
  final T item;

  /// Queue [item]; false when its key was already queued (dropped), so
  /// `[for (final l in links) if (v.add(Detail(l))) l]` is the new ones.
  bool add(T item) => _run.add(item);

  /// Send [value] to the run's stream.
  void emit(R value) => _run.emit(value);
}

final class _Run<T, R> {
  _Run(this.s, this.out, Iterable<T> seeds, this.onItem, this.onError) {
    seeds.forEach(add);
  }

  final Scrape<T, R> s;
  final StreamController<R> out;
  final FutureOr<void> Function(Visit<T, R>) onItem;
  final FutureOr<void> Function(Visit<T, R>, Object)? onError;

  final _queue = Queue<T>();
  final _seen = <Object?>{};
  var _running = 0, _done = 0, _total = 0;
  var paused = false, _started = false, _stopped = false;
  Object? _error;
  StackTrace? _stack;

  /// Ends rate waits and backoffs once the run stops, so a cancelled or
  /// failed run leaves no timer keeping the VM alive.
  final _halt = rate.Halt();

  bool add(T item) {
    if (_stopped) return false;
    final k = s.key;
    if (!_seen.add(k == null ? item : k(item))) return false;
    _queue.add(item);
    _total++;
    if (_started) pump();
    return true;
  }

  void emit(R value) {
    if (!_stopped && !out.isClosed) out.add(value);
  }

  void start() {
    _started = true;
    pump();
  }

  void cancel() {
    _stopped = true;
    _queue.clear();
    _halt.fire();
  }

  void pump() {
    while (!paused && !_stopped && _running < s.limit && _queue.isNotEmpty) {
      _running++;
      unawaited(_handle(_queue.removeFirst()));
    }
    if (_running == 0 && (_queue.isEmpty || _stopped) && !out.isClosed) {
      final e = _error;
      if (e != null) out.addError(e, _stack);
      out.close();
    }
  }

  Future<void> _handle(T item) async {
    final visit = Visit<T, R>._(this, item);
    try {
      for (var attempt = 0; ; attempt++) {
        final pace = s.rate;
        if (pace != null) await rate.take(pace, _halt);
        if (_stopped) return;
        try {
          await onItem(visit);
          break;
        } catch (e, st) {
          if (_stopped) return;
          if (attempt < s.retries) {
            await rate.sleep(retry.backoff(attempt, null), _halt);
            if (_stopped) return;
            continue;
          }
          final handler = onError;
          if (handler == null) {
            _fail(e, st);
            return;
          }
          try {
            await handler(visit, e);
          } catch (e2, st2) {
            _fail(e2, st2);
          }
          break;
        }
      }
    } finally {
      _running--;
      _done++;
      s.onProgress?.call(_done, _total);
      pump();
    }
  }

  void _fail(Object e, StackTrace st) {
    if (_error != null) return;
    _error = e;
    _stack = st;
    _queue.clear();
    _stopped = true;
    _halt.fire();
  }
}
