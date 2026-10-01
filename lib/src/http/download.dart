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
  Object? get error => switch (this) {
    DownloadFailed(:final error) => error,
    _ => null,
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
  @override
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

  /// Files that failed to download.
  @override
  final int failed;

  /// The update that triggered this event.
  @override
  final DownloadProgress current;

  const BatchDownloadProgress({
    required this.completed,
    required this.total,
    required this.written,
    this.failed = 0,
    required this.current,
  });

  /// Overall completion from 0.0 to 1.0, or `null` while [total] is unknown.
  double? get ratio => total == null ? null : (total! > 0 ? (completed / total!).clamp(0.0, 1.0) : 1.0);

  @override
  String toString() => 'BatchDownloadProgress($completed/${total ?? '?'}, new: $written, failed: $failed, $current)';
}

/// Bytes buffered before the writer waits for the disk, bounding memory when the source
/// outruns the destination.
const _flushEvery = 4 * 1024 * 1024;

/// How often a transfer reports itself: an event per few-KB chunk cost allocations nobody
/// could see, at a frame rate. The final state is always reported.
const _reportEvery = Duration(milliseconds: 50);

/// What a download was asked for, on its way from the call site to the transfer.
typedef _Transfer = ({
  Map<String, String>? headers,
  bool overwrite,
  bool resume,
  bool ifModified,
  (Hash algorithm, String hex)? checksum,
});

/// A download whose bytes do not hash to what the caller said; its `.part` is discarded.
///
/// {@category Networking}
final class ChecksumMismatch implements Exception {
  final Uri url;
  final Hash algorithm;
  final String expected;
  final String actual;

  const ChecksumMismatch(this.url, this.algorithm, this.expected, this.actual);

  @override
  String toString() => '$url: ${algorithm.name} is $actual, expected $expected';
}

/// Download operations on [Path].
///
/// {@category Networking}
extension PathDownloadExtensions on Path {
  /// Downloads [url] to this path atomically, as a batch of one, so `show()` renders it.
  ///
  /// Writes `<name>.part`, verifies `Content-Length`, renames on success, and stops on the
  /// enclosing [Cancel.scope]. A failed transfer keeps its `.part` for the next download to
  /// resume with a `Range` when [resume] is set.
  ///
  /// [ifModified] sends the destination's timestamp as `if-modified-since` — a `304` is a
  /// [DownloadSkipped] — and implies [overwrite]. [checksum] is what the bytes must hash to;
  /// else a [DownloadFailed] holding a [ChecksumMismatch].
  ///
  /// ```dart
  /// await 'sdk.zip'.path.download(url, checksum: (Hash.sha256, '9f86d0…')).show();
  /// ```
  Stream<BatchDownloadProgress> download(
    Uri url, {
    Map<String, String>? headers,
    bool overwrite = false,
    bool resume = true,
    bool ifModified = false,
    (Hash algorithm, String hex)? checksum,
  }) => _batchDownload(
    Stream.value((url: url, path: this)),
    knownTotal: 1,
    concurrency: 1,
    how: (headers: headers, overwrite: overwrite, resume: resume, ifModified: ifModified, checksum: checksum),
  );

