/// Incremental hashes, one-shot or in a pipe. Thin facade over `package:crypto`.
///
/// ```dart
/// final id = Hash.md5().add(url).hex();
/// final check = Hash.sha256();
/// await (Http.get(isoUrl) | check > Fs.file('disc.iso'));
/// if (check.hex() != expected) await Fs.file('disc.iso').delete();
/// ```
///
/// Public surface is exactly: [Hash], [Hasher].
/// - `Hash.md5/sha1/sha256/sha512()` make a [Hasher].
/// - [Hasher] supports `add` (feed data) `hex` (finish).
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

/// A hash in progress: a [Writer] you feed, a [Pipe] that passes through.
final class Hasher implements Writer, Pipe {
  Hasher._(this._hash) : _capture = _DigestCapture() {
    _in = _hash.startChunkedConversion(_capture);
  }

  final c.Hash _hash;
  final _DigestCapture _capture;
  late final ByteConversionSink _in;
  var _done = false;
  var _poisoned = false;
  var _running = false;

  void _checkUsable(String action) {
    if (_poisoned) {
      throw StateError('hash saw only part of a failed run; $action is stale');
    }
    if (_done) {
      throw StateError('hash is finished; hex() was already called');
    }
    if (_running) {
      throw StateError('hash is already running; concurrent use is stale');
    }
  }

  /// Poison the hasher: a later [hex]/[add] throws instead of returning a
  /// partial or empty-input digest. Called when the run failed anywhere,
  /// including a writer that failed before this stage was read (wired via
  /// [Reader.to]'s cancel-on-writer-error, which tears down the pipe stream
  /// and lands in [_tee]'s finally / [consume]'s catch).
  void _abort(Object e) {
    _poisoned = true;
  }

  /// Feed more data: a `String` (UTF-8) or a `List<int>`. Returns this.
  /// Anything else is an [ArgumentError]. An [add] after [hex], or after a
  /// failed run through this hasher, is a [StateError].
  Hasher add(Object data) {
    _checkUsable('add');
    _in.add(_toBytes(data));
    return this;
  }

  /// Finish the hash. Calling it again returns the same digest. After a
  /// failed run through this hasher it throws instead of a partial digest.
  String hex() {
    if (_poisoned) {
      throw StateError('hash saw only part of a failed run; hex is stale');
    }
    if (_running) {
      throw StateError(
          'hash is in flight; wait for the stream to finish before calling hex()');
    }
    if (!_done) {
      _in.close();
      _done = true;
    }
    return _capture.digest.toString();
  }

  @override
  Future<void> consume(Stream<List<int>> input) async {
    if (_poisoned) {
      throw StateError('hash saw only part of a failed run; reuse is stale');
    }
    if (_done) {
      throw StateError('hash is finished; cannot take another pipeline');
    }
    if (_running) {
      throw StateError('hash is already running; concurrent use is stale');
    }
    _running = true;
    try {
      await for (final chunk in input) {
        _in.add(chunk);
      }
    } catch (e) {
      // The run failed: the digest is partial, so poison it rather than
      // let a later hex() silently return it.
      _abort(e);
      rethrow;
    } finally {
      _running = false;
    }
    _in.close();
    _done = true;
  }

  @override
  Stream<List<int>> transform(Stream<List<int>> input) {
    if (_poisoned) {
      throw StateError('hash saw only part of a failed run; reuse is stale');
    }
    if (_done) {
      throw StateError('hash is finished; cannot take another pipeline');
    }
    if (_running) {
      throw StateError('hash is already running; concurrent use is stale');
    }
    _running = true;
    return _tee(input);
  }

  Stream<List<int>> _tee(Stream<List<int>> input) async* {
    var ok = false;
    try {
      await for (final chunk in input) {
        _in.add(chunk);
        yield chunk;
      }
      // The pipe ran to the end: finish here so hex() is stable and a second
      // pipeline is a StateError, as specced.
      _in.close();
      _done = true;
      ok = true;
    } finally {
      _running = false;
      // Input failure or downstream cancel (including Reader.to's
      // cancel-on-writer-error for a writer-first failure): the digest is
      // partial, so a later hex()/add() must throw rather than silently
      // use it (or return the empty-input digest when nothing was read).
      if (!ok) _abort(StateError('pipe did not run to the end'));
    }
  }

  static List<int> _toBytes(Object data) {
    if (data is String) return utf8.encode(data);
    if (data is List<int>) return data;
    throw ArgumentError.value(
      data,
      'data',
      'must be a String or List<int>',
    );
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
