// # Downloads
//
// {@category Networking}

part of '../../http.dart';

/// The state of one file download: [Downloading], [Downloaded], [DownloadSkipped]
/// or [DownloadFailed].
///
/// {@category Networking}
sealed class DownloadProgress implements TaskProgress {
  /// The source URL.
  final Uri url;

  /// The destination on disk.
  final Path path;

  const DownloadProgress(this.url, this.path);

  @override
  String get taskId => path;

  @override
  String get label => path.name;

  @override
  bool get isDone => this is! Downloading;

  @override
  int? get received => switch (this) {
    Downloading(:final received) => received,
    Downloaded(:final bytes) => bytes,
    _ => null,
  };

  @override
  int? get total => switch (this) {
    Downloading(:final total) => total,
    Downloaded(:final bytes) => bytes,
    _ => null,
  };

  @override
  double? get ratio => switch (this) {
    Downloading(:final received, :final total) when total != null && total > 0 => (received / total).clamp(0.0, 1.0),
    Downloaded() => 1.0,
    _ => null,
  };

  @override
  String? get status => switch (this) {
    Downloading() => null,
    Downloaded() => 'done',
    DownloadSkipped() => 'skipped',
    DownloadFailed() => 'failed',
  };

  @override
  String toString() => '$runtimeType($path)';
}

/// Bytes are arriving.
///
/// {@category Networking}
final class Downloading extends DownloadProgress {
  @override
  final int received;

  /// Expected bytes from `Content-Length`, or `null` when the server did not say.
  @override
  final int? total;

  const Downloading(super.url, super.path, {required this.received, this.total});
}

/// The file was written and renamed into place.
///
/// {@category Networking}
final class Downloaded extends DownloadProgress {
  /// Bytes written.
  final int bytes;

  const Downloaded(super.url, super.path, this.bytes);
}

/// The destination already existed and `overwrite` was false.
///
/// {@category Networking}
final class DownloadSkipped extends DownloadProgress {
  const DownloadSkipped(super.url, super.path);
}

/// The transfer failed; its `.part` file stays for a resume.
///
/// {@category Networking}
final class DownloadFailed extends DownloadProgress {
  /// What went wrong.
  final Object error;

  const DownloadFailed(super.url, super.path, this.error);
}

/// Aggregated progress for a batch of downloads.
///
/// {@category Networking}
class BatchDownloadProgress implements BatchProgress {
  /// Files finished so far — downloaded, skipped or failed.
  @override
  final int completed;

  /// Files in the batch, or `null` while a stream source is still producing them.
  @override
  final int? total;

  /// Files newly written, excluding skips and failures.
  final int written;

  /// The update that triggered this event.
  @override
  final DownloadProgress current;

  const BatchDownloadProgress({
    required this.completed,
    required this.total,
    required this.written,
    required this.current,
  });

  /// Overall completion from 0.0 to 1.0, or `null` while [total] is unknown.
  double? get ratio => total == null ? null : (total! > 0 ? (completed / total!).clamp(0.0, 1.0) : 1.0);

  @override
  String toString() => 'BatchDownloadProgress($completed/${total ?? '?'}, new: $written, $current)';
}

/// Bytes buffered before the writer waits for the disk. Bounds the memory a download
/// can hold when the source is faster than the destination.
const _flushEvery = 4 * 1024 * 1024;

