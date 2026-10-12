import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/jobs.dart';
import '../core/native.dart' as l2native;
import '../core/traits.dart';
import '../fs/io.dart' as fs;

export '../core/errors.dart';
export '../core/pipe.dart';
export '../core/traits.dart';

List<int> _bytes(Object data) {
  if (data is Uint8List) return data;
  if (data is List<int>) return data;
  if (data is String) return utf8.encode(data);
  throw ArgumentError.value(data, 'data', 'Must be String, List<int> or Uint8List');
}

/// A named hash function: call it with data, or hash a [Source] with [SourceHash.hash].
///
/// Every digest runs through the native `tk_digest_*` engine. Without the
/// library the call is an [UnsupportedError] (rule 42: no Dart fallback).
final class Algo {
  final String name;
  final int size;

  /// The native digest block size, kept beside the code it belongs to.
  // ignore: unused_field
  final int _blockSize;

  /// The native `tk_digest_*` algorithm code (digest.rs): 0 md5, 3 sha256,
  /// 5 sha512, 14 blake3, 16 crc32, 18 xxh64, 19 xxh3.
  final int _code;

  const Algo._(this.name, this.size, this._blockSize, this._code);

  /// Hashes [data] (`String`, `List<int>` or `Uint8List`); [key] selects the
  /// keyed/HMAC variant where supported. Anything else is an [ArgumentError].
  ///
  /// Files hash with [SourceHash.hash] instead: `call` never touches the
  /// disk, so passing a file throws telling you to
  /// `await File('ubuntu.iso').hash(Hash.sha256)`.
  Uint8List call(Object data, {Object? key}) {
    if (data is fs.File || data is io.File || data is io.FileSystemEntity) {
      throw ArgumentError.value(data, 'data', 'Hashing a file is async: await File(p).hash($name)');
    }
    final bytes = _bytes(data);
    final k = key == null ? null : _bytes(key);
    return _nativeBytes(this, k, bytes);
  }

  @override
  String toString() => name;
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
}

/// The native `tk_digest_*` calls behind [Algo].
///
/// Looked up once per isolate from the engine seam; a missing library
/// throws [UnsupportedError] out of `require()` before reaching these.
abstract final class _HashNative {
  static ffi.DynamicLibrary get _lib => l2native.require();

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
          ffi.Uint32,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_digest_file_async');
}

/// How much of a large in-hand input is handed to the library at a time, so
/// it is never copied whole.
const _nativeChunk = 1 << 20;

/// The longest digest (SHA-512): the size of every output buffer.
const _nativeMaxDigest = 64;

/// One streamed read through the native handle.
const _streamChunk = 64 * 1024;

/// Opens a native digest/MAC handle for [algo] under [key]; throws the
/// library's error mapped to [ArgumentError] for a bad key, else
/// [l2native.NativeException].
ffi.Pointer<ffi.Void> _nativeOpen(Algo algo, List<int>? key) {
  final h = key == null
      ? _HashNative.digestNew(algo._code)
      : l2native.withBytes(key, (k, n) => _HashNative.macNew(algo._code, k, n));
  if (h == ffi.nullptr) {
    final why = l2native.lastError();
    if (key != null) throw ArgumentError.value('•••', 'key', '${algo.name}: $why');
    throw l2native.NativeException('hash with ${algo.name}', why);
  }
  return h;
}

/// Finishes native handle [h] into its digest; the handle is released.
Uint8List _nativeFinish(Algo algo, ffi.Pointer<ffi.Void> h) => l2native.withOut(
  'hash with ${algo.name}',
  _nativeMaxDigest,
  (out) => _HashNative.digestFinal(h, out, _nativeMaxDigest),
);

