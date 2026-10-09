part of '../../hash.dart';

// Every receiver in `digest.dart` ends in one of the functions here.

typedef _U8 = Pointer<Uint8>;
typedef _Handle = Pointer<Void>;
typedef _HandleOp = Int32 Function(_Handle, _U8, IntPtr);
typedef _HandleOpDart = int Function(_Handle, _U8, int);
typedef _BufOp = Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr);
typedef _BufOpDart = int Function(int, _U8, int, _U8, int);

final class _N {
  static final lib = NativeBridge.main.require();

  static final digestNew = lib.lookupFunction<_Handle Function(Uint32), _Handle Function(int)>('tk_digest_new');
  static final macNew = lib.lookupFunction<_Handle Function(Uint32, _U8, IntPtr), _Handle Function(int, _U8, int)>(
    'tk_mac_new',
  );
  static final digestFile = lib
      .lookupFunction<
        Int32 Function(_Handle, _U8, IntPtr, NativeProgress, _U8),
        int Function(_Handle, _U8, int, NativeProgress, _U8)
      >('tk_digest_file');
  static final digestUpdate = lib.lookupFunction<_HandleOp, _HandleOpDart>('tk_digest_update');
  static final digestFinal = lib.lookupFunction<_HandleOp, _HandleOpDart>('tk_digest_final');
  static final digest = lib.lookupFunction<_BufOp, _BufOpDart>('tk_digest');
  static final hmac = lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr),
        int Function(int, _U8, int, _U8, int, _U8, int)
      >('tk_hmac');
}

/// The longest digest (SHA-512, BLAKE2b): the size of every output buffer.
const _maxDigest = 64;

/// A file up to this size is read by the library on the calling isolate; a larger one in a
/// worker isolate, which costs about 2 ms to start — what SHA-256 takes over 4 MiB.
const _inline = 4 << 20;

/// How much of a stream is handed to the library at a time.
const _streamChunk = 64 << 10;

/// A failed MAC is always the key's fault, so an [ArgumentError]; a digest cannot fail.
Never _fail(int alg, List<int>? key) {
  final why = NativeBridge.main.lastError();
  final name = Hash.values[alg].name;
  throw key == null ? NativeException('hash with $name', why) : ArgumentError.value('•••', 'key', '$name: $why');
}

/// The digest of [data], or its MAC under [key]: key, data and output share one allocation.
Uint8List _ofBytes(Hash algorithm, List<int>? key, List<int> data) {
  final k = key?.length ?? 0, n = data.length, size = k + n + _maxDigest;
  final buf = NativeBridge.main.alloc(size);
  try {
    // setAll is setRange underneath, so a Uint8List still copies with one memmove.
    final view = buf.asTypedList(size);
    if (key != null) view.setAll(0, key);
    view.setAll(k, data);
    final len = key == null
        ? _N.digest(algorithm.index, buf + k, n, buf + k + n, _maxDigest)
        : _N.hmac(algorithm.index, buf, k, buf + k, n, buf + k + n, _maxDigest);
    if (len < 0) _fail(algorithm.index, key);
    return Uint8List.fromList(Uint8List.sublistView(view, k + n, k + n + len));
  } finally {
    NativeBridge.main.free(buf, size);
  }
}

/// A new digest handle, or a MAC handle under [key]; [_finish] releases it.
_Handle _open(int alg, List<int>? key) {
  final h = key == null ? _N.digestNew(alg) : NativeBridge.main.withBytes(key, (k, n) => _N.macNew(alg, k, n));
  return h == nullptr ? _fail(alg, key) : h;
}

/// The digest [h] holds; the handle is released.
Uint8List _finish(int alg, _Handle h) => NativeBridge.main.withOut(
  'hash with ${Hash.values[alg].name}',
  _maxDigest,
  (out) => _N.digestFinal(h, out, _maxDigest),
);

/// The digest or MAC of the file at [path], read by the library; blocks until it is done.
/// [progress] and [stop] are a worker's, or `nullptr`.
Uint8List _ofFile(int alg, List<int>? key, String path, NativeProgress progress, _U8 stop) {
  final h = _open(alg, key);
  // `_finish` releases the handle even after a failed read.
  final failure = NativeBridge.main.withText(path, (p, n) => _N.digestFile(h, p, n, progress, stop)) < 0
      ? NativeBridge.main.lastError()
      : null;
  final digest = _finish(alg, h);
  if (failure == null) return digest;
  final error = NativeBridge.fileError(failure, path, 'Cannot hash $path');
  // What is not the OS's own error is the file's nature: no FormatException for a read.
  throw error is FormatException ? FileSystemException('Cannot hash: ${error.message}', path) : error;
}

/// The digest or MAC of [source], fed to the library through one buffer a slice at a time,
/// [work] told the bytes so far; a cancel ends it at once.
Future<Uint8List> _ofStream(Hash algorithm, List<int>? key, Stream<List<int>> source, Work work) async {
  final h = _open(algorithm.index, key);
  final buf = NativeBridge.main.alloc(_streamChunk);
  final view = buf.asTypedList(_streamChunk);
  var received = 0;
  try {
    await for (final chunk in source.cancellable) {
      for (var at = 0; at < chunk.length; at += _streamChunk) {
        final n = min(_streamChunk, chunk.length - at);
        view.setRange(0, n, chunk, at);
        if (_N.digestUpdate(h, buf, n) < 0) _fail(algorithm.index, key);
      }
      received += chunk.length;
      work.amount(received);
    }
  } catch (_) {
    _finish(algorithm.index, h);
    rethrow;
  } finally {
    NativeBridge.main.free(buf, _streamChunk);
  }
  return _finish(algorithm.index, h);
}
