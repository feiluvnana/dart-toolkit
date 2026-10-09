// Downloads: one URL to one file, as a `Task<Path>`; many are `parallelize`.

part of '../http.dart';

/// What a download's bytes must hash to: `Checksum(Hash.sha256, '9f86d0…')`. The hex is checked
/// when made (a `Hex`): anything but hex digits is a [FormatException].
///
/// {@category Networking}
final class Checksum {
  final Hash algorithm;
  final String hex;

  Checksum(this.algorithm, String hex) : hex = Hex(hex).trim().toLowerCase();

  @override
  String toString() => '${algorithm.name} $hex';
}

/// A download whose bytes do not hash to its [Checksum]; its `.part` is deleted.
/// `Invalid checksum in <url>: sha256 is <actual>, expected <expected>`.
///
/// {@category Networking}
final class ChecksumException extends FormatException {
  final Uri url;
  final Checksum expected;
  final String actual;

  ChecksumException(this.url, this.expected, this.actual)
    : super('Invalid checksum in $url: ${expected.algorithm.name} is $actual, expected ${expected.hex}');

  @override
  String toString() => message;
}

/// Downloading one URL to a file.
///
/// {@category Networking}
extension UriDownload on Uri {
  /// Downloads this URL to the file [to], or into the folder [into] under the name the server
  /// gives it (`Content-Disposition`, else the final URL's name; see [Response.name]): a
  /// `Task<Path>` of the file written. Exactly one of [to] and [into]. Many downloads are
  /// `urls.parallelize((u) => u.download(into: 'out'))`.
  ///
  /// ```dart
  /// await url.download(into: 'out');
  /// await url.download(to: 'out/sdk.zip', checksum: Checksum(Hash.sha256, digest), segments: 4);
  /// await url.download(into: 'out', accept: 'image/', conflict: Conflict.newer, headers: {'referer': '$page'});
  /// ```
  ///
  /// - It writes `<file>.part` and renames it into place once whole (the `Content-Length`
  ///   checked, the [checksum] too, as the step `verifying`): a file never exists half-written.
  /// - [conflict] says what a file already there means: [Conflict.skip] (the default) leaves it,
  ///   `Done(fresh: false)`, asking nothing when [to] names it (or [into] and a URL whose name
  ///   has no query string, so it names the file); [Conflict.newer] asks the server with
  ///   `If-Modified-Since`, a `304` being `Done(fresh: false)`; [Conflict.rename] picks a free
  ///   `name (1).ext`. Two downloads wanting one name at once get the same answer: the second
  ///   skips, fails, renames, or waits to replace the first.
  /// - [resume] keeps the `.part` of a download that stopped or failed, and the next one carries
  ///   on from it with a `Range` (checked with `If-Range`, so a changed file comes back whole);
  ///   with `resume: false` a stopped one deletes it.
  /// - [accept] is the media type the answer must be (`'image/'` takes any image); anything else
  ///   is a [FormatException]. Without it, an HTML page where the file's name says otherwise is
  ///   one too, so a `200` error page is never saved as `report.pdf`.
  /// - [segments] fetches the file in that many ranged parts at once (each at least 1 MiB) when
  ///   the server takes ranges and says the length, each part resumed where it stopped.
  /// - The scope's retry policy carries a broken transfer on from where it stopped; waits show
  ///   as the steps `waiting` and `retry 1/3`.
  Task<Path> download({
    String? to,
    String? into,
    Checksum? checksum,
    int segments = 1,
    String? accept,
    Conflict conflict = Conflict.skip,
    Map<String, String>? headers,
    bool resume = true,
  }) {
    if ((to == null) == (into == null)) {
      throw ArgumentError('Invalid destination: give exactly one of to: (a file) and into: (a folder)');
    }
    if (segments < 1) throw ArgumentError.value(segments, 'segments', 'Invalid segments, expected at least 1');
    if (accept != null) {
      try {
        Mime(accept);
      } on FormatException catch (e) {
        throw ArgumentError.value(accept, 'accept', e.message);
      }
    }
    final job = _Download(
      _settings,
      this,
      to: to,
      into: into == null ? null : _folder(into),
      checksum: checksum,
      segments: segments,
      accept: accept == null ? null : Mime(accept),
      conflict: conflict,
      headers: headers,
      resume: resume,
    );
    return TaskInternals.start(this, job.label, job.run);
  }
}

