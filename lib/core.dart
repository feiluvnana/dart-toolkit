/// Core pipeline: bytes flow from a [Reader], through [Pipe]s, into a
/// [Writer], watched by [Probe]s: `reader | pipe & probe > writer`.
///
/// ```dart
/// final http = Http.client();
/// await (http.get(url) & Console.bar('a.zip') | hash > Fs.file('a.zip'));
/// await (http.get(url) | hash > null);   // checksum only, nothing stored
/// final text = await http.get(url).text();
/// ```
///
/// Public surface is exactly: [Reader], [Writer], [Pipe], [Probe], [Meter],
/// [Task], [Watch], [Closeable], [Origin], [ToolkitException],
/// [ContentException], [PasswordException]. Helpers (unit literals, sizes,
/// times, `Rate`, `Cookies`, hashes) are `package:dart_toolkit/utils.dart`.
/// - [Reader]: `stream` `bytes` `text` `lines` `|` `&` `>` (+ `origin`, `of`).
/// - [Writer]: `consume` (+ `origin`).
/// - [Probe]: `update`; `&` attaches one to a reader, a [Task] or (via
///   [Watch]) any future, and it shows the whole run.
/// - [Meter]: a probe to draw by hand: `done` `total` `rate`.
/// - [Task]: a future that counts (`Pool.map`, `Dir.copy`): `&`.
/// - [Pipe]: `transform` `abort`.
/// - [Closeable]: `close`.
/// - [Origin]: typed `url()` / `status()` / `name()` / `path()` / `size()` for a reader.
/// - [ToolkitException]: the base of every failure the toolkit itself reports.
/// - [ContentException]: a value the toolkit rejects (bad JSON, archive, image…).
/// Everything else is private.
library;

// Origin's named parameters feed private fields, which initializing formals cannot do.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'src/progress.dart';
import 'src/resume.dart';

export 'src/progress.dart' show Meter, Probe, Task, Watch;

/// What a reader knows about its source: URL, status, file name, path, size.
///
/// Modules never import each other: `html`/`json` read `reader.origin().url()`
/// for the base URL and `origin().status()` for error-page annotation;
/// `chrome` reads `origin().name()`/`origin().path()` for upload staging.
/// A plain in-memory reader carries an empty [Origin].
final class Origin {
  /// An origin with whatever the source knows; [Origin.new] with no
  /// arguments is the empty one.
  const Origin({String? url, int? status, String? name, String? path, int? size})
    : _url = url,
      _status = status,
      _name = name,
      _path = path,
      _size = size;

  final String? _url;
  final int? _status;
  final String? _name;
  final String? _path;
  final int? _size;

  /// Final URL after redirects (http response), if any.
  String? url() => _url;

  /// HTTP status (response), if any.
  int? status() => _status;

  /// Suggested file name (`content-disposition`, URL tail), if any.
  String? name() => _name;

  /// File-system path (fs file, staged upload), if any.
  String? path() => _path;

  /// The length in bytes, when known without reading (a response's
  /// `content-length`, in-memory bytes); a file's comes from its [path].
  /// A probe learns its total from here.
  int? size() => _size;
}

/// Bytes you can read. Implement [stream]; everything else comes with it.
abstract mixin class Reader {
  /// Single-subscription chunks; the one member to implement.
  Stream<List<int>> stream();

  /// Where the bytes came from; empty unless the reader overrides it
  /// (`Response`, `Visit`, `File`, `Download`).
  Origin origin() => const Origin();

  /// An in-memory reader over [bytes]. The bytes reach every [Writer] the
  /// same way file or network bytes do.
  static Reader of(List<int> bytes) => _Memory(bytes);

  /// Read everything into memory.
  Future<List<int>> bytes() => _bytes(this);

  /// The text line by line as it arrives (UTF-8, malformed bytes replaced;
  /// `\n`, `\r\n` and `\r` end a line): logs, NDJSON, server-sent events,
  /// a program's output (`Shell.read(cmd).lines()`).
  Stream<String> lines() => stream().transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter());

  /// UTF-8, malformed bytes replaced; types may refine (charset).
  Future<String> text() async => utf8.decode(await bytes(), allowMalformed: true);

  /// The bytes through [pipe]. Lazy: nothing flows yet; null → this
  /// reader, unchanged.
  Reader operator |(Pipe? pipe) => pipe == null ? this : _PipedReader(this, pipe);

  /// This reader, watched by [probe]; null → unchanged. The probe shows
  /// the whole run it ends up in, wherever it sits: the source's bytes
  /// against the source's length (learned, never passed), or the work a
  /// source or writer reports (an encode, an archive).
  Reader operator &(Probe? probe) => probe == null ? this : _WatchedReader(this, probe);

  /// Runs the pipeline to the end into [writer]; null → run and discard.
  ///
  /// On failure every piped stage is notified via [Pipe.abort] **without
  /// starting anything new**: no probe listen-then-cancel, so a [Pipe] that
  /// would start a child process (shell filter) never starts one just to
  /// kill it, an http source is not marked streaming by the failure path,
  /// and broadcast sources poison their stages too.
  Future<void> operator >(Writer? writer) => _run(this, writer);
}

