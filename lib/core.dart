/// Core pipeline: bytes flow from a [Reader], through [Pipe]s, into a [Writer].
///
/// ```dart
/// await (Http.get(url) | hash > Fs.file('a.zip'));
/// await (Http.get(url) | hash > null);   // checksum only, nothing stored
/// final text = await Http.get(url).text();
/// ```
///
/// Public surface is exactly: [Reader], [Writer], [Pipe], [Closeable].
/// - [Reader]: `stream` `bytes` `text` `pipe` `|` `to` `>`.
/// - [Writer]: `consume`.
/// - [Pipe]: `transform`.
/// - [Closeable]: `close`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// Bytes you can read. Implement [stream]; everything else comes with it.
abstract mixin class Reader {
  /// Single-subscription chunks; the one member to implement.
  Stream<List<int>> stream();

  /// Read everything into memory.
  Future<List<int>> bytes() async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in stream()) {
      out.add(chunk);
    }
    return out.takeBytes();
  }

  /// UTF-8, malformed bytes replaced; types may refine (charset).
  Future<String> text() async =>
      utf8.decode(await bytes(), allowMalformed: true);

  /// Lazy: nothing flows yet; null → this reader, unchanged.
  Reader pipe(Pipe? pipe) =>
      pipe == null ? this : _PipedReader(this, pipe);

  /// `= pipe(pipe)`.
  Reader operator |(Pipe? pipe) => this.pipe(pipe);

  /// Runs the pipeline to the end; null → run and discard.
  Future<void> to(Writer? writer) async {
    Stream<List<int>>? s;
    try {
      s = stream();
      if (writer == null) {
        await for (final _ in s) {
          // discard
        }
        return;
      }
      await writer.consume(s);
    } catch (e, st) {
      // The writer failed before or during the read (e.g. a missing parent,
      // or a throw-before-read test writer). The piped stream may never have
      // been listened to, which would leave the source (file, http) hanging
      // and intermediate pipes (Hasher, Bar) unpoisoned. Listening then
      // cancelling runs any pipe generators so their cancel paths poison or
      // release, and releases the source. When the writer already listened,
      // this second listen throws StateError and is ignored: the writer's
      // own cancel already propagated. Broadcast streams allow a second
      // listen, which would run the pipeline twice: skip the probe there.
      try {
        final stream = s;
        if (stream != null && !stream.isBroadcast) {
          await stream.listen(null, onError: (_) {}).cancel();
        }
      } catch (_) {}
      Error.throwWithStackTrace(e, st);
    }
  }

  /// `= to(writer)`.
  Future<void> operator >(Writer? writer) => to(writer);
}

/// Somewhere bytes end up: a file, a hash, an unpacked folder.
abstract interface class Writer {
  Future<void> consume(Stream<List<int>> input);
}

/// Something bytes pass through: a hash, a progress bar, gzip, a process.
abstract interface class Pipe {
  Stream<List<int>> transform(Stream<List<int>> input);
}

/// Something that holds a resource until closed: a browser, a page, a response, a bar.
abstract interface class Closeable {
  /// Idempotent.
  Future<void> close();
}

/// `Http.get(u).text()`, `Http.get(u) | hash > file`.
extension ReaderFuture on Future<Reader> {
  Future<List<int>> bytes() async => (await this).bytes();
  Future<String> text() async => (await this).text();
  Reader pipe(Pipe? pipe) => _FutureReader(this).pipe(pipe);
  Reader operator |(Pipe? pipe) => _FutureReader(this) | pipe;
  Future<void> to(Writer? writer) async => (await this).to(writer);
  Future<void> operator >(Writer? writer) async => (await this).to(writer);
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
  Stream<List<int>> stream() => _pipe.transform(_source.stream());
}

final class _FutureReader with Reader {
  _FutureReader(this._future);

  final Future<Reader> _future;

  @override
  Stream<List<int>> stream() async* {
    yield* (await _future).stream();
  }

  @override
  Future<List<int>> bytes() async => (await _future).bytes();

  @override
  Future<void> to(Writer? writer) => _future.then((r) => r.to(writer));
}
