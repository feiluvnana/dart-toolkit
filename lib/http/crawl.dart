import 'dart:async';

import 'package:http/http.dart' as http;

/// Action returned by a crawler fetch handler, carrying optional data and URLs to follow.
class CrawlAction<T> {
  /// The data items produced from processing the response.
  final List<T> data;

  /// Child URLs to follow.
  final List<Uri> follow;

  const CrawlAction({this.data = const [], this.follow = const []});

  /// Action with a single data item.
  factory CrawlAction.data(T item, {Iterable<Uri> follow = const []}) =>
      CrawlAction(data: [item], follow: follow.toList());

  /// Action that only follows URLs without emitting data.
  factory CrawlAction.follow(Iterable<Uri> urls) => CrawlAction(follow: urls.toList());

  /// Empty action.
  const CrawlAction.none() : data = const [], follow = const [];
}

/// Minimalist streaming web crawler.
///
/// Crawls [seeds] concurrently with up to [concurrency] workers, passes each
/// HTTP response to [onFetch], yields emitted data items, and feeds returned
/// [CrawlAction.follow] URLs back into the queue.
Stream<T> crawl<T>(
  Iterable<Uri> seeds, {
  required FutureOr<CrawlAction<T>> Function(http.Response res) onFetch,
  int concurrency = 4,
  Duration? delay,
  http.Client? client,
}) {
  late final StreamController<T> controller;
  final httpClient = client ?? http.Client();
  final visited = <Uri>{};
  final queue = <Uri>[...seeds];
  final active = <Future<void>>{};
  final limit = concurrency > 0 ? concurrency : 1;
  var isStopped = false;

  void schedule() {
    if (isStopped || controller.isClosed) return;

    while (queue.isNotEmpty && active.length < limit) {
      final uri = queue.removeAt(0);
      if (!visited.add(uri)) continue;

      late final Future<void> task;
      task = Future<void>(() async {
        try {
          if (delay != null && delay > Duration.zero) {
            await Future<void>.delayed(delay);
          }
          if (isStopped) return;
          final res = await httpClient.get(uri);
          if (isStopped) return;
          final action = await onFetch(res);
          for (final item in action.data) {
            if (!controller.isClosed) controller.add(item);
          }
          for (final nextUri in action.follow) {
            if (!visited.contains(nextUri)) {
              queue.add(nextUri);
            }
          }
        } catch (e, st) {
          if (!controller.isClosed) controller.addError(e, st);
        } finally {
          active.remove(task);
          if (queue.isEmpty && active.isEmpty && !controller.isClosed) {
            if (client == null) httpClient.close();
            controller.close();
          } else {
            schedule();
          }
        }
      });
      active.add(task);
    }

    if (queue.isEmpty && active.isEmpty && !controller.isClosed) {
      if (client == null) httpClient.close();
      controller.close();
    }
  }

  controller = StreamController<T>(
    onListen: () {
      schedule();
    },
    onCancel: () {
      isStopped = true;
      if (client == null) httpClient.close();
    },
  );

  return controller.stream;
}