// Reader's longer bodies, kept out of the mixin that every reader copies.

Future<List<int>> _bytes(Reader reader) async {
  final out = BytesBuilder(copy: false);
  await for (final chunk in reader.stream()) {
    out.add(chunk);
  }
  return out.takeBytes();
}

Future<void> _run(Reader self, Writer? writer) async {
  final probes = _probes(self);
  final run = probes.isEmpty ? null : Run(probes);
  // Synchronously, before any await: a resumable GET (http `resume: true`)
  // piped into a path through pass-through pipes delivers itself.
  final path = writer?.origin().path();
  if (path != null) {
    final pipes = <Pipe>[];
    Reader cur = self;
    while (cur is _PipedReader || cur is _WatchedReader) {
      if (cur is _PipedReader) {
        pipes.insert(0, cur._pipe);
        cur = cur._source;
      } else {
        cur = (cur as _WatchedReader)._source;
      }
    }
    final source = cur is _FutureReader ? cur._future : cur;
    if (source is Resumable && pipes.every((p) => p is PassThrough) && source.claim()) {
      try {
        await source.resume(path, [if (run != null) _Counter(run), ...pipes]);
        run?.end();
        return;
      } catch (e) {
        _abortChain(self, e);
        run?.end(e);
        rethrow;
      }
    }
  }
  Stream<List<int>>? s;
  try {
    // [_open] is lazy (async*): creating [s] starts nothing. A writer that
    // throws before its first listen (missing parent, closed response)
    // therefore leaves the source untouched; [abort] below still
    // poisons/frees the stages.
    s = _open(self, run);
    if (writer == null) {
      await for (final _ in s) {
        // discard
      }
    } else {
      final works = run == null ? null : writing[writer];
      await (works == null ? writer.consume(s) : works(s, run!));
      // A writer that returned without reading everything (or anything)
      // must not leave the source open: a response would keep the VM alive.
      // Closing a fully read source is a no-op.
      unawaited(_closeRoot(self));
    }
    run?.end();
  } catch (e, st) {
    try {
      _abortChain(self, e);
    } catch (_) {}
    run?.end(e);
    unawaited(_closeRoot(self));
    Error.throwWithStackTrace(e, st);
  }
}

/// The probes attached anywhere along [reader]'s chain, outermost first.
List<Probe> _probes(Reader reader) {
  final out = <Probe>[];
  var cur = reader;
  while (true) {
    if (cur is _WatchedReader) {
      out.add(cur._probe);
      cur = cur._source;
    } else if (cur is _PipedReader) {
      cur = cur._source;
    } else {
      return out;
    }
  }
}

/// The bytes of [reader]'s chain, with [run] (if any) counting at the
/// root: the source's own work when it reports one, else its bytes
/// against its length. Lazy: nothing starts until listened.
Stream<List<int>> _open(Reader reader, Run? run) {
  if (reader is _WatchedReader) return _open(reader._source, run);
  if (reader is _PipedReader) return _piped(reader, run);
  if (reader is _FutureReader) return _later(reader, run);
  if (run == null) return reader.stream();
  final works = working[reader];
  return works != null ? works(run) : _counted(reader, run);
}

// async* defers `_source`'s stream until listened: building the stream
// starts nothing, so `Reader >`'s abort path has no side effects.
Stream<List<int>> _piped(_PipedReader reader, Run? run) async* {
  yield* reader._pipe.transform(_open(reader._source, run));
}

