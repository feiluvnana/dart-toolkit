/// Incremental hashes, one-shot or in a pipe. Thin facade over `package:crypto`.
///
/// ```dart
/// final id = Hash.md5().add(url).hex();
/// final h = Hash.sha256().addBytes(header).add(name);
/// await (http.get(isoUrl) | Hash.sha256(expect: sum) > Fs.file('disc.iso')); // a mismatch never lands
/// final h = Hash.sha256(); await (Fs.file('disc.iso') > h); print(h.hex());   // a file's digest
/// final sig = Hash.sha256(key: utf8.encode(secret)).add(body).hex();   // HMAC
/// ```
///
/// Public surface is exactly: [Hash], [Hasher].
/// - `Hash.md5/sha1/sha256/sha512()` make a [Hasher]; on md5 and sha256
///   `key:` makes it an HMAC and `expect:` checks the digest.
/// - [Hasher] supports `add` (feed text) `addBytes` (feed bytes) `hex`
///   `bytes` (finish, as text or raw); `expect:` checks the result. As a [Writer] it digests a stream; as a [Pipe] it forwards
///   unchanged and digests, so `reader | hasher > file` stores and checksums
///   in one pass.
/// Everything else is private.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as c;

import 'core.dart';
import 'src/resume.dart' show PassThrough;
export 'core.dart';

/// Entry point: one method per algorithm. With [expect] (hex) the hasher
/// checks itself at the end of a run: a mismatch fails the pipeline with a
/// [ContentException] before the writer commits, so
/// `http.get(u) | Hash.sha256(expect: sum) > Archive.unarchive('opt')`
/// never unpacks a bad download. It is checked when a run ends (`>`, `|`,
/// `of`); `hex()` alone does not check.
///
/// With [key] the hasher is an HMAC (RFC 2104) over that secret:
/// `Hash.sha256(key: utf8.encode(secret)).add(payload).hex()` checks a
/// webhook signature, and a digest's [Hasher.bytes] keys the next step of a
/// signing chain.
abstract final class Hash {
  /// MD5 hasher.
  static Hasher md5({String? expect, List<int>? key}) => Hasher._(c.md5, 'md5', expect, key);

  /// SHA-1 hasher.
  static Hasher sha1() => Hasher._(c.sha1, 'sha1', null, null);

  /// SHA-256 hasher.
  static Hasher sha256({String? expect, List<int>? key}) => Hasher._(c.sha256, 'sha256', expect, key);

  /// SHA-512 hasher.
  static Hasher sha512() => Hasher._(c.sha512, 'sha512', null, null);
}

/// The lifecycle of a [Hasher]. Three booleans could encode eight states, of
/// which four are real; one enum makes every transition explicit in the
/// single [_guard] switch below.
enum _State {
  /// Nothing fed yet and no pipeline running.
  idle,

  /// A pipeline is flowing through [Hasher.consume] or [Hasher.transform].
  running,

  /// Finished: [Hasher.hex] closed the sink.
  done,

  /// A run failed partway: later reads throw instead of a partial digest.
  poisoned,
}

/// A hash in progress: a [Writer] you feed, a [Pipe] that passes through.
final class Hasher with Writer implements Pipe, PassThrough {
  Hasher._(c.Hash hash, String name, String? expect, List<int>? key)
    : _name = key == null ? name : 'hmac-$name',
      _expect = expect?.trim().toLowerCase(),
      _capture = _DigestCapture() {
    _in = key == null ? hash.startChunkedConversion(_capture) : c.Hmac(hash, key).startChunkedConversion(_capture);
  }

  final String _name;
  final String? _expect;
  final _DigestCapture _capture;
  late final ByteConversionSink _in;
  var _state = _State.idle;

  /// The one guard: every entry point runs through this switch, so each
  /// state has exactly one meaning everywhere. [action] names the attempted
  /// use for the error; [reread] allows [hex] on a finished hash (it
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
        throw StateError('hash saw only part of a failed run; $action is stale');
    }
  }

  /// [Pipe.abort]: poison so a later [hex] throws instead of returning
  /// a wrong digest. Covers broadcast sources too. Wired via `Reader >`'s abort walk, which
  /// calls [abort] without starting the pipeline, and via [_tee]'s finally /
  /// [consume]'s catch mid-run.
  @override
  void abort(Object error) {
    _state = _State.poisoned;
  }

  /// Feed more text (UTF-8). Returns this. An [add] after [hex], while
  /// a pipeline is running, or after a failed run is a [StateError].
  Hasher add(String text) {
    _guard('add');
    _in.add(utf8.encode(text));
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
  String hex() => _finish('hex').toString();

  /// The raw digest bytes. Finishes like [hex].
  List<int> bytes() => List.of(_finish('bytes').bytes);

  c.Digest _finish(String action) {
    _guard(action, reread: true);
    if (_state != _State.done) {
      _in.close();
      _state = _State.done;
    }
    return _capture.digest;
  }

  /// With `expect:`, a finished digest that differs is a FormatException.
  void _check() {
    final want = _expect;
    if (want == null) return;
    final got = _capture.digest.toString();
    if (got != want) throw ContentException('$_name mismatch: got $got, expected $want');
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
      // let a later hex() silently return it.
      abort(e);
      rethrow;
    } finally {
      if (_state == _State.running) _state = _State.idle;
    }
    _in.close();
    _state = _State.done;
    _check();
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
      // The pipe ran to the end: finish here so hex() is stable and a
      // second pipeline is a StateError, as specced.
      _in.close();
      _state = _State.done;
      ok = true;
      _check(); // fails the run at its end, before the writer commits
    } finally {
      if (_state == _State.running) _state = _State.idle;
      // Input failure or downstream cancel (including `Reader >`'s
      // abort on a writer-first failure): the digest is partial, so a later
      // hex()/add() must throw rather than silently use it (or return
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
