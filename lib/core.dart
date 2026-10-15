/// Core pipeline: bytes flow from a [Reader], through [Pipe]s, into a [Writer].
///
/// ```dart
/// final http = Http.client();
/// await (http.get(url) | hash > Fs.file('a.zip'));
/// await (http.get(url) | hash > null);   // checksum only, nothing stored
/// final text = await http.get(url).text();
/// ```
///
/// Public surface is exactly: [Reader], [Writer], [Pipe], [Closeable], [Origin],
/// [Cookies], [Rate], [Durations], [Times], [Spans], [ToolkitException],
/// [ContentException].
/// - [Reader]: `stream` `bytes` `text` `lines` `pipe` `|` `to` `>` (+ `origin`, `of`).
/// - [Writer]: `consume` (+ `origin`).
/// - [Cookies]: a jar shared by `chrome` and `http`: `parse` `encode` `[]` `header` `set`.
/// - [Rate]: paces the work that shares it (`wait`).
/// - [Durations]: `3.seconds`, `11.minutes`: unit literals for every timeout.
/// - [Times] / [Spans]: `now.format('yyyy-MM-dd')`, `wait.human()` (`11 min 5 s`).
/// - [Pipe]: `transform` `abort`.
/// - [Closeable]: `close`.
/// - [Origin]: typed `url()` / `status()` / `name()` / `path()` for a reader.
/// - [ToolkitException]: the base of every failure the toolkit itself reports.
/// - [ContentException]: a value the toolkit rejects (bad JSON, archive, image…).
/// Everything else is private.
///
/// {@canonicalFor cookies.Cookies}
/// {@canonicalFor rate.Rate}
/// {@canonicalFor time.Spans}
/// {@canonicalFor time.Times}
library;

// Origin's named parameters feed private fields, which initializing formals cannot do.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'src/resume.dart';

export 'src/cookies.dart' show Cookies;
export 'src/rate.dart' show Rate;
export 'src/time.dart' show Spans, Times;

/// What a reader knows about its source: URL, status, file name, path.
///
/// Modules never import each other: `html`/`json` read `reader.origin().url()`
/// for the base URL and `origin().status()` for error-page annotation;
/// `chrome` reads `origin().name()`/`origin().path()` for upload staging.
/// A plain in-memory reader carries an empty [Origin].
final class Origin {
  /// An origin with whatever the source knows; [Origin.new] with no
  /// arguments is the empty one.
  const Origin({String? url, int? status, String? name, String? path})
    : _url = url,
      _status = status,
      _name = name,
      _path = path;

  final String? _url;
  final int? _status;
  final String? _name;
  final String? _path;

  /// Final URL after redirects (http response), if any.
  String? url() => _url;

  /// HTTP status (response), if any.
  int? status() => _status;

  /// Suggested file name (`content-disposition`, URL tail), if any.
  String? name() => _name;