Stream<List<int>> _later(_FutureReader reader, Run? run) async* {
  yield* _open(await reader._get(), run);
}

Stream<List<int>> _counted(Reader source, Run run) async* {
  final origin = source.origin();
  var total = origin.size();
  final path = origin.path();
  if (total == null && path != null) {
    try {
      total = await io.File(path).length();
    } on io.FileSystemException {
      // not a file (yet): no total
    }
  }
  yield* run.count(source.stream(), total: total);
}

/// A run's counter as a pass-through pipe, for the resume path: it learns
/// the full length there, and leaves the bytes replayed from disk out of
/// the rate.
final class _Counter with Pipe implements PassThrough {
  _Counter(this._run) {
    sizers[this] = (bytes) => _total = bytes;
    replays[this] = (bytes) => _replay += bytes;
  }

  final Run _run;
  int? _total;
  var _replay = 0;

  @override
  Stream<List<int>> transform(Stream<List<int>> input) {
    final replay = _replay;
    _replay = 0;
    return _run.count(input, total: _total, replay: replay);
  }
}

/// Walk a [_PipedReader] chain and call [Pipe.abort] on each stage, outermost
/// (closest to the writer) first, without creating any stream.
///
/// A [_FutureReader] hides its source behind a future that may not have
/// completed: its outer pipes (a [_PipedReader] wrapping it) are still
/// aborted via the recursion into [_PipedReader._source]; the future's inner
/// reader cannot be reached synchronously and is left to its own error path
/// once it resolves.
void _abortChain(Reader reader, Object error) {
  var cur = reader;
  while (cur is _PipedReader || cur is _WatchedReader) {
    if (cur is _PipedReader) {
      try {
        cur._pipe.abort(error);
      } catch (_) {}
      cur = cur._source;
    } else {
      cur = (cur as _WatchedReader)._source;
    }
  }
}

/// Close the innermost source of a pipe chain if it holds a resource, so a writer
/// that failed before listening does not leak the response or file handle.
Future<void> _closeRoot(Reader reader) async {
  try {
    var cur = reader;
    while (true) {
      if (cur is _PipedReader) {
        cur = cur._source;
      } else if (cur is _WatchedReader) {
        cur = cur._source;
      } else if (cur is _FutureReader) {
        cur = await cur._future;
      } else {
        break;
      }
    }
    if (cur is Closeable) await (cur as Closeable).close();
  } catch (_) {}
}

/// Somewhere bytes end up: a file, a hash, an unpacked folder. Implement
/// [consume]; [origin] mirrors [Reader.origin].
abstract mixin class Writer {
  /// Store [input]; complete when the last byte is stored.
  Future<void> consume(Stream<List<int>> input);

  /// Where the bytes go; empty unless the writer overrides it (a `File`
  /// reports its path, which is how `Client.save` skips and resumes).
  Origin origin() => const Origin();
}

/// Something bytes pass through and change: a hash, gzip, a process.
/// Watching is not a pipe: a [Probe] attaches with `&`.
///
/// A mixin class so `with Pipe` keeps the default [abort]; `implements Pipe`
/// must override it.
abstract mixin class Pipe {
  /// The bytes after this stage; lazy until listened.
  Stream<List<int>> transform(Stream<List<int>> input);

  /// The run failed: poison the stage (a Hasher refuses `hex`), release
  /// what it holds. Called by `Reader >` on every stage without starting
  /// anything; also called by a stage's own `transform`/`consume` error
  /// path when the failure happens mid-stream. The default is a no-op for
  /// stateless pipes (gzip).
  void abort(Object error) {}
}

/// Something that holds a resource until closed: a browser, a page, a response, a bar.
abstract interface class Closeable {
  /// Idempotent.
  Future<void> close();
}

/// `http.get(u).text()`, `http.get(u) & bar | hash > file`. Generic, so it
/// wins over [Watch] for every future of a reader: `& bar` on a response
/// watches its bytes, not the request.
extension ReaderFuture<R extends Reader> on Future<R> {
  Future<List<int>> bytes() async => (await this).bytes();
  Future<String> text() async => (await this).text();
  Stream<String> lines() => Stream.fromFuture(this).asyncExpand((r) => r.lines());
  Future<Origin> origin() async {
    final r = await this;
    try {
      return r.origin();
    } finally {
      if (r is Closeable) await (r as Closeable).close();
    }
  }

