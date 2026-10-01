part of '../../hash.dart';

// Bindings to the digest half of dart_toolkit_native. Every receiver in `digest.dart` ends in
// one of the three functions at the bottom: bytes in memory, one file, many files.

typedef _U8 = Pointer<Uint8>;
typedef _Handle = Pointer<Void>;

/// The native functions, looked up once on first use.
final class _N {
  static final lib = NativeBridge.require();

  static final digestNew = lib.lookupFunction<_Handle Function(Uint32), _Handle Function(int)>('tk_digest_new');
  static final macNew = lib.lookupFunction<_Handle Function(Uint32, _U8, IntPtr), _Handle Function(int, _U8, int)>(
    'tk_mac_new',
  );
  static final digestFile = lib.lookupFunction<Int32 Function(_Handle, _U8, IntPtr), int Function(_Handle, _U8, int)>(
    'tk_digest_file',
  );
  static final digestFinal = lib.lookupFunction<Int32 Function(_Handle, _U8, IntPtr), int Function(_Handle, _U8, int)>(
    'tk_digest_final',
  );
  static final digest = lib
      .lookupFunction<Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr), int Function(int, _U8, int, _U8, int)>(
        'tk_digest',
      );
  static final hmac = lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr),
        int Function(int, _U8, int, _U8, int, _U8, int)
      >('tk_hmac');
  static final digestFiles = lib
      .lookupFunction<Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr), int Function(int, _U8, int, _U8, int)>(
        'tk_digest_files',
      );
}

/// The longest digest the library produces (SHA-512, BLAKE2b), and so the size of every
/// fixed-digest output buffer.
const _maxDigest = 64;

/// A file up to this size is read by the library on the calling isolate; a larger one in a
/// worker isolate, which costs about 2 ms to start — what SHA-256 takes over 4 MiB.
const _inline = 4 << 20;

/// A failed MAC is always the key's fault — one too long for BLAKE2, not 32 bytes for BLAKE3,
/// or a checksum asked to take one — so it is an [ArgumentError]; a digest cannot fail.
Never _fail(Hash algorithm, List<int>? key) {
  final message = '${algorithm.name}: ${NativeBridge.lastError()}';
  throw key == null ? StateError(message) : ArgumentError(message);
}

/// The digest of [data], or its MAC under [key]: key, data and output share one allocation.
Uint8List _ofBytes(Hash algorithm, List<int>? key, List<int> data) {
  final k = key?.length ?? 0, n = data.length, size = k + n + _maxDigest;
  final buf = NativeBridge.alloc(size);
  try {
    final view = buf.asTypedList(size)
      ..setAll(0, key ?? const [])
      ..setAll(k, data);
    final len = key == null
        ? _N.digest(algorithm.index, buf + k, n, buf + k + n, _maxDigest)
        : _N.hmac(algorithm.index, buf, k, buf + k, n, buf + k + n, _maxDigest);
    if (len < 0) _fail(algorithm, key);
    return Uint8List.fromList(Uint8List.sublistView(view, k + n, k + n + len));
  } finally {
    NativeBridge.free(buf, size);
  }
}

/// The digest or MAC of the file at [path], read by the library; blocks until it is done.
Uint8List _ofFile(Hash algorithm, List<int>? key, String path) {
  final h = key == null
      ? _N.digestNew(algorithm.index)
      : NativeBridge.withBytes(key, (k, n) => _N.macNew(algorithm.index, k, n));
  if (h == nullptr) _fail(algorithm, key);
  // The handle is released by `digestFinal` whether or not the file could be read.
  final failure = NativeBridge.withText(path, (p, n) => _N.digestFile(h, p, n)) < 0 ? NativeBridge.lastError() : null;
  final digest = NativeBridge.withOut(_maxDigest, (out) => _N.digestFinal(h, out, _maxDigest));
  if (failure != null) throw FileSystemException(failure, path);
  return digest;
}

/// The digests of [paths], in order, hashed in parallel by the library; blocks until done.
List<Uint8List> _ofFiles(Hash algorithm, List<String> paths) {
  // One empty name joins to nothing at all, which the library reads as no files.
  if (paths.contains('')) throw const FileSystemException('Cannot hash a file with an empty name', '');
  final cap = algorithm.length * paths.length;
  final out = NativeBridge.withText(paths.join('\x00'), (p, n) {
    final buf = NativeBridge.alloc(cap);
    try {
      final count = _N.digestFiles(algorithm.index, p, n, buf, cap);
      if (count < 0) throw FileSystemException(NativeBridge.lastError(), null);
      // Each digest is matched to its file by position, so a short count is a wrong answer.
      if (count != paths.length) throw StateError('hashed $count of ${paths.length} files');
      return Uint8List.fromList(buf.asTypedList(cap));
    } finally {
      NativeBridge.free(buf, cap);
    }
  });
  return [for (var i = 0; i < cap; i += algorithm.length) Uint8List.sublistView(out, i, i + algorithm.length)];
}