  /// File-system path (fs file, staged upload), if any.
  String? path() => _path;
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
  Future<List<int>> bytes() async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in stream()) {
      out.add(chunk);
    }
    return out.takeBytes();
  }

  /// The text line by line as it arrives (UTF-8, malformed bytes replaced;
  /// `\n`, `\r\n` and `\r` end a line): logs, NDJSON, server-sent events,
  /// a program's progress (`Reader.of(const []) | Shell.filter(cmd)`).
  Stream<String> lines() => stream().transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter());

  /// UTF-8, malformed bytes replaced; types may refine (charset).
  Future<String> text() async => utf8.decode(await bytes(), allowMalformed: true);

  /// Lazy: nothing flows yet; null → this reader, unchanged.
  Reader pipe(Pipe? pipe) => pipe == null ? this : _PipedReader(this, pipe);

  /// `= pipe(pipe)`.
  Reader operator |(Pipe? pipe) => this.pipe(pipe);

  /// Runs the pipeline to the end; null → run and discard.
  ///
  /// On failure every piped stage is notified via [Pipe.abort] **without
  /// starting anything new**: no probe listen-then-cancel, so a [Pipe] that
  /// would start a child process (shell filter) never starts one just to
  /// kill it, an http source is not marked streaming by the failure path,
  /// and broadcast sources poison their stages too.
  Future<void> to(Writer? writer) async {
    // Synchronously, before any await: a resumable GET (http `resume: true`)
    // piped into a path through pass-through pipes delivers itself.
    final path = writer?.origin().path();
    if (path != null) {
      final pipes = <Pipe>[];
      Reader cur = this;
      while (cur is _PipedReader) {
        pipes.insert(0, cur._pipe);
        cur = cur._source;
      }
      final source = cur is _FutureReader ? cur._future : cur;
      if (source is Resumable && pipes.every((p) => p is PassThrough) && source.claim()) {
        try {
          return await source.resume(path, pipes);
        } catch (e) {
          _abortChain(this, e);
          rethrow;
        }
      }
    }
    Stream<List<int>>? s;
    try {
      // [_PipedReader.stream] is lazy (async*): creating [s] starts nothing.
      // A writer that throws before its first listen (missing parent, closed
      // response) therefore leaves the source untouched; [abort] below still
      // poisons/frees the stages.
      s = stream();
      if (writer == null) {
        await for (final _ in s) {
          // discard
        }
        return;
      }
      await writer.consume(s);
      // A writer that returned without reading everything (or anything)
      // must not leave the source open: a response would keep the VM alive.
      // Closing a fully read source is a no-op.
      unawaited(_closeRoot(this));
    } catch (e, st) {
      try {
        _abortChain(this, e);
      } catch (_) {}
      unawaited(_closeRoot(this));
      Error.throwWithStackTrace(e, st);
    }
  }

  /// `= to(writer)`.
  Future<void> operator >(Writer? writer) => to(writer);
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
  while (cur is _PipedReader) {
    try {
      cur._pipe.abort(error);
    } catch (_) {}
    cur = cur._source;
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

/// Unit literals: `3.seconds`, `1.5.seconds`, `250.milliseconds`,
/// `11.minutes`. Fractions round to the microsecond.
extension Durations on num {
  /// This many milliseconds.
  Duration get milliseconds => _us(Duration.microsecondsPerMillisecond);

  /// This many seconds.
  Duration get seconds => _us(Duration.microsecondsPerSecond);

  /// This many minutes.
  Duration get minutes => _us(Duration.microsecondsPerMinute);

  /// This many hours.
  Duration get hours => _us(Duration.microsecondsPerHour);

  /// This many days.
  Duration get days => _us(Duration.microsecondsPerDay);

  Duration _us(int per) => Duration(microseconds: this is int ? (this as int) * per : (this * per).round());
}

/// Something bytes pass through: a hash, a progress bar, gzip, a process.
///
/// A mixin class so `with Pipe` keeps the default [abort]; `implements Pipe`
/// must override it.
abstract mixin class Pipe {
  /// The bytes after this stage; lazy until listened.
  Stream<List<int>> transform(Stream<List<int>> input);

  /// The run failed: poison the stage (a Hasher refuses `hex`), print
  /// ✗ (a Bar), release the live line. Called by [Reader.to] on every
  /// stage without starting anything; also called by a stage's own
  /// `transform`/`consume` error path when the failure happens mid-stream.
  /// The default is a no-op for stateless pipes (gzip).
  void abort(Object error) {}
}

/// Something that holds a resource until closed: a browser, a page, a response, a bar.
abstract interface class Closeable {
  /// Idempotent.
  Future<void> close();
}

/// `http.get(u).text()`, `http.get(u) | hash > file`.
extension ReaderFuture on Future<Reader> {
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

  Reader pipe(Pipe? pipe) => _FutureReader(this).pipe(pipe);
  Reader operator |(Pipe? pipe) => _FutureReader(this) | pipe;
  Future<void> to(Writer? writer) => _FutureReader(this).to(writer);

  Future<void> operator >(Writer? writer) => _FutureReader(this).to(writer);
}

/// `Chrome.launch().close()`; one mirror for every type.
extension CloseableFuture on Future<Closeable> {
  Future<void> close() async => (await this).close();
}

final class _PipedReader with Reader {
  _PipedReader(this._source, this._pipe);

  final Reader _source;
  final Pipe _pipe;

  @override
  Origin origin() => _source.origin();

  @override
  // async* defers `_source.stream()` until listened: building the stream
  // starts nothing, so [Reader.to]'s abort path has no side effects.
  Stream<List<int>> stream() async* {
    yield* _pipe.transform(_source.stream());
  }
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
  Future<void> to(Writer? writer) {
    final Object source = _future;
    final path = writer?.origin().path();
    if (path != null && source is Resumable && source.claim()) return source.resume(path, const <Pipe>[]);
    return _get().then((r) => r.to(writer));
  }
}

/// In-memory bytes behind [Reader.of].
final class _Memory with Reader {
  _Memory(List<int> bytes) : _bytes = (bytes is Uint8List ? bytes : Uint8List.fromList(bytes)).asUnmodifiableView();

  final Uint8List _bytes;

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
