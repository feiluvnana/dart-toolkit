/// Incremental hashes, one-shot or in a pipe. Thin facade over `package:crypto`.
///
/// ```dart
/// final id = Hash.md5().add(url).hexDigest();
/// final h = Hash.sha256().addBytes(header).add(name);
/// final check = Hash.sha256();
/// await (Http.get(isoUrl) | check > Fs.file('disc.iso'));
/// if (check.hexDigest() != expected) await Fs.file('disc.iso').delete();
/// ```
///
/// Public surface is exactly: [Hash], [Hasher].
/// - `Hash.md5/sha1/sha256/sha512()` make a [Hasher].
/// - [Hasher] supports `add` (feed text) `addBytes` (feed bytes) `hexDigest`
///   (finish). As a [Writer] it digests a stream; as a [Pipe] it forwards
///   unchanged and digests, so `reader | hasher > file` stores and checksums
///   in one pass.
/// Everything else is private.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as c;

import 'core.dart';
export 'core.dart';

/// Entry point: one method per algorithm.
abstract final class Hash {
  /// MD5 hasher.
  static Hasher md5() => Hasher._(c.md5);

  /// SHA-1 hasher.
  static Hasher sha1() => Hasher._(c.sha1);

  /// SHA-256 hasher.
  static Hasher sha256() => Hasher._(c.sha256);

  /// SHA-512 hasher.
  static Hasher sha512() => Hasher._(c.sha512);
}

/// The lifecycle of a [Hasher]. Three booleans could encode eight states, of
/// which four are real; one enum makes every transition explicit in the
/// single [_guard] switch below.
enum _State {
  /// Nothing fed yet and no pipeline running.
  idle,

  /// A pipeline is flowing through [Hasher.consume] or [Hasher.transform].
  running,

  /// Finished: [Hasher.hexDigest] closed the sink.
  done,

  /// A run failed partway: later reads throw instead of a partial digest.
  poisoned,
}

/// A hash in progress: a [Writer] you feed, a [Pipe] that passes through.
final class Hasher implements Writer, Pipe {
  Hasher._(this._hash) : _capture = _DigestCapture() {
    _in = _hash.startChunkedConversion(_capture);
  }

  final c.Hash _hash;
  final _DigestCapture _capture;
  late final ByteConversionSink _in;
  var _state = _State.idle;

  /// The one guard: every entry point runs through this switch, so each
  /// state has exactly one meaning everywhere. [action] names the attempted
  /// use for the error; [reread] allows [hexDigest] on a finished hash (it
  /// returns the same digest).
  void _guard(String action, {bool reread = false}) {
    switch (_state) {
      case _State.idle:
        break;
      case _State.done when reread:
        break;
      case _State.running:
        throw StateError('hash is already running; $action must wait');
      case _State.done:
        throw StateError('hash is finished; $action is stale');
      case _State.poisoned:
        throw StateError(
            'hash saw only part of a failed run; $action is stale');
    }
  }

  /// [Pipe.abort]: poison so a later [hexDigest] throws instead of returning
  /// a wrong digest. Covers broadcast sources too (the old listen-cancel
  /// probe skipped them). Wired via [Reader.writeTo]'s abort walk, which
  /// calls [abort] without starting the pipeline, and via [_tee]'s finally /
  /// [consume]'s catch mid-run.
  @override
  void abort(Object error) {
    _state = _State.poisoned;
  }

  /// Feed more text (UTF-8). Returns this. An [add] after [hexDigest], while
  /// a pipeline is running, or after a failed run is a [StateError].
  Hasher add(String data) {
    _guard('add');
    _in.add(utf8.encode(data));
    return this;
  }

  /// Feed more bytes. Returns this. Same staleness rules as [add].
  Hasher addBytes(List<int> data) {
    _guard('add');
    _in.add(data);
    return this;
  }

  /// Finish the hash. Calling it again returns the same digest. After a
  /// failed run through this hasher it throws instead of a partial digest,
  /// and an [add]/[addBytes] after it is a [StateError].
  String hexDigest() {
    _guard('hexDigest', reread: true);
    if (_state == _State.done) return _capture.digest.toString();
    _in.close();
    _state = _State.done;
    return _capture.digest.toString();
  }

  @override
  Future<void> consume(Stream<List<int>> input) async {
    _guard('consume');
    _state = _State.running;
    try {
      await for (final chunk in input) {
        _in.add(chunk);
      }
    } catch (e) {
      // The run failed: the digest is partial, so poison it rather than
      // let a later hexDigest() silently return it.
      abort(e);
      rethrow;
    } finally {
      if (_state == _State.running) _state = _State.idle;
    }
    _in.close();
    _state = _State.done;
  }

  @override
  Stream<List<int>> transform(Stream<List<int>> input) {
    _guard('transform');
    _state = _State.running;
    return _tee(input);
  }

  Stream<List<int>> _tee(Stream<List<int>> input) async* {
    var ok = false;
    try {
      await for (final chunk in input) {
        _in.add(chunk);
        yield chunk;
      }
      // The pipe ran to the end: finish here so hexDigest() is stable and a
      // second pipeline is a StateError, as specced.
      _in.close();
      _state = _State.done;
      ok = true;
    } finally {
      if (_state == _State.running) _state = _State.idle;
      // Input failure or downstream cancel (including Reader.writeTo's
      // abort on a writer-first failure): the digest is partial, so a later
      // hexDigest()/add() must throw rather than silently use it (or return
      // the empty-input digest when nothing was read).
      if (!ok) abort(StateError('pipe did not run to the end'));
    }
  }
}

final class _DigestCapture implements Sink<c.Digest> {
  late c.Digest digest;

  @override
  void add(c.Digest data) {
    digest = data;
  }

  @override
  void close() {}
}
