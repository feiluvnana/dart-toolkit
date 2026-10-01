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

/// Bytes buffered before the writer waits for the disk. Bounds the memory a download
/// can hold when the source is faster than the destination.
const _flushEvery = 4 * 1024 * 1024;

/// How often a transfer in flight reports itself.
///
/// A chunk arrives every few kilobytes and the renderer draws at a frame rate, so an event
/// per chunk allocated two objects and pumped two stream controllers for an update nobody
/// could see — and made the socket wait on the consumer to do it. The final state is always
/// reported, whenever it lands.
const _reportEvery = Duration(milliseconds: 50);

/// What a download was asked for, on its way from the call site to the transfer.
///
/// Spelled once here rather than once per hop between the four `download` receivers, the
/// batch loop and the writer, as [_Plan] is for a crawl.
typedef _Transfer = ({
  Map<String, String>? headers,
  bool overwrite,
  bool resume,
  bool ifModified,
  (Hash algorithm, String hex)? checksum,
});

/// A download whose bytes do not hash to what the caller said they would. The `.part` file
/// is discarded: it is not what was asked for, and resuming it would never make it so.
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
  /// Downloads [url] to this path atomically, streaming the same [BatchDownloadProgress]
  /// every other `download` streams — one file is a batch of one, so `show()` renders it
  /// and nothing has to be wrapped in a map to be reported.
  ///
  /// Writes `<name>.part` and renames on success, verifies `Content-Length`, and stops on
  /// the enclosing [Cancel.scope]. A failed or cancelled transfer keeps its `.part`; the next
  /// download of the same path resumes it with a `Range` request when [resume] is set, and
  /// starts over when the server does not honour the range. The per-file state is
  /// [BatchDownloadProgress.current].
  ///
  /// [ifModified] asks the server whether the file changed rather than skipping because it
  /// is there: the destination's timestamp goes out as `if-modified-since` and a `304` is a
  /// [DownloadSkipped]. It implies [overwrite], since a file that did change is meant to
  /// replace the old one.
  ///
  /// [checksum] is what the bytes must hash to; anything else is a [DownloadFailed] holding
  /// a [ChecksumMismatch], and the `.part` is discarded rather than left to resume. It is
  /// on this form alone: one checksum describes one file, so a batch has no use for it.
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

  /// One file, from a fresh start or from the `.part` a failed run left.
  ///
  /// A resume is only a resume of *the same file*. The first answer's validator — a strong
  /// `ETag`, else its `Last-Modified` — is kept beside the part as `<name>.part.if-range`,
  /// and a resume sends it as `If-Range`: a server whose file changed answers `200` with the
  /// whole new one instead of `206` with the tail of it, which spliced onto the old head was
  /// a file that had never existed, reported as [Downloaded]. A `206` must also start where
  /// the part ends; one that does not is thrown away and the file fetched whole.
  ///
  /// Inside `Http.scope(retries:)` a transfer cut off half-way — a reset, a server that sent
  /// less than it announced — carries on from the byte it stopped at, within that budget.
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
      // Only against a destination already in place: a half-written `.part` says nothing
      // about when the whole file was last changed.
      final since = ifModified && present && offset == 0 ? HttpDate.format(await modified()) : null;
      var received = offset;
      String? lastModified;

      for (var attempt = 0; ; attempt++) {
        // A download wants the resource, so it says so: a client that renders pages hands
        // this to plain HTTP instead of building a DOM out of a zip. See [Request.raw].
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
          // `bytes */N` with N what is already here: the part *is* the file, and a previous
          // run stopped between the last byte and the rename.
          if (_contentRange(streamed.headers['content-range']).total == offset) {
            received = offset;
            break;
          }
          // Otherwise the part is not a prefix of what the server has now; start over.
          await _discard(part);
          offset = 0;
          continue;
        }
        if (!streamed.isOk) {
          // Close the body instead of holding the connection until GC.
          unawaited(_drain(streamed));
          yield DownloadFailed(url, this, HttpException(_status(status, streamed.reasonPhrase), uri: url));
          return;
        }
        final range = _contentRange(streamed.headers['content-range']);
        if (status == 206 && range.start != offset) {
          // Not the bytes the part is missing: not these, and not a resume.
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
            // `add` only queues, so without this the socket is throttled by the
            // consumer and never by the disk, and a slow destination buffers the
            // difference in memory.
            if (unflushed >= _flushEvery) {
              unflushed = 0;
              await sink.flush();
            }
            // See [_reportEvery]. The first chunk always reports, so a slow transfer shows
            // itself at once rather than after the first interval.
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
        if (broke == null && received > total!) {
          await _discard(part); // not a prefix of anything; useless
          await _discard(validator);
          throw HttpException('Download incomplete: expected $total bytes but received $received bytes', uri: url);
        }
        final error =
            broke ?? HttpException('Download incomplete: expected $total bytes but received $received bytes', uri: url);
        if (attempt >= budget || !_transient(error) || Cancel.isCancelled) throw error;
        // Cut off: carry on from what is on disk.
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

/// What a `content-range` says: where the bytes start (`null` for `*`) and how long the whole
/// file is (`null` when the server does not know).
({int? start, int? total}) _contentRange(String? header) {
  final m = _range.firstMatch(header ?? '');
  if (m == null) return (start: null, total: null);
  return (start: m[1] == null ? null : int.parse(m[1]!), total: int.tryParse(m[2]!));
}

final _range = RegExp(r'bytes\s+(?:(\d+)-\d+|\*)/(\d+|\*)', caseSensitive: false);

/// Keeps what identifies the file [headers] describe, for a resume's `If-Range`: a strong
/// `ETag` (a weak one may not be used there), else the `Last-Modified` date. With neither,
/// there is nothing to keep, and a resume is trusted as it always was.
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
  // The consumer stopped listening: nobody is left to tell, so the transfers just stop.
  var abandoned = false;
  StreamSubscription<({Uri url, Path path})>? subscription;
  void Function()? unregister;
  Timer? grace;

  // Two pairs naming one destination would write one `.part` from two sockets.
  final destinations = <String>{};

  bool cancelled() => stopped;

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

  // A cancel stops the source, fails what is queued, and lets each transfer in flight end —
  // the client aborts it — so its [DownloadFailed] is reported before the stream closes. A
  // client that does not abort is given a moment, not forever.
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
      Future<void> transfer() async {
        // The batch owns one client; each file's download joins it rather than opening
        // a connection of its own.
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
          // The batch's token, wherever the stream happens to be listened to from, so the
          // client in the zone below can abort on it.
          await (cancelToken == null ? transfer() : Cancel.scope(transfer, token: cancelToken));
        } catch (e) {
          completed++;
          failed++;
          emit(DownloadFailed(item.url, item.path, e));
        } finally {
          active.remove(task);
          if (active.isEmpty && (cancelled() || (queue.isEmpty && sourceDone))) {
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
      // Cancelled before it began, each pair still reports its own [DownloadFailed] — at
      // once, since a download in a cancelled scope sends nothing.
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
  /// A `Map` holds one destination per URL. To send one URL to two places, use the
  /// [IterableDownloadExtensions] form over records.
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