/// [into] without a trailing separator.
String _folder(String into) => into.length > 1 && (into.endsWith('/') || into.endsWith(Platform.pathSeparator))
    ? into.substring(0, into.length - 1)
    : into;

/// Files a download in this process is writing, by absolute path, each with when it is done.
final _writing = <String, Future<void>>{};

/// The names of [_writing], for a rename to step around.
final _taken = <String>{};

String _absolute(String path) => File(path).absolute.path;

/// What a download is told about its file before it writes it.
sealed class _Landing {}

/// Write it to [path]; [since] is the time the server's copy must be newer than.
final class _Write extends _Landing {
  final String path;
  final DateTime? since;
  _Write(this.path, [this.since]);
}

/// Leave [path] as it is: `Done(fresh: false)`.
final class _Keep extends _Landing {
  final String path;
  _Keep(this.path);
}

/// A part answered with the whole file, or other bytes than it asked for: the file changed
/// since the parts were planned, or a resume asked for the wrong name's tail.
final class _Restart implements Exception {
  /// Whether the part is kept, to be carried on with a range.
  final bool keep;

  const _Restart({this.keep = false});
}

final class _Download {
  final _Settings s;
  final Uri url;
  final String? to;
  final String? into;
  final Checksum? checksum;
  final int segments;
  final Mime? accept;
  final Conflict conflict;
  final Map<String, String>? headers;
  final bool resume;

  _Download(
    this.s,
    this.url, {
    required this.to,
    required this.into,
    required this.checksum,
    required this.segments,
    required this.accept,
    required this.conflict,
    required this.headers,
    required this.resume,
  });

  /// The URL's own name, when it names the file: it has one and no query string.
  String? get _ownName => url.name.isEmpty || url.hasQuery ? null : url.name;

  String get label => FileBridge.label(to ?? '$into/${url.name.isEmpty ? url.host : url.name}');

  /// The file being written, once settled, and the end of this download's claim on it.
  String? _target;
  Completer<void>? _claim;

  late Work _work;
  late File _part, _validator, _ranges;

  void _aim(String target) {
    _target = target;
    _part = File('$target.part');
    _validator = File('$target.part.if-range');
    _ranges = File('$target.part.ranges');
  }

  Future<Path> run(Work work) async {
    _work = work;
    work.defer(() async {
      final claim = _claim;
      if (claim != null) {
        final absolute = _absolute(_target!);
        _writing.remove(absolute);
        _taken.remove(absolute);
        claim.complete();
      }
      // A stopped download without resume, or one stopped for good (its job removed), leaves
      // nothing behind; a paused one keeps its part for when it carries on.
      final ended = work.ended;
      final forgotten = ended is Stopped && ended.reason == Stopped.removed;
      if (_target != null && (forgotten || (!resume && ended is! Done))) await _forget();
    });
    var landing = switch ((to, _ownName)) {
      (final file?, _) => await _settle(file),
      (null, final name?) => await _settle('$into${Platform.pathSeparator}$name'),
      _ => null,
    };
    if (landing case _Keep(:final path)) return _kept(path);
    if (landing case _Write(:final path)) _aim(path);
    if (!resume && _target != null) await _forget();
    final since = landing is _Write ? landing.since : null;

    final String? modified;
    try {
      modified = await _retrying(s, Request('GET', url), () => _transfer(since), step: work.step);
    } on _NotModified {
      return _kept(_target!);
    }
    final target = _target!;
    if (checksum case final sum?) {
      work.step('verifying');
      final digest = await TaskInternals.detached(() => sum.algorithm.file(_part.path));
      if (!digest.matches(sum.hex)) {
        await _forget();
        throw ChecksumException(url, sum, digest.hex);
      }
    }
    await FileBridge.rename(_part, target);
    await _discard(_validator);
    if (modified != null && modified.isNotEmpty) {
      try {
        await File(target).setLastModified(HttpDate.parse(modified));
      } catch (_) {} // best-effort: a file without its server timestamp is still the file
    }
    return Path(target);
  }