  /// One file, fresh or from the `.part` a failed run left.
  ///
  /// A resume sends the first answer's validator (kept as `<name>.part.if-range`) as
  /// `If-Range`, so a changed file comes back whole rather than as a tail spliced onto the
  /// old head; a `206` not starting where the part ends is refetched whole. Under
  /// `Http.scope(retries:)` a transfer cut off half-way carries on from where it stopped.
  Stream<DownloadProgress> _download(Uri url, _Transfer how) async* {
    final (:headers, :overwrite, :resume, :ifModified, :checksum) = how;
    final present = await exists();
    if (present && !overwrite && !ifModified) {
      yield DownloadSkipped(url, this);
      return;
    }

    if (Cancel.token case final token? when token.isCancelled) {
      yield DownloadFailed(url, this, _cancelled(token));
      return;
    }

    final lease = _clientFor();
    final part = File('${asFile.path}.part');
    final validator = File('${asFile.path}.part.if-range');
    final budget = switch (lease.client) {
      final _ScopeClient scope => scope._retries,
      _ => 0,
    };

    try {
      var offset = resume && await part.exists() ? await part.length() : 0;
      // A half-written `.part` says nothing about when the file changed.
      final since = ifModified && present && offset == 0 ? HttpDate.format(await modified()) : null;
      var received = offset;
      String? lastModified;

      for (var attempt = 0; ; attempt++) {
        final request = Request('GET', url, headers: headers)..[Request.raw] = true;
        if (offset > 0) {
          request.headers['range'] = 'bytes=$offset-';
          if (await _readValidator(validator) case final tag?) request.headers['if-range'] = tag;
        } else if (since != null && attempt == 0) {
          request.headers.putIfAbsent('if-modified-since', () => since);
        }
        final streamed = await lease.client.send(request);
        if (streamed.headers['last-modified'] case final lm?) lastModified = lm;
        final status = streamed.statusCode;

        if (status == 304 && offset == 0) {
          unawaited(_drain(streamed));
          yield DownloadSkipped(url, this);
          return;
        }
        if (status == 416 && offset > 0) {
          unawaited(_drain(streamed));
          // `bytes */N` with N already here: a previous run stopped before the rename.
          if (_contentRange(streamed.headers['content-range']).total == offset) {
            received = offset;
            break;
          }
          // Otherwise the part is no prefix of the file; start over.
          await _discard(part);
          offset = 0;
          continue;
        }
        if (!streamed.isOk) {
          unawaited(_drain(streamed));
          yield DownloadFailed(url, this, HttpException(_status(status, streamed.reasonPhrase), uri: url));
          return;
        }
        final range = _contentRange(streamed.headers['content-range']);
        if (status == 206 && range.start != offset) {
          // Not the bytes the part is missing.
          unawaited(_drain(streamed));
          if (offset == 0) {
            yield DownloadFailed(
              url,
              this,
              HttpException('206 for bytes ${range.start}- of a request for all of it', uri: url),
            );
            return;
          }
          await _discard(part);
          offset = 0;
          continue;
        }
        final resumed = status == 206;
        if (!resumed) {
          offset = 0;
          await _keepValidator(validator, streamed.headers);
        }
        final total = resumed ? range.total : streamed.contentLength;

        await part.parent.create(recursive: true);
        final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
        received = offset;
        var unflushed = 0;
        Object? broke;

        final clock = Stopwatch()..start();
        var nextReport = Duration.zero;
        try {
          await for (final chunk in streamed.stream) {
            Cancel.throwIfCancelled();
            sink.add(chunk);
            received += chunk.length;
            unflushed += chunk.length;
            // `add` only queues: without this a slow disk buffers the difference in memory.
            if (unflushed >= _flushEvery) {
              unflushed = 0;
              await sink.flush();
            }
            // The first chunk always reports, so a slow transfer shows itself at once.
            if (clock.elapsed >= nextReport) {
              nextReport = clock.elapsed + _reportEvery;
              yield Downloading(url, this, received: received, total: total);
            }
          }
        } catch (e) {
          broke = e;
        } finally {
          await sink.close();
        }

        if (broke == null && (total == null || received == total)) break;
        final error =
            broke ?? HttpException('Download incomplete: expected $total bytes but received $received bytes', uri: url);
        if (broke == null && received > total!) {
          await _discard(part); // not a prefix of anything
          await _discard(validator);
          throw error;
        }
        if (attempt >= budget || !_transient(error) || Cancel.isCancelled) throw error;
        await _Retry.backoff(attempt).delay();
        offset = received;
      }

      if (checksum case (final algorithm, final expected)) {
        final actual = await Path(part.path).hash(algorithm);
        if (actual.toLowerCase() != expected.toLowerCase()) {
          await _discard(part);
          await _discard(validator);
          yield DownloadFailed(url, this, ChecksumMismatch(url, algorithm, expected.toLowerCase(), actual));
          return;
        }
      }

      await part.rename(asFile.path);
      await _discard(validator);
      if (lastModified != null) {
        try {
          await asFile.setLastModified(HttpDate.parse(lastModified));
        } catch (_) {}
      }
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

/// A `content-range`'s start (`null` for `*`) and total (`null` when unknown).
({int? start, int? total}) _contentRange(String? header) {
  final m = _range.firstMatch(header ?? '');
  if (m == null) return (start: null, total: null);
  return (start: m[1] == null ? null : int.parse(m[1]!), total: int.tryParse(m[2]!));
}

final _range = RegExp(r'bytes\s+(?:(\d+)-\d+|\*)/(\d+|\*)', caseSensitive: false);

/// Keeps a resume's `If-Range` validator: a strong `ETag` (a weak one may not be used),
/// else `Last-Modified`; with neither, a resume is trusted.
Future<void> _keepValidator(File file, Headers headers) async {
  final tag = headers['etag'];
  final value = tag != null && !tag.startsWith('W/') ? tag : headers['last-modified'];
  try {
    if (value == null) {
      await _discard(file);
    } else {
      await file.parent.create(recursive: true);
      await file.writeAsString(value);
    }
  } catch (_) {}
}

Future<String?> _readValidator(File file) async {
  try {
    final value = (await file.readAsString()).trim();
    return value.isEmpty ? null : value;
  } catch (_) {
    return null;
  }
}

Stream<BatchDownloadProgress> _batchDownload(
  Stream<({Uri url, Path path})> source, {
  required _Transfer how,
  int? knownTotal,
  int concurrency = 4,
}) {
  final cancelToken = Cancel.token;
  final controller = StreamController<BatchDownloadProgress>();
  final limit = concurrency > 0 ? concurrency : 1;
  final queue = Queue<({Uri url, Path path})>();
  final active = <Future<void>>{};
  final lease = _clientFor();

  var discovered = 0;
  var completed = 0;
  var written = 0;
  var failed = 0;
  var sourceDone = false;
  var stopped = false;
  // The consumer stopped listening, so the transfers just stop.
  var abandoned = false;
  StreamSubscription<({Uri url, Path path})>? subscription;
  void Function()? unregister;
  Timer? grace;

  // Two pairs naming one destination would write one `.part` from two sockets.
  final destinations = <String>{};

  void finish() {
    stopped = true;
    grace?.cancel();
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
        failed: failed,
        current: progress,
      ),
    );
  }

  // A cancel stops the source, fails what is queued, and lets transfers in flight report
  // their [DownloadFailed] as the client aborts them — within a grace period.
  void stop() {
    stopped = true;
    subscription?.cancel();
    final reason = _cancelled(cancelToken!);
    while (queue.isNotEmpty) {
      final item = queue.removeFirst();
      completed++;
      failed++;
      emit(DownloadFailed(item.url, item.path, reason));
    }
    if (active.isEmpty) {
      finish();
    } else {
      grace ??= Timer(const Duration(seconds: 2), finish);
    }
  }

  // A discovery stream that outran the transfers would queue the whole crawl.
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
    if (stopped || controller.isClosed) return;
    applyBackpressure();

    while (queue.isNotEmpty && active.length < limit) {
      final item = queue.removeFirst();

      late final Future<void> task;
      Future<void> transfer() async {
        // Each file's download joins the batch's client.
        final transfers = _withClient(lease.client, () => item.path._download(item.url, how));
        await for (final p in transfers) {
          if (abandoned) break;
          if (p.isDone) {
            completed++;
            if (p is Downloaded) written++;
            if (p is DownloadFailed) failed++;
          }
          emit(p);
        }
      }

      task = Future<void>(() async {
        try {
          if (abandoned) return;
          // The batch's token, wherever the stream is listened to, so the client can abort.
          await (cancelToken == null ? transfer() : Cancel.scope(transfer, token: cancelToken));
        } catch (e) {
          completed++;
          failed++;
          emit(DownloadFailed(item.url, item.path, e));
        } finally {
          active.remove(task);
          if (active.isEmpty && (stopped || (queue.isEmpty && sourceDone))) {
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
      // Cancelled before it began, each pair still reports its own [DownloadFailed], at once.
      final early = cancelToken?.isCancelled ?? false;
      subscription = source.listen(
        (item) {
          discovered++;
          if (!destinations.add(item.path.absolute)) {
            completed++;
            emit(DownloadSkipped(item.url, item.path));
            return;
          }
          queue.add(item);
          schedule();
        },
        onError: controller.addError,
        onDone: () {
          sourceDone = true;
          schedule();
        },
      );
      if (!early) unregister = cancelToken?.onCancel(stop);
    }
    // A consumer that stops listening stops the transfers, not just the reports.
    ..onCancel = () {
      abandoned = true;
      finish();
    };

  return controller.stream;
}

/// Batch downloads over a fixed set of pairs.
///
/// {@category Networking}
extension IterableDownloadExtensions on Iterable<({Uri url, Path path})> {
  /// Downloads every pair, at most [concurrency] at a time; see [PathDownloadExtensions.download].
  Stream<BatchDownloadProgress> download({
    Map<String, String>? headers,
    int concurrency = 4,
    bool overwrite = false,
    bool resume = true,
    bool ifModified = false,
  }) {
    final items = toList();
    return _batchDownload(
      Stream.fromIterable(items),
      knownTotal: items.length,
      concurrency: concurrency,
      how: (headers: headers, overwrite: overwrite, resume: resume, ifModified: ifModified, checksum: null),
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
  Stream<BatchDownloadProgress> download({
    Map<String, String>? headers,
    int concurrency = 4,
    bool overwrite = false,
    bool resume = true,
    bool ifModified = false,
  }) => _batchDownload(
    this,
    concurrency: concurrency,
    how: (headers: headers, overwrite: overwrite, resume: resume, ifModified: ifModified, checksum: null),
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
  /// One destination per URL; for two, use the [IterableDownloadExtensions] form.
  Stream<BatchDownloadProgress> download({
    Map<String, String>? headers,
    int concurrency = 4,
    bool overwrite = false,
    bool resume = true,
    bool ifModified = false,
  }) => pairs.download(
    headers: headers,
    concurrency: concurrency,
    overwrite: overwrite,
    resume: resume,
    ifModified: ifModified,
  );
}
