// ignore_for_file: avoid_annotating_with_dynamic
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import '../core/native.dart' as l2native;
import '../core/traits.dart';
import '../fs/io.dart' as fs;

/// A streaming message digest: [update] bytes, then [digest] once.
abstract interface class Hasher {
  void update(Object data);
  Uint8List digest();
}

List<int> _bytes(Object data) {
  if (data is Uint8List) return data;
  if (data is List<int>) return data;
  if (data is String) return utf8.encode(data);
  throw ArgumentError.value(data, 'data', 'Must be String, List<int> or Uint8List');
}

/// Whether [a] and [b] hold the same bytes, in time that depends only on their
/// lengths: no early exit, so digests and MACs are safe to check with it.
bool _ctEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= (a[i] & 0xFF) ^ (b[i] & 0xFF);
  }
  return diff == 0;
}

// ---------------------------------------------------------------------------
// Algo / Mac / Writer
// ---------------------------------------------------------------------------

/// A named hash function: call it, or use [mac] and [writer].
///
/// Every digest runs through the native `tk_digest_*` engine. Without the
/// library the call is an [UnsupportedError] (r50: no Dart fallback).
final class Algo {
  final String name;
  final int size;
  final int blockSize;

  /// The native `tk_digest_*` algorithm code (digest.rs): 0 md5, 3 sha256,
  /// 5 sha512, 14 blake3, 16 crc32, 18 xxh64, 19 xxh3.
  final int code;

  const Algo._(this.name, this.size, this.blockSize, this.code);

  /// Digest length in bytes.
  int get length => size;

  /// Hashes [data] (`String`, `List<int>` or `Uint8List`); [key] selects the
  /// keyed/HMAC variant where supported. Anything else is an [ArgumentError].
  ///
  /// Files hash with [file] instead: `call` never touches the disk, so
  /// passing a file path or [fs.File] throws telling you to
  /// `await Hash.sha256.file(path)`.
  Uint8List call(Object data, {Object? key}) {
    if (data is fs.File || data is fs.Path || data is io.File || data is io.FileSystemEntity) {
      throw ArgumentError.value(data, 'data', 'Hashing a file is async: await $name.file(path)');
    }
    final bytes = _bytes(data);
    final k = key == null ? null : _bytes(key);
    return _nativeBytes(this, k, bytes);
  }

  /// Hashes the file at [path] (`String`, [fs.Path], [fs.File] or [io.File]),
  /// reading it inside the native library in constant Dart memory, or its MAC
  /// under [key]. A missing file is a [io.PathNotFoundException] naming it.
  ///
  /// ```dart
  /// final digest = await Hash.sha256.file('ubuntu.iso');
  /// ```
  Future<Uint8List> file(Object path, {Object? key}) async {
    final p = path is fs.File
        ? path.str
        : path is fs.Path
        ? path.str
        : path is io.File
        ? path.path
        : path.toString();
    final k = key == null ? null : _bytes(key);
    return _nativeFile(this, k, p);
  }

  /// A reusable keyed MAC: `Hash.sha256.mac(secret)(message)`.
  Mac mac(Object key) => Mac(this, _bytes(key));

  /// A streaming writer, itself a [Writer] so it sinks a pipe:
  /// `await File('x').pipe(Hash.sha256.writer())`.
  ///
  /// Chunks feed a native `tk_digest_*` handle (opened by [writer]); without
  /// the library opening it is an [UnsupportedError].
  ///
  /// ```dart
  /// final w = Hash.sha256.writer();
  /// await w.write('hello ');
  /// await w.write('world');
  /// print(w.finish().hex); // == Hash.sha256('hello world').hex
  /// ```
  AlgoWriter writer() => AlgoWriter._open(this);

  @override
  String toString() => name;
}

/// A keyed message authentication code.
///
/// Computed through the native `tk_hmac`/`tk_mac_new` engine; without the
/// library the call is an [UnsupportedError] (r50: no Dart fallback).
final class Mac {
  final Algo algo;
  final List<int> key;

  const Mac(this.algo, this.key);