  /// Gives up the claim on [path], which is left as it is.
  void _keepOnly(String path) {
    final claim = _claim;
    _writing.remove(_absolute(path));
    _taken.remove(_absolute(path));
    _claim = null;
    claim?.complete();
  }

  Path _kept(String path) {
    TaskInternals.stale(_work);
    return Path(path);
  }

  Future<void> _forget() async {
    await _discard(_part);
    await _discard(_validator);
    await _discard(_ranges);
  }

  /// Where [path] goes under [conflict], claimed for this download before anything is awaited,
  /// so two downloads never both take one name.
  Future<_Landing> _settle(String path) async {
    final absolute = _absolute(path);
    if (_writing[absolute] case final other?) {
      switch (conflict) {
        case Conflict.skip:
          return _Keep(path);
        case Conflict.fail:
          throw PathExistsException(path, const OSError(), 'Cannot download $url: $path exists');
        case Conflict.rename:
          return _settle(FileBridge.free(path, claimed: _taken));
        case Conflict.overwrite || Conflict.newer:
          await other;
          return _settle(path);
      }
    }
    final claim = Completer<void>();
    _taken.add(absolute);
    _writing[absolute] = claim.future;
    void unclaim() {
      _taken.remove(absolute);
      _writing.remove(absolute);
      claim.complete();
    }

    DateTime? since;
    try {
      final there = await FileSystemEntity.type(path, followLinks: true);
      if (there == FileSystemEntityType.directory) {
        throw PathExistsException(path, const OSError(), 'Cannot download $url: $path is a folder');
      }
      if (there != FileSystemEntityType.notFound) {
        switch (conflict) {
          case Conflict.skip:
            unclaim();
            return _Keep(path);
          case Conflict.fail:
            throw PathExistsException(path, const OSError(), 'Cannot download $url: $path exists');
          case Conflict.rename:
            unclaim();
            return await _settle(FileBridge.free(path, claimed: _taken));
          case Conflict.overwrite:
            break;
          case Conflict.newer:
            since = await File(path).lastModified();
        }
      }
    } catch (_) {
      if (!claim.isCompleted) unclaim();
      rethrow;
    }
    _claim = claim;
    return _Write(path, since);
  }

  /// One try: from where the `.part` stopped to the end. Answers the server's `Last-Modified`.
  Future<String?> _transfer(DateTime? since) async {
    while (true) {
      try {
        return await _once(since);
      } on _Restart catch (restart) {
        // From the top, or from the part of the name the server gave: not a retry.
        if (!restart.keep) await _forget();
      }
    }
  }

  Future<String?> _once(DateTime? since) async {
    var offset = _target != null && await _part.exists() ? await _part.length() : 0;
    // A part with holes is never resumed as a prefix: its ranges carry on where each stopped.
    if (offset > 0 && await _ranges.exists()) {
      final saved = await _Segments.load(_part, _ranges);
      if (saved == null) throw const _Restart();
      await saved.run(this);
      return saved.modified;
    }
    final request = Request('GET', url, headers: headers)..[Request.raw] = true;
    if (offset > 0) {
      request.headers['range'] = 'bytes=$offset-';
      if (await _readValidator(_validator) case final tag?) request.headers['if-range'] = tag;
    } else if (since != null) {
      request.headers['if-modified-since'] = HttpDate.format(since);
    }
    final res = await _exchange(s, request, step: _work.step);
    final status = res.statusCode;
    if (status == 304 && since != null && offset == 0) {
      unawaited(_drain(res));
      throw const _NotModified();
    }
    if (status == 416 && offset > 0) {
      unawaited(_drain(res));
      // `bytes */N` with N already here: a previous run stopped before the rename.
      if (_contentRange(res.headers['content-range']).total == offset) return res.headers['last-modified'];
      throw const _Restart();
    }
    if (!res.isOk) throw await _refused(res, request);
    try {
      await _name(res, offset);
      _check(res);
    } catch (_) {
      unawaited(_drain(res));
      rethrow;
    }
    final range = _contentRange(res.headers['content-range']);
    if (status == 206 && range.start != offset) {
      unawaited(_drain(res));
      // Not the bytes the part is missing.
      if (offset == 0) throw ClientException('206 for bytes ${range.start}- of a request for all of it', url);
      throw const _Restart();
    }
    final resumed = status == 206;
    if (!resumed) {
      if (offset > 0 && _target != null) {
        // The server sent it whole: the part is no use.
        await _discard(_part);
      }
      offset = 0;
      await _keepValidator(_validator, res.headers);
    }
    final total = resumed ? range.total : res.contentLength;
    if (segments > 1 && !resumed && total != null && _ranged(res.headers)) {
      if (_Segments.plan(_part, _ranges, total, segments, res.headers) case final job?) {
        await job.run(this, first: res);
        return job.modified;
      }
    }
    await _pipe(res, offset, total, append: resumed);
    return res.headers['last-modified'];
  }

