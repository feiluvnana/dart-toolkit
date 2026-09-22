part of '../../hash.dart';

// ---------------------------------------------------------------------------------------------
// Bindings to the digest half of dart_toolkit_native. Bytes cross as (pointer, length) and
// results land in a caller buffer through `NativeBridge.withOut`.
// ---------------------------------------------------------------------------------------------

typedef _U8 = Pointer<Uint8>;

/// The native functions, looked up once on first use.
final class _N {
  static final lib = NativeBridge.require('hashing');

  static final digestNew = lib.lookupFunction<Pointer<Void> Function(Uint32), Pointer<Void> Function(int)>(
    'tk_digest_new',
  );
  static final digestUpdate = lib
      .lookupFunction<Void Function(Pointer<Void>, _U8, IntPtr), void Function(Pointer<Void>, _U8, int)>(
        'tk_digest_update',
      );
  static final digestFinal = lib
      .lookupFunction<Int32 Function(Pointer<Void>, _U8, IntPtr), int Function(Pointer<Void>, _U8, int)>(
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
}

/// Bytes staged into native memory per `tk_digest_update`. `openRead` hands over about
/// 64 KiB at a time, so a larger staging buffer is allocated and never filled.
const _stage = 64 * 1024;

/// The longest digest the library produces (SHA-512, BLAKE2b), and so the size of every
/// fixed-digest output buffer.
const _maxDigest = 64;

/// A digest fed in pieces, for files; `bytes.hashBytes` is the one-call form.
final class _Digest {
  final Pointer<Void> _ctx;
  final _U8 _buffer = NativeBridge.alloc(_stage);
  late final Uint8List _view = _buffer.asTypedList(_stage);
  bool _released = false;

  _Digest(Hash algorithm) : _ctx = _N.digestNew(algorithm.index);

  void add(List<int> chunk) {
    for (var off = 0; off < chunk.length; off += _stage) {
      final n = chunk.length - off < _stage ? chunk.length - off : _stage;
      _view.setRange(0, n, chunk, off);
      _N.digestUpdate(_ctx, _buffer, n);
    }
  }

  Uint8List finish() {
    try {
      return NativeBridge.withOut(_maxDigest, (out) => _N.digestFinal(_ctx, out, _maxDigest));
    } finally {
      _released = true;
      NativeBridge.free(_buffer, _stage);
    }
  }

  /// Releases the native context and staging buffer when [finish] is never reached — a
  /// source that throws mid-read would otherwise leak both, invisibly to Dart's GC.
  /// Idempotent, and safe to call after [finish].
  void dispose() {
    if (_released) return;
    _released = true;
    try {
      // `tk_digest_final` is what frees the context; the half-fed digest is discarded.
      NativeBridge.withOut(_maxDigest, (out) => _N.digestFinal(_ctx, out, _maxDigest));
    } catch (_) {
      // Releasing is the point here; a failure to produce a digest nobody wants is not.
    }
    NativeBridge.free(_buffer, _stage);
  }
}

/// Runs [body] with two byte arguments in native memory.
R _with2<R>(List<int> a, List<int> b, R Function(_U8, int, _U8, int) body) =>
    NativeBridge.withBytes(a, (pa, la) => NativeBridge.withBytes(b, (pb, lb) => body(pa, la, pb, lb)));