  /// Authenticates [data].
  Uint8List call(Object data) {
    final bytes = _bytes(data);
    return _nativeBytes(algo, key, bytes);
  }

  /// Authenticates [data] (alias for [call]).
  Uint8List of(Object data) => call(data);
}

/// A streaming hash writer, itself a [Writer] so it sinks a pipe; call
/// [digest] (or [finish], or read [sum]) once.
///
/// Backed by a native `tk_digest_*` handle; without the library opening one
/// is an [UnsupportedError] (r50: no Dart fallback).
final class AlgoWriter implements Hasher, Writer {
  final ffi.Pointer<ffi.Void> _handle;
  final Algo _algo;
  bool _done = false;

  AlgoWriter._(this._algo, this._handle);

  /// Opens a writer for [algo] on a native `tk_digest_*` handle.
  factory AlgoWriter._open(Algo algo) {
    final h = _HashNative.digestNew(algo.code);
    if (h == ffi.nullptr) {
      throw l2native.NativeException('hash with ${algo.name}', l2native.Lib2Native.lastError());
    }
    return AlgoWriter._(algo, h);
  }

  void _check() {
    if (_done) throw StateError('Digest already finished');
  }

  @override
  void update(Object data) {
    _check();
    final bytes = _bytes(data);
    l2native.Lib2Native.withBytes(bytes, (p, n) {
      if (_HashNative.digestUpdate(_handle, p, n) < 0) {
        final why = l2native.Lib2Native.lastError();
        // Release the handle (final frees it even when the output is refused).
        try {
          l2native.Lib2Native.withOut('hash with ${_algo.name}', _algo.size, (out) {
            return _HashNative.digestFinal(_handle, out, _algo.size);
          });
        } catch (_) {
          // The update's error below is what the caller hears; this only frees.
        }
        _done = true;
        throw l2native.NativeException('hash with ${_algo.name}', why);
      }
    });
  }

  /// Adds [data] (`String` UTF-8, bytes verbatim) and answers the bytes
  /// accepted, so a file pipes straight into the digest.
  @override
  Future<int> write(Object data) async {
    update(data);
    return _bytes(data).length;
  }

  @override
  Future<void> flush() async {}

  /// Finishes the digest; only valid once.
  @override
  Uint8List digest() {
    _check();
    _done = true;
    return l2native.Lib2Native.withOut('hash with ${_algo.name}', _algo.size, (out) {
      final n = _HashNative.digestFinal(_handle, out, _algo.size);
      if (n < 0) throw l2native.NativeException('hash with ${_algo.name}', l2native.Lib2Native.lastError());
      return n;
    });
  }

  /// Alias for [digest].
  Uint8List finish() => digest();

  /// Alias for [digest], for `hasher.sum.hex` after a pipe.
  Uint8List get sum => digest();
}

/// The catalog of hash algorithms: `Hash.sha256('hello').hex`.
abstract final class Hash {
  /// 128-bit MD5 (legacy only — not collision resistant).
  static const Algo md5 = Algo._('md5', 16, 64, 0);

  /// 256-bit SHA-2, the default for integrity checks.
  static const Algo sha256 = Algo._('sha256', 32, 64, 3);

  /// 512-bit SHA-2.
  static const Algo sha512 = Algo._('sha512', 64, 128, 5);

  /// 256-bit BLAKE3, fast and keyed-mode capable.
  static const Algo blake3 = Algo._('blake3', 32, 64, 14);

  /// 32-bit CRC, for checksums and archive formats.
  static const Algo crc32 = Algo._('crc32', 4, 4, 16);

  /// 64-bit XXH64, for fast non-crypto fingerprints.
  static const Algo xxh64 = Algo._('xxh64', 8, 8, 18);

  /// 64-bit XXH3, for fast dedup keys and fingerprints.
  static const Algo xxh3 = Algo._('xxh3', 8, 8, 19);

  /// Every algorithm.
  static List<Algo> get values => [md5, sha256, sha512, blake3, crc32, xxh64, xxh3];
}