  /// Whether the server's name for the file has been settled.
  var _named = false;

  /// Settles the name the server gives the file, for a download [into] a folder: the URL's own
  /// name was a guess until now. A body that is the wrong name's tail ([offset] past 0), or one
  /// whose name has a part of its own, starts again under it.
  Future<void> _name(StreamedResponse res, int offset) async {
    if (to != null || _named) return;
    _named = true;
    final name = MessageInternals.serverName(res.headers, res.url ?? url);
    if (name.isEmpty && _target == null) throw MissingException('file name', where: '$url');
    final wanted = '$into${Platform.pathSeparator}$name';
    if (_target case final guess?) {
      if (name.isEmpty || _absolute(guess) == _absolute(wanted)) return;
      final claim = _claim;
      _writing.remove(_absolute(guess));
      _taken.remove(_absolute(guess));
      _claim = null;
      claim?.complete();
      await _forget();
      _target = null;
    }
    switch (await _settle(wanted)) {
      case _Keep(:final path):
        _target = path;
        throw const _NotModified();
      case _Write(:final path, :final since):
        _aim(path);
        // Asked too late for `If-Modified-Since`: the answer's own date decides.
        if (since != null) {
          final served = MessageInternals.httpDate(res.headers['last-modified'] ?? '');
          if (served != null && !served.isAfter(since)) {
            _keepOnly(path);
            throw const _NotModified();
          }
        }
        if (!resume) await _forget();
        if (offset > 0 || (resume && await _part.exists() && await _part.length() > 0)) {
          throw const _Restart(keep: true);
        }
    }
  }

  /// Fails an answer of a type nobody wanted: not [accept], or HTML where the file's name says
  /// otherwise.
  void _check(StreamedResponse res) {
    final type = res.headers['content-type'] ?? '';
    if (accept case final wanted?) {
      if (!wanted.matches(type)) {
        throw FormatException('Invalid content type in $url: "$type", expected "$wanted"');
      }
      return;
    }
    final media = type.split(';').first.trim().toLowerCase();
    if (media != 'text/html' && media != 'application/xhtml+xml') return;
    final ext = FileBridge.extension(_target!);
    if (ext.isEmpty || ext == 'html' || ext == 'htm' || ext == 'xhtml') return;
    throw FormatException('Invalid download in $url: an HTML page ($media) where a .$ext was expected');
  }

  /// [res]'s body into the part, from [offset], reporting its amount.
  Future<void> _pipe(StreamedResponse res, int offset, int? total, {required bool append}) async {
    await _part.parent.create(recursive: true);
    final sink = _part.openWrite(mode: append ? FileMode.append : FileMode.write);
    var received = offset;
    var reported = Clock.current.elapsed;
    var first = true;
    _work.amount(received, total: total);
    Object? broke;
    try {
      await sink.addStream(
        res.stream.map((chunk) {
          received += chunk.length;
          final now = Clock.current.elapsed;
          // The first chunk always reports, so a slow transfer shows itself at once.
          if (first || now - reported >= _reportEvery) {
            first = false;
            reported = now;
            _work.amount(received, total: total);
          }
          return chunk;
        }),
      );
    } catch (e) {
      broke = e;
    } finally {
      // A broken body has failed the sink too; what it wrote is the `.part` to resume.
      await sink.close().catchError((Object e) => broke ??= e);
    }
    _work.amount(received, total: total);
    if (broke case final e?) throw e;
    if (total == null || received == total) return;
    if (received > total) {
      await _forget();
      throw FormatException('Invalid download in $url: $received bytes where Content-Length said $total');
    }
    throw ClientException('Download incomplete: expected $total bytes but received $received', url);
  }
}