/// Download operations on [Path].
///
/// {@category Networking}
extension PathDownloadExtensions on Path {
  /// Downloads [url] to this path atomically, streaming [DownloadProgress] updates.
  ///
  /// Writes `<name>.part` and renames on success, verifies `Content-Length`, and honours
  /// [cancelToken] cooperatively. A failed or cancelled transfer keeps its `.part`; the next
  /// download of the same path resumes it with a `Range` request when [resume] is set, and
  /// starts over when the server does not honour the range.
  Stream<DownloadProgress> download(
    Uri url, {
    Client? client,
    Map<String, String>? headers,
    bool overwrite = false,
    bool resume = true,
    CancelToken? cancelToken,
  }) async* {
    if (!overwrite && await exists()) {
      yield DownloadSkipped(url, this);
      return;
    }

    if (cancelToken != null && cancelToken.isCancelled) {
      yield DownloadFailed(url, this, CancelledException(cancelToken.reason?.toString() ?? 'Download cancelled'));
      return;
    }

    final lease = _clientFor(client);
    final partFile = File('${asFile.path}.part');
    var received = 0;

    try {
      var offset = resume && await partFile.exists() ? await partFile.length() : 0;
      final request = Request('GET', url, headers: headers);
      if (offset > 0) request.headers['range'] = 'bytes=$offset-';
      var streamed = await lease.client.send(request);

      if (streamed.statusCode == 416 && offset > 0) {
        // The part is not a prefix of what the server has now; start over.
        unawaited(streamed.stream.listen(null, cancelOnError: true).cancel().catchError((_) {}));
        offset = 0;
        streamed = await lease.client.send(Request('GET', url, headers: headers));
      }
      if (!streamed.isOk && streamed.statusCode != 206) {
        // Close the body instead of holding the connection until GC.
        unawaited(streamed.stream.listen(null, cancelOnError: true).cancel().catchError((_) {}));
        yield DownloadFailed(url, this, HttpException('Download failed with status ${streamed.statusCode}', uri: url));
        return;
      }
      final resumed = streamed.statusCode == 206 && offset > 0;
      if (!resumed) offset = 0;
      final total = switch (streamed.headers['content-range']) {
        final range? when resumed => int.tryParse(range.split('/').last),
        _ => streamed.contentLength == null ? null : offset + streamed.contentLength!,
      };

      await partFile.parent.create(recursive: true);
      final sink = partFile.openWrite(mode: resumed ? FileMode.append : FileMode.write);
      received = offset;
      var unflushed = 0;

      try {
        await for (final chunk in streamed.stream) {
          cancelToken?.throwIfCancelled();
          sink.add(chunk);
          received += chunk.length;
          unflushed += chunk.length;
          // `add` only queues, so without this the socket is throttled by the
          // consumer and never by the disk, and a slow destination buffers the
          // difference in memory.
          if (unflushed >= _flushEvery) {
            unflushed = 0;
            await sink.flush();
          }
          yield Downloading(url, this, received: received, total: total);
        }
      } finally {
        await sink.close();
      }

      if (total != null && received != total) {
        if (received > total) await _discard(partFile); // not a prefix of anything; useless
        throw HttpException('Download incomplete: expected $total bytes but received $received bytes', uri: url);
      }

      await partFile.rename(asFile.path);
      yield Downloaded(url, this, received);
    } catch (e) {
      yield DownloadFailed(url, this, e);
    } finally {
      lease.close();
    }
  }
}

Future<void> _discard(File part) async {
  try {
    if (await part.exists()) await part.delete();
  } catch (_) {}
}

