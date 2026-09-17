/// # Downloads
///
/// {@category Files}
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../async/cancellation_token.dart';
import '../fs/path.dart';

/// Progress state for an individual file download.
///
/// {@category Files}
class DownloadProgress {
  /// The source URL being downloaded.
  final Uri url;

  /// The destination path on disk.
  final Path path;

  /// Number of bytes received so far.
  final int received;

  /// Total expected bytes from Content-Length header, or `null` if unknown.
  final int? total;

  /// Whether the download has finished (either saved to disk, skipped, or failed).
  final bool isDone;

  /// Whether the download was skipped because the file already exists and overwrite is false.
  final bool isSkipped;

  /// Whether the download failed (e.g. 404, short read, or connection error).
  final bool isFailed;

  /// Optional error object if the download failed.
  final Object? error;

  const DownloadProgress({
    required this.url,
    required this.path,
    this.received = 0,
    this.total,
    this.isDone = false,
    this.isSkipped = false,
    this.isFailed = false,
    this.error,
  });

  /// Progress ratio from 0.0 to 1.0, or `null` if total content length is unknown.
  double? get ratio => (total != null && total! > 0) ? (received / total!).clamp(0.0, 1.0) : null;

  /// Progress percentage from 0 to 100, or `null` if total content length is unknown.
  int? get percent => ratio != null ? (ratio! * 100).round() : null;

  @override
  String toString() =>
      'DownloadProgress(path: $path, received: $received, total: $total, isDone: $isDone, isSkipped: $isSkipped, isFailed: $isFailed)';
}

/// Aggregated progress state during batch file downloads.
///
/// {@category Files}
class BatchDownloadProgress {
  /// Total number of files completed so far (downloaded + skipped + failed).
  final int completed;

  /// Total count of files in the batch.
  final int total;

  /// Number of files newly downloaded (not skipped).
  final int newDownloads;

  /// The current file's progress update.
  final DownloadProgress current;

  const BatchDownloadProgress({
    required this.completed,
    required this.total,
    required this.newDownloads,
    required this.current,
  });

  /// Overall completion ratio from 0.0 to 1.0.
  double get ratio => total > 0 ? (completed / total).clamp(0.0, 1.0) : 1.0;

  /// Overall completion percentage from 0 to 100.
  int get percent => (ratio * 100).round();

  @override
  String toString() =>
      'BatchDownloadProgress(completed: $completed/$total, newDownloads: $newDownloads, current: $current)';
}

/// Download operations on [Path].
///
/// {@category Files}
extension PathDownloadExtensions on Path {
  /// Downloads content from [url] atomically using a `.part` temporary file and streams [DownloadProgress] updates.
  ///
  /// - Downloads to `<filename>.part` and renames to final destination only upon successful full download.
  /// - Verifies `Content-Length` header; incomplete or short reads are treated as errors.
  /// - Deletes `.part` file on failure to prevent permanent corruption of future runs.
  /// - Supports [cancelToken] for graceful cooperative cancellation.
  Stream<DownloadProgress> download(
    Uri url, {
    http.Client? client,
    bool overwrite = false,
    CancellationToken? cancelToken,
  }) async* {
    if (!overwrite && await exists()) {
      yield DownloadProgress(url: url, path: this, isDone: true, isSkipped: true);
      return;
    }

    if (cancelToken != null && cancelToken.isCancelled) {
      yield DownloadProgress(
        url: url,
        path: this,
        isDone: true,
        isFailed: true,
        error: CancellationException(cancelToken.reason?.toString() ?? 'Download cancelled'),
      );
      return;
    }

    final httpClient = client ?? http.Client();
    final partFile = File('${asFile.path}.part');
    var received = 0;
    int? total;

    try {
      final request = http.Request('GET', url);
      final streamed = await httpClient.send(request);

      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        yield DownloadProgress(
          url: url,
          path: this,
          isDone: true,
          isFailed: true,
          error: HttpException('Download failed with status ${streamed.statusCode}', uri: url),
        );
        return;
      }

      final headerContentLength = streamed.headers['content-length'];
      total = streamed.contentLength ?? (headerContentLength != null ? int.tryParse(headerContentLength) : null);

      await partFile.parent.create(recursive: true);
      final sink = partFile.openWrite();

      try {
        await for (final chunk in streamed.stream) {
          if (cancelToken != null && cancelToken.isCancelled) {
            throw CancellationException(cancelToken.reason?.toString() ?? 'Download cancelled');
          }
          sink.add(chunk);
          received += chunk.length;
          yield DownloadProgress(
            url: url,
            path: this,
            received: received,
            total: total,
            isDone: false,
            isSkipped: false,
          );
        }
      } finally {
        await sink.close();
      }

      if (total != null && received != total) {
        throw HttpException('Download incomplete: expected $total bytes but received $received bytes', uri: url);
      }

      if (await asFile.exists()) {
        await asFile.delete();
      }
      await partFile.rename(asFile.path);

      yield DownloadProgress(
        url: url,
        path: this,
        received: received,
        total: total ?? received,
        isDone: true,
        isSkipped: false,
      );
    } catch (e) {
      if (await partFile.exists()) {
        try {
          await partFile.delete();
        } catch (_) {}
      }
      yield DownloadProgress(
        url: url,
        path: this,
        received: received,
        total: total ?? received,
        isDone: true,
        isFailed: true,
        error: e,
      );
    } finally {
      if (client == null) httpClient.close();
    }
  }
}