/// A `304` to `If-Modified-Since`, or a name the policy keeps: nothing to write.
final class _NotModified implements Exception {
  const _NotModified();
}

/// Whether a server takes byte ranges: it said `Accept-Ranges: bytes`.
bool _ranged(Headers headers) => (headers['accept-ranges'] ?? '').toLowerCase().contains('bytes');

/// The smallest part [_Segments] splits a file into.
const _minimumPart = 1 << 20;

/// A download in ranged parts, written in place into one preallocated `.part`; each part's
/// progress is kept in `<name>.part.ranges`, so a later run resumes each where it stopped.
final class _Segments {
  final File part;
  final File ranges;
  final int total;

  /// The first answer's `If-Range` validator, as [_keepValidator] picks it.
  final String? validator;

  /// The first answer's `Last-Modified`, for the finished file.
  final String? modified;

  /// Per part: its first byte, its last, and how many are on disk.
  final List<List<int>> parts;

  /// Per part: bytes read and not yet written, for progress.
  final List<int> _pending;

  _Segments(this.part, this.ranges, this.total, this.validator, this.modified, this.parts)
    : _pending = List.filled(parts.length, 0);

  /// [total] bytes in up to [count] parts of at least [_minimumPart]; `null` when that is fewer
  /// than two.
  static _Segments? plan(File part, File ranges, int total, int count, Headers headers) {
    final most = total ~/ _minimumPart;
    final n = count < most ? count : most;
    if (n < 2) return null;
    final size = (total + n - 1) ~/ n;
    final tag = headers['etag'];
    return _Segments(
      part,
      ranges,
      total,
      tag != null && !tag.startsWith('W/') ? tag : headers['last-modified'],
      headers['last-modified'],
      [
        for (var i = 0; i < n; i++) [i * size, ((i + 1) * size < total ? (i + 1) * size : total) - 1, 0],
      ],
    );
  }

  /// The parts [ranges] holds for [part], or `null` when either is missing, unreadable or
  /// disagrees with the other.
  static Future<_Segments?> load(File part, File ranges) async {
    try {
      final saved = jsonDecode(await ranges.readAsString()) as Map<String, Object?>;
      final total = saved['total']! as int;
      if (!await part.exists() || await part.length() != total) return null;
      return _Segments(part, ranges, total, saved['validator'] as String?, saved['modified'] as String?, [
        for (final span in saved['parts']! as List) [for (final n in span as List) n as int],
      ]);
    } on Object catch (_) {
      return null; // unreadable: the file is fetched again whole
    }
  }

  int get received {
    var sum = 0;
    for (var i = 0; i < parts.length; i++) {
      sum += parts[i][2] + _pending[i];
    }
    return sum;
  }

  /// Writes [ranges] whole, through a sibling renamed over it.
  Future<void> _save() => FileBridge.write(
    ranges.path,
    utf8.encode(jsonEncode({'total': total, 'validator': validator, 'modified': modified, 'parts': parts})),
  );

