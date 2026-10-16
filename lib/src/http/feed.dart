// Feed: a newest-first listing (a timeline, a search, an API's pages)
// walked one page at a time, with a cursor that survives an interrupted run.
part of '../../http.dart';

/// A newest-first listing, walked one page at a time by [run]: from the top
/// until a page says the rest is known, or to the end.
///
/// ```dart
/// final posts = Feed((cursor) => api.get('posts', query: {'after': cursor}).json().then(
///       (j) => (items: j.$('data').toList(), next: j.$('next').text())), cursor: '.posts-cursor');
/// await posts.run((page) => page.items().every(seen) ? page.stop() : page.add(save(page.items())));
/// ```
///
/// [page] fetches the page at a cursor (null: the newest) and names the
/// next one (null: the end). With [cursor], a path, the walk remembers
/// where it got to: the next page's cursor is written there once a page's
/// work has succeeded, and removed when the walk ends. A run that finds one
/// first lists the top up to what is known (what is new since), then
/// continues from it.
final class Feed<T> {
  /// A feed of [page]s; [cursor] is the file that remembers the walk.
  Feed(this._page, {this._cursor});

  final Future<({List<T> items, String? next})> Function(String? cursor) _page;
  final String? _cursor;

  /// Walk the pages; true when the end was reached.
  ///
  /// [onPage] gets each non-empty page as a [FeedPage]: its `items()`,
  /// `add(work)` for what the page starts (a download, a save; `true` when
  /// it succeeded), and `stop()` to end the walk there (the rest is known,
  /// or older than wanted). [run] waits for [onPage], not for the work: the
  /// next page is fetched while it runs. The cursor moves past a page only
  /// once its work and every earlier page's succeeded. With [all], the walk
  /// starts from the top whatever cursor is saved (a full re-list). A
  /// failing [page] fails the run; the cursor stays at the last page whose
  /// work was done. [run] completes after every page's work.
  Future<bool> run(FutureOr<void> Function(FeedPage<T> page) onPage, {bool all = false}) async {
    final file = _cursor == null ? null : File(_cursor);
    final saved = all || file == null || !await file.exists() ? '' : (await file.readAsString()).trim();
    var chain = Future<void>.value();
    var ok = true;

    // Remember [next] (null: done, nothing to continue) once [page]'s work
    // is; the catch-up from the top only waits for its work.
    void track(FeedPage<T>? page, String? next, {required bool tracked}) {
      final done = page == null ? Future.value(true) : page._done();
      chain = chain.then((_) async {
        final succeeded = await done;
        if (!tracked) return;
        ok = ok && succeeded;
        if (!ok || file == null) return;
        if (next == null) {
          if (await file.exists()) await file.delete();
        } else {
          await file.parent.create(recursive: true);
          await file.writeAsString(next);
        }
      });
    }

    // From [cursor]; true when the end was reached.
    Future<bool> walk(String? cursor, {required bool tracked}) async {
      for (;;) {
        final p = await _page(cursor);
        final end = p.items.isEmpty || p.next == null || p.next == cursor;
        final page = p.items.isEmpty ? null : FeedPage<T>._(p.items);
        if (page != null) await onPage(page);
        if (page != null && page._stopped) {
          track(page, null, tracked: tracked);
          return false;
        }
        track(page, end ? null : p.next, tracked: tracked);
        if (end) return true;
        cursor = p.next;
      }
    }

    try {
      if (saved.isEmpty) return await walk(null, tracked: true);
      await walk(null, tracked: false);
      return await walk(saved, tracked: true);
    } finally {
      await chain;
    }
  }
}

/// One page of a [Feed] walk: its items, the work it starts, and whether
/// the walk ends here.
final class FeedPage<T> {
  FeedPage._(this._items);

  final List<T> _items;
  final _work = <Future<bool>>[];
  var _stopped = false;

  /// This page's items, newest first.
  List<T> items() => _items;

  /// [work] this page started; the cursor moves past the page once all of
  /// it is `true`. Returns this page.
  FeedPage<T> add(Future<bool> work) {
    // Heard at once: a failure is this page's, never an unhandled error.
    _work.add(work.catchError((Object _) => false));
    return this;
  }

  /// End the walk at this page (its work still counts).
  void stop() => _stopped = true;

  Future<bool> _done() async => (await Future.wait(_work)).every((ok) => ok);
}