Stream<BatchDownloadProgress> _batchDownload(
  Iterable<({Path path, Uri url})> pairs, {
  http.Client? client,
  int concurrency = 4,
  bool overwrite = false,
  CancellationToken? cancelToken,
}) async* {
  final items = pairs.toList();
  final totalFiles = items.length;
  if (totalFiles == 0) return;

  var completedCount = 0;
  var newCount = 0;
  final httpClient = client ?? http.Client();

  final controller = StreamController<BatchDownloadProgress>();
  final limit = concurrency > 0 ? concurrency : 1;
  final queue = Queue<({Path path, Uri url})>.from(items);
  final active = <Future<void>>{};

  void schedule() {
    if (controller.isClosed || (cancelToken != null && cancelToken.isCancelled)) return;

    while (queue.isNotEmpty && active.length < limit) {
      final item = queue.removeFirst();

      late final Future<void> task;
      task = Future<void>(() async {
        try {
          if (cancelToken != null && cancelToken.isCancelled) return;
          await for (final p in item.path.download(
            item.url,
            client: httpClient,
            overwrite: overwrite,
            cancelToken: cancelToken,
          )) {
            if (p.isDone) {
              completedCount++;
              if (!p.isSkipped && !p.isFailed) newCount++;
            }
            if (!controller.isClosed) {
              controller.add(
                BatchDownloadProgress(completed: completedCount, total: totalFiles, newDownloads: newCount, current: p),
              );
            }
          }
        } catch (e) {
          completedCount++;
          if (!controller.isClosed) {
            controller.add(
              BatchDownloadProgress(
                completed: completedCount,
                total: totalFiles,
                newDownloads: newCount,
                current: DownloadProgress(url: item.url, path: item.path, isDone: true, isFailed: true, error: e),
              ),
            );
          }
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

  controller.onListen = () {
    cancelToken?.onCancel(() {
      if (!controller.isClosed) {
        controller.close();
      }
    });
    schedule();
  };
  yield* controller.stream;
}

/// Batch download extensions on a source-to-destination map.
///
/// {@category Files}
extension UriPathMapDownloadExtensions on Map<Uri, Path> {
  /// Downloads all URL-path pairs concurrently and streams [BatchDownloadProgress] updates.
  Stream<BatchDownloadProgress> downloadAll({
    http.Client? client,
    int concurrency = 4,
    bool overwrite = false,
    CancellationToken? cancelToken,
  }) => _batchDownload(
    entries.map((e) => (path: e.value, url: e.key)),
    client: client,
    concurrency: concurrency,
    overwrite: overwrite,
    cancelToken: cancelToken,
  );
}