  /// Fetches every part at once ([first], the answer that planned them, is the first part's),
  /// reporting the bytes received on [d]'s work. Ends with [ranges] gone, or kept for a resume
  /// when it fails; [_Restart] when the file changed under the parts.
  Future<void> run(_Download d, {StreamedResponse? first}) async {
    if (first != null) {
      // Saved before the part exists: a part with holes never lacks its ranges.
      await part.parent.create(recursive: true);
      await _save();
      final raf = await part.open(mode: FileMode.write);
      try {
        await raf.truncate(total);
      } finally {
        await raf.close();
      }
    }
    final stop = CancelToken();
    final outer = Cancel.token;
    final unhear = outer?.onCancel(() => stop.cancel(outer.reason));
    (Object, StackTrace)? failure;
    final all = Future.wait([
      for (var i = 0; i < parts.length; i++)
        Cancel.scope(token: stop, () => _part(i, d, i == 0 ? first : null)).catchError((Object e, StackTrace st) {
          // The first failure is the download's; it stops the other parts.
          failure ??= (e, st);
          stop.cancel();
        }),
    ]);
    final saving = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_save().catchError((Object _) {})); // best-effort: a resume redoes what is unsaved
    });
    final reporting = Timer.periodic(_reportEvery, (_) => d._work.amount(received, total: total));
    try {
      await all;
    } finally {
      saving.cancel();
      reporting.cancel();
      unhear?.call();
      d._work.amount(received, total: total);
      failure == null ? await _discard(ranges) : await _save();
    }
    if (failure case (final e, final st)) Error.throwWithStackTrace(e, st);
  }

  /// Part [i], from where it stopped to its end, tried again as the scope says.
  Future<void> _part(int i, _Download d, StreamedResponse? first) {
    final span = parts[i];
    final request = Request('GET', d.url, headers: d.headers)..[Request.raw] = true;
    return _retrying(d.s, request, () async {
      final from = span[0] + span[2];
      final end = span[1];
      var res = first;
      first = null;
      if (from > end) {
        if (res != null) unawaited(_drain(res));
        return;
      }
      if (res == null) {
        final ask = request.copy()..headers['range'] = 'bytes=$from-$end';
        if (validator case final tag?) ask.headers['if-range'] = tag;
        res = await _exchange(d.s, ask);
        if (res.statusCode != 206 || _contentRange(res.headers['content-range']).start != from) {
          if (res.isOk) {
            unawaited(_drain(res));
            throw const _Restart();
          }
          throw await _refused(res, ask);
        }
      }
      await _write(i, res, from, end, d.url);
    });
  }

  /// [res]'s bytes [from] to [end] into the part, a MiB at a time; past [end] it is cut.
  Future<void> _write(int i, StreamedResponse res, int from, int end, Uri url) async {
    final raf = await part.open(mode: FileMode.append);
    final buffer = BytesBuilder(copy: false);
    try {
      await raf.setPosition(from);
      var at = from;
      Future<void> flush() async {
        if (buffer.isEmpty) return;
        final length = buffer.length;
        await raf.writeFrom(buffer.takeBytes());
        parts[i][2] += length;
        _pending[i] = 0;
      }

      try {
        await for (final chunk in res.stream) {
          final room = end + 1 - at;
          final kept = chunk.length > room ? chunk.sublist(0, room) : chunk;
          buffer.add(kept);
          at += kept.length;
          _pending[i] = buffer.length;
          if (buffer.length >= _minimumPart) await flush();
          if (at > end) break;
        }
      } finally {
        // What arrived before a break is good: kept, so a resume starts after it.
        await flush();
      }
      if (at <= end) throw ClientException('Download incomplete: bytes $from-$end ended at $at', url);
    } finally {
      _pending[i] = 0;
      await raf.close();
    }
  }
}

/// A `content-range`'s start (`null` for `*`) and total (`null` when unknown).
({int? start, int? total}) _contentRange(String? header) {
  final m = _range.firstMatch(header ?? '');
  if (m == null) return (start: null, total: null);
  return (start: m[1] == null ? null : int.parse(m[1]!), total: int.tryParse(m[2]!));
}

final _range = RegExp(r'bytes\s+(?:(\d+)-\d+|\*)/(\d+|\*)', caseSensitive: false);

/// Keeps a resume's `If-Range` validator: a strong `ETag` (a weak one may not be used), else
/// `Last-Modified`; with neither, a resume is trusted.
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
  } on FileSystemException catch (_) {} // best-effort: no validator means a full fetch next time
}

Future<String?> _readValidator(File file) async {
  try {
    final value = (await file.readAsString()).trim();
    return value.isEmpty ? null : value;
  } on FileSystemException catch (_) {
    return null; // none kept: the resume is trusted
  }
}