/// The native `tk_digest_*` calls behind [Algo] (Phase C wiring).
///
/// Looked up once per isolate from [l2native.Lib2Native]; a missing library
/// throws [UnsupportedError] out of `require()` before reaching these.
abstract final class _HashNative {
  static ffi.DynamicLibrary get _lib => l2native.Lib2Native.require();

  static final digestNew = _lib
      .lookupFunction<ffi.Pointer<ffi.Void> Function(ffi.Uint32), ffi.Pointer<ffi.Void> Function(int)>('tk_digest_new');

  static final macNew = _lib
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Uint32, ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        ffi.Pointer<ffi.Void> Function(int, ffi.Pointer<ffi.Uint8>, int)
      >('tk_mac_new');

  static final digestUpdate = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int)
      >('tk_digest_update');

  static final digestFinal = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int)
      >('tk_digest_final');

  static final digest = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Uint32, ffi.Pointer<ffi.Uint8>, ffi.IntPtr, ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        int Function(int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int)
      >('tk_digest');

  static final hmac = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Uint32,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
        ),
        int Function(int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int)
      >('tk_hmac');

  static final digestFile = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
        ),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>)
      >('tk_digest_file');
}

/// How much of a large in-hand input is handed to the library at a time, so
/// it is never copied whole.
const _nativeChunk = 1 << 20;

/// The longest digest (SHA-512): the size of every output buffer.
const _nativeMaxDigest = 64;

/// Opens a native digest/MAC handle for [algo] under [key]; throws the
/// library's error mapped to [ArgumentError] for a bad key, else
/// [l2native.NativeException].
ffi.Pointer<ffi.Void> _nativeOpen(Algo algo, List<int>? key) {
  final h = key == null
      ? _HashNative.digestNew(algo.code)
      : l2native.Lib2Native.withBytes(key, (k, n) => _HashNative.macNew(algo.code, k, n));
  if (h == ffi.nullptr) {
    final why = l2native.Lib2Native.lastError();
    if (key != null) throw ArgumentError.value('•••', 'key', '${algo.name}: $why');
    throw l2native.NativeException('hash with ${algo.name}', why);
  }
  return h;
}

/// Finishes native handle [h] into its digest; the handle is released.
Uint8List _nativeFinish(Algo algo, ffi.Pointer<ffi.Void> h) => l2native.Lib2Native.withOut(
  'hash with ${algo.name}',
  _nativeMaxDigest,
  (out) => _HashNative.digestFinal(h, out, _nativeMaxDigest),
);

/// The digest/MAC of [data] through the native library.
Uint8List _nativeBytes(Algo algo, List<int>? key, List<int> data) {
  if (data.length <= _nativeChunk) {
    final klen = key?.length ?? 0;
    final size = klen + data.length + _nativeMaxDigest;
    final buf = l2native.Lib2Native.alloc(size);
    try {
      final view = buf.asTypedList(size);
      if (key != null) view.setAll(0, key);
      view.setAll(klen, data);
      final kp = buf;
      final dp = ffi.Pointer<ffi.Uint8>.fromAddress(buf.address + klen);
      final op = ffi.Pointer<ffi.Uint8>.fromAddress(buf.address + klen + data.length);
      final n = key == null
          ? _HashNative.digest(algo.code, dp, data.length, op, _nativeMaxDigest)
          : _HashNative.hmac(algo.code, kp, klen, dp, data.length, op, _nativeMaxDigest);
      if (n < 0) {
        final why = l2native.Lib2Native.lastError();
        if (key != null) throw ArgumentError.value('•••', 'key', '${algo.name}: $why');
        throw l2native.NativeException('hash with ${algo.name}', why);
      }
      return Uint8List.fromList(view.sublist(klen + data.length, klen + data.length + n));
    } finally {
      l2native.Lib2Native.free(buf, size);
    }
  }
  final h = _nativeOpen(algo, key);
  final buf = l2native.Lib2Native.alloc(_nativeChunk);
  try {
    final view = buf.asTypedList(_nativeChunk);
    for (var at = 0; at < data.length; at += _nativeChunk) {
      final n = data.length - at < _nativeChunk ? data.length - at : _nativeChunk;
      view.setRange(0, n, data, at);
      if (_HashNative.digestUpdate(h, buf, n) < 0) {
        final why = l2native.Lib2Native.lastError();
        _nativeFinish(algo, h);
        if (key != null) throw ArgumentError.value('•••', 'key', '${algo.name}: $why');
        throw l2native.NativeException('hash with ${algo.name}', why);
      }
    }
  } finally {
    l2native.Lib2Native.free(buf, _nativeChunk);
  }
  return _nativeFinish(algo, h);
}