/// The digest/MAC of [data] through the native library.
Uint8List _nativeBytes(Algo algo, List<int>? key, List<int> data) {
  if (data.length <= _nativeChunk) {
    final klen = key?.length ?? 0;
    final size = klen + data.length + _nativeMaxDigest;
    final buf = l2native.alloc(size);
    try {
      final view = buf.asTypedList(size);
      if (key != null) view.setAll(0, key);
      view.setAll(klen, data);
      final kp = buf;
      final dp = ffi.Pointer<ffi.Uint8>.fromAddress(buf.address + klen);
      final op = ffi.Pointer<ffi.Uint8>.fromAddress(buf.address + klen + data.length);
      final n = key == null
          ? _HashNative.digest(algo._code, dp, data.length, op, _nativeMaxDigest)
          : _HashNative.hmac(algo._code, kp, klen, dp, data.length, op, _nativeMaxDigest);
      if (n < 0) {
        final why = l2native.lastError();
        if (key != null) throw ArgumentError.value('•••', 'key', '${algo.name}: $why');
        throw l2native.NativeException('hash with ${algo.name}', why);
      }
      return Uint8List.fromList(view.sublist(klen + data.length, klen + data.length + n));
    } finally {
      l2native.free(buf, size);
    }
  }
  final h = _nativeOpen(algo, key);
  final buf = l2native.alloc(_nativeChunk);
  try {
    final view = buf.asTypedList(_nativeChunk);
    for (var at = 0; at < data.length; at += _nativeChunk) {
      final n = data.length - at < _nativeChunk ? data.length - at : _nativeChunk;
      view.setRange(0, n, data, at);
      if (_HashNative.digestUpdate(h, buf, n) < 0) {
        final why = l2native.lastError();
        _nativeFinish(algo, h);
        if (key != null) throw ArgumentError.value('•••', 'key', '${algo.name}: $why');
        throw l2native.NativeException('hash with ${algo.name}', why);
      }
    }
  } finally {
    l2native.free(buf, _nativeChunk);
  }
  return _nativeFinish(algo, h);
}

/// The digest/MAC of the file at [path], read inside the native library on one of its
/// threads (the event loop stays free); [onProgress] hears bytes read and the size.
Future<Uint8List> _nativeFile(
  Algo algo,
  List<int>? key,
  String path, {
  void Function(int done, int total)? onProgress,
}) async {
  try {
    return await nativeJob(
      'hash $path',
      l2native.engineJobs,
      (done, stop, progress, id) => l2native.withText(
        path,
        (p, n) => l2native.withBytes(
          key ?? const <int>[],
          (k, kn) => _HashNative.digestFile(algo._code, p, n, k, kn, done, stop, progress, id),
        ),
      ),
      onProgress: onProgress,
    );
  } on NativeException catch (e) {
    throw _nativeFileError(e.message, path);
  }
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

extension SourceHash on Source {
  /// The digest of every byte ([key]: its MAC). A File hashes inside the native library in
  /// constant memory, on one of its threads; other sources stream through a native digest
  /// handle. [onProgress] hears a file's bytes read and its size.
  Future<Uint8List> hash(Algo algo, {Object? key, void Function(int done, int total)? onProgress}) async {
    final k = key == null ? null : _bytes(key);
    if (this case final fs.File f) return _nativeFile(algo, k, f.path, onProgress: onProgress);
    // The native handle opens only once the reader has: a failing source leaks nothing.
    final r = await reader();
    final buf = l2native.alloc(_streamChunk);
    final h = _nativeOpen(algo, k);
    var finished = false;
    try {
      final view = buf.asTypedList(_streamChunk);
      final chunk = Uint8List(_streamChunk);
      while (true) {
        final n = await r.read(chunk);
        if (n <= 0) break;
        view.setRange(0, n, chunk);
        if (_HashNative.digestUpdate(h, buf, n) < 0) {
          final why = l2native.lastError();
          finished = true;
          _nativeFinish(algo, h);
          if (key != null) throw ArgumentError.value('•••', 'key', '${algo.name}: $why');
          throw l2native.NativeException('hash with ${algo.name}', why);
        }
      }
      finished = true;
      return _nativeFinish(algo, h);
    } finally {
      // Finishing frees the handle: an error on the way releases it too.
      if (!finished) _nativeFinish(algo, h);
      l2native.free(buf, _streamChunk);
      await r.close();
    }
  }
}

/// Digest bytes rendered as text or a number.
extension Digest on List<int> {
  /// Lowercase hex string.
  String get hex {
    final sb = StringBuffer();
    for (final b in this) {
      sb.write((b & 0xFF).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Padded base64 string.
  String get base64 => base64Encode(this);

  /// Big-endian integer value of the digest.
  int toInt() {
    var v = 0;
    for (final b in this) {
      v = (v << 8) | (b & 0xFF);
    }
    return v;
  }
}

/// Lowercase hex text for bytes.
abstract final class Hex {
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
  /// Decodes padded (or unpadded, per `dart:convert`) base64 [text].
  static Uint8List decode(String text) => base64Decode(_normalize(text));

  /// [text] for decoding: whitespace stripped, padding restored.
  static String _normalize(String text) {
    final compact = text.replaceAll(RegExp(r'\s'), '');
    final pad = (4 - compact.length % 4) % 4;
    return '$compact${'=' * pad}';
  }
}