  Reader operator |(Pipe? pipe) => _FutureReader(this) | pipe;
  Reader operator &(Probe? probe) => _FutureReader(this) & probe;
  Future<void> operator >(Writer? writer) => _FutureReader(this) > writer;
}

/// `Chrome.launch().close()`; one mirror for every type.
extension CloseableFuture on Future<Closeable> {
  Future<void> close() async => (await this).close();
}

final class _PipedReader with Reader {
  _PipedReader(this._source, this._pipe);

  final Reader _source;
  final Pipe _pipe;

  /// The source's URL, status and name, but no path or size: the piped
  /// bytes are not that file's, so a reader of paths (an ffmpeg input, an
  /// upload) must stream them instead.
  @override
  Origin origin() {
    final o = _source.origin();
    return Origin(url: o.url(), status: o.status(), name: o.name());
  }

  @override
  Stream<List<int>> stream() => _top(this);
}

final class _WatchedReader with Reader {
  _WatchedReader(this._source, this._probe);

  final Reader _source;
  final Probe _probe;

  /// The source's, unchanged: watching changes no byte.
  @override
  Origin origin() => _source.origin();

  @override
  Stream<List<int>> stream() => _top(this);
}

/// A chain read outside `>` (`(file & bar).json()`, an upload body): one
/// run for its probes, ended when the stream ends.
Stream<List<int>> _top(Reader reader) {
  final probes = _probes(reader);
  if (probes.isEmpty) return _open(reader, null);
  final run = Run(probes);
  return run.wrap(_open(reader, run));
}

final class _FutureReader with Reader {
  _FutureReader(this._future);

  final Future<Reader> _future;
  Reader? _resolved;

  Future<Reader> _get() async => _resolved ??= await _future;

  @override
  Stream<List<int>> stream() async* {
    yield* (await _get()).stream();
  }

  /// Empty until the future resolves (first read), then the reader's own.
  @override
  Origin origin() => _resolved?.origin() ?? const Origin();

  @override
  Future<List<int>> bytes() async => (await _get()).bytes();

  @override
  Future<String> text() async => (await _get()).text();

  @override
  Future<void> operator >(Writer? writer) {
    final Object source = _future;
    final path = writer?.origin().path();
    if (path != null && source is Resumable && source.claim()) return source.resume(path, const <Pipe>[]);
    return _get().then((r) => r > writer);
  }
}

/// In-memory bytes behind [Reader.of].
final class _Memory with Reader {
  _Memory(List<int> bytes) : _bytes = (bytes is Uint8List ? bytes : Uint8List.fromList(bytes)).asUnmodifiableView();

  final Uint8List _bytes;

  @override
  Origin origin() => Origin(size: _bytes.length);

  @override
  Stream<List<int>> stream() => Stream<List<int>>.value(_bytes);

  @override
  Future<List<int>> bytes() async => _bytes;

  @override
  Future<String> text() async => utf8.decode(_bytes, allowMalformed: true);
}

/// Base for every failure the toolkit itself reports, so scripts catch one
/// family instead of parsing message strings. A `cause` carries the engine
/// error underneath when there is one (the `dart:convert` error behind a bad
/// document, the action that failed behind a bad tab click).
/// Engine failures that reach the caller unwrapped (a refused connection, a
/// program that won't start) and Dart-idiom guards (`ArgumentError` for a bad
/// argument, `TimeoutException` for a wait that runs out) keep their SDK
/// types; see §5 of docs/VISION.md.
abstract class ToolkitException implements Exception {
  const ToolkitException(this.message, {this.cause});

  /// One line saying what failed and where.
  final String message;

  /// The engine error underneath, or null when the toolkit detected the
  /// failure alone.
  final Object? cause;
}

/// A value the toolkit itself rejects: invalid JSON, a bad selector, a
/// corrupt archive or image, a checksum mismatch. Extends [FormatException],
/// so an existing `on FormatException` keeps catching it; prefer matching the
/// specific type. The offending `source`/`offset` ride along when known.
final class ContentException extends FormatException implements ToolkitException {
  const ContentException([super.message = '', super.source, super.offset, this.cause]);

  @override
  final Object? cause;
}

/// An encrypted archive with no password, or the wrong one: ask again
/// instead of treating the data as damaged. A [ContentException].
final class PasswordException extends ContentException {
  const PasswordException(super.message);
}