/// The digest/MAC of the file at [path], read inside the native library.
Uint8List _nativeFile(Algo algo, List<int>? key, String path) {
  final h = _nativeOpen(algo, key);
  final failure =
      l2native.Lib2Native.withText(path, (p, n) => _HashNative.digestFile(h, p, n, ffi.nullptr, ffi.nullptr)) < 0
      ? l2native.Lib2Native.lastError()
      : null;
  final digest = _nativeFinish(algo, h);
  if (failure == null) return digest;
  throw _nativeFileError(failure, path);
}

/// What the library said about the file at [path], as the exception it
/// means: a missing file (os error 2/3) is a [io.PathNotFoundException], any
/// other system error a [io.FileSystemException].
Exception _nativeFileError(String message, String path) {
  final m = RegExp(r'\(os error (\d+)\)').firstMatch(message);
  if (m == null) return io.FileSystemException('Cannot hash: $message', path);
  final code = int.parse(m[1]!);
  final said = message.substring(0, m.start).trim();
  final at = said.lastIndexOf(': ');
  final error = io.OSError(at < 0 ? said : said.substring(at + 2), code);
  if (code == 2 || code == 3) return io.PathNotFoundException(path, error, 'Cannot hash');
  return io.FileSystemException('Cannot hash', path, error);
}

/// Digest bytes rendered as hex or an integer, and checked in constant time.
extension DigestValue on List<int> {
  /// Lowercase hex string.
  String get hex {
    final sb = StringBuffer();
    for (final b in this) {
      sb.write((b & 0xFF).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Big-endian integer value of the digest.
  int get intVal {
    var v = 0;
    for (final b in this) {
      v = (v << 8) | (b & 0xFF);
    }
    return v;
  }

  /// A [Uint8List] copy of the digest.
  Uint8List get rawBytes => this is Uint8List ? this as Uint8List : Uint8List.fromList(this);

  /// Whether this digest is the one [hex] spells, in either case, in time
  /// that depends only on the lengths. Text that is not hex is a
  /// [FormatException].
  bool matches(String hex) => _ctEq(this, Hex.decode(hex));

  /// Whether this digest holds the same bytes as [other], in time that
  /// depends only on the lengths.
  bool constantEquals(List<int> other) => _ctEq(this, other);
}

/// Lowercase hex text for bytes.
abstract final class Hex {
  /// Encodes [bytes] as lowercase hex.
  static String encode(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write((b & 0xFF).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Decodes [hex] (either case, even length); anything else is a
  /// [FormatException] naming the text.
  static Uint8List decode(String hex) {
    if (hex.length.isOdd || !_hexBody.hasMatch(hex)) {
      throw FormatException('Invalid hex: $hex', hex);
    }
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

final _hexBody = RegExp(r'^[0-9a-fA-F]*$');

/// RFC 4648 base64 text for bytes.
abstract final class Base64 {
  /// Encodes [data] (`String` UTF-8, bytes verbatim) as padded base64.
  static String encode(Object data) => base64Encode(_bytes(data));

  /// Decodes padded (or unpadded, per `dart:convert`) base64 [text].
  static Uint8List decode(String text) => base64Decode(Base64.normalize(text));

  /// Normalizes [text] for decoding: whitespace stripped, padding restored.
  static String normalize(String text) {
    final compact = text.replaceAll(RegExp(r'\s'), '');
    final pad = (4 - compact.length % 4) % 4;
    return '$compact${'=' * pad}';
  }
}