Stream<BatchDownloadProgress> _batchDownload(
  Stream<({Uri url, Path path})> source, {
  int? knownTotal,
  Client? client,
  Map<String, String>? headers,
  int concurrency = 4,
  bool overwrite = false,
  bool resume = true,
  CancelToken? cancelToken,
}) {
  final controller = StreamController<BatchDownloadProgress>();
  final limit = concurrency > 0 ? concurrency : 1;
  final queue = Queue<({Uri url, Path path})>();
  final active = <Future<void>>{};
  final lease = _clientFor(client);

  var discovered = 0;
  var completed = 0;
  var written = 0;
  var sourceDone = false;
  var stopped = false;
  StreamSubscription<({Uri url, Path path})>? subscription;
  void Function()? unregister;

  bool cancelled() => stopped || (cancelToken != null && cancelToken.isCancelled);

  void finish() {
    stopped = true;
    unregister?.call();
    subscription?.cancel();
    lease.close();
    if (!controller.isClosed) controller.close();
  }

  void emit(DownloadProgress progress) {
    if (controller.isClosed) return;
    controller.add(
      BatchDownloadProgress(
        completed: completed,
        total: knownTotal ?? (sourceDone ? discovered : null),
        written: written,
        current: progress,
      ),
    );
  }

  // Reading ahead is bounded: a discovery stream that outruns the transfers would
  // otherwise queue the whole crawl before the first file is written.
  final highWater = limit * 4;

  void applyBackpressure() {
    final sub = subscription;
    if (sub == null || sourceDone) return;
    if (queue.length >= highWater) {
      if (!sub.isPaused) sub.pause();
    } else if (sub.isPaused) {
      sub.resume();
    }
  }

  void schedule() {
    if (cancelled() || controller.isClosed) return;
    applyBackpressure();

    while (queue.isNotEmpty && active.length < limit) {
      final item = queue.removeFirst();

      late final Future<void> task;
      task = Future<void>(() async {
        try {
          if (cancelled()) return;
          await for (final p in item.path.download(
            item.url,
            client: lease.client,
            headers: headers,
            overwrite: overwrite,
            resume: resume,
            cancelToken: cancelToken,
          )) {
            if (cancelled()) break;
            if (p.isDone) {
              completed++;
              if (p is Downloaded) written++;
            }
            emit(p);
          }
        } catch (e) {
          completed++;
          emit(DownloadFailed(item.url, item.path, e));
        } finally {
          active.remove(task);
          if (queue.isEmpty && active.isEmpty && sourceDone) {
            finish();
          } else {
            schedule();
          }
        }
      });
      active.add(task);
    }

    if (queue.isEmpty && active.isEmpty && sourceDone) finish();
  }

  controller
    ..onListen = () {
      unregister = cancelToken?.onCancel(finish);
      subscription = source.listen(
        (item) {
          discovered++;
          queue.add(item);
          schedule();
        },
        onError: controller.addError,
        onDone: () {
          sourceDone = true;
          schedule();
        },
      );
    }
    // A consumer that stops listening stops the transfers, not just the reports.
    ..onCancel = finish;

  return controller.stream;
}

/// Batch downloads over a fixed set of pairs.
///
/// {@category Networking}
extension IterableDownloadExtensions on Iterable<({Uri url, Path path})> {
  /// Downloads every pair, at most [concurrency] at a time.
  Stream<BatchDownloadProgress> downloadAll({
    Client? client,
    Map<String, String>? headers,
    int concurrency = 4,
    bool overwrite = false,
    bool resume = true,
    CancelToken? cancelToken,
  }) {
    final items = toList();
    return _batchDownload(
      Stream.fromIterable(items),
      knownTotal: items.length,
      client: client,
      headers: headers,
      concurrency: concurrency,
      overwrite: overwrite,
      resume: resume,
      cancelToken: cancelToken,
    );
  }
}

/// Batch downloads over pairs that are still being discovered.
///
/// {@category Networking}
extension StreamDownloadExtensions on Stream<({Uri url, Path path})> {
  /// Downloads pairs as they arrive, so discovery and transfer overlap.
  ///
  /// [BatchDownloadProgress.total] is `null` until this stream closes.
  Stream<BatchDownloadProgress> downloadAll({
    Client? client,
    Map<String, String>? headers,
    int concurrency = 4,
    bool overwrite = false,
    bool resume = true,
    CancelToken? cancelToken,
  }) => _batchDownload(
    this,
    client: client,
    headers: headers,
    concurrency: concurrency,
    overwrite: overwrite,
    resume: resume,
    cancelToken: cancelToken,
  );
}

/// Batch downloads over a source-to-destination map.
///
/// {@category Networking}
extension MapDownloadExtensions on Map<Uri, Path> {
  /// These entries as download pairs, for composing with the iterable and stream forms.
  Iterable<({Uri url, Path path})> get pairs => entries.map((e) => (url: e.key, path: e.value));

  /// Downloads every entry, at most [concurrency] at a time.
  ///
  /// A `Map` holds one destination per URL. To send one URL to two places, use the
  /// [IterableDownloadExtensions] form over records.
  Stream<BatchDownloadProgress> downloadAll({
    Client? client,
    Map<String, String>? headers,
    int concurrency = 4,
    bool overwrite = false,
    bool resume = true,
    CancelToken? cancelToken,
  }) => pairs.downloadAll(
    client: client,
    headers: headers,
    concurrency: concurrency,
    overwrite: overwrite,
    resume: resume,
    cancelToken: cancelToken,
  );
}
