part of '../../crypto.dart';

/// A streaming digest: the native library when it loaded, `package:crypto` otherwise.
abstract interface class _Digest {
  void add(List<int> chunk);
  Uint8List finish();
}

_Digest _digest(Hash algorithm) {
  if (Native.isAvailable) return _NativeDigest(algorithm);
  final fallback = algorithm._crypto;
  if (fallback == null) throw UnsupportedError('${algorithm.name} needs dart_toolkit_native: ${Native.reason}');
  return _CryptoDigest(fallback);
}

String _hex(Uint8List bytes) {
  const digits = '0123456789abcdef';
  final sb = StringBuffer();
  for (final b in bytes) {
    sb
      ..write(digits[b >> 4])
      ..write(digits[b & 0xf]);
  }
  return sb.toString();
}

final class _CryptoDigest implements _Digest {
  final List<crypto.Digest> _out = [];
  late final ByteConversionSink _in;

  _CryptoDigest(crypto.Hash hash) {
    _in = hash.startChunkedConversion(ChunkedConversionSink<crypto.Digest>.withCallback(_out.addAll));
  }

  @override
  void add(List<int> chunk) => _in.add(chunk);

  @override
  Uint8List finish() {
    _in.close();
    return Uint8List.fromList(_out.single.bytes);
  }
}

// ---------------------------------------------------------------------------------------------
// Bindings to dart_toolkit_native
// ---------------------------------------------------------------------------------------------

typedef _U8 = Pointer<Uint8>;

/// The native functions, looked up once.
final class _N {
  static final lib = Native.require('crypto');
  static final digestNew = lib.lookupFunction<Pointer<Void> Function(Uint32), Pointer<Void> Function(int)>(
    'tk_digest_new',
  );
  static final digestUpdate = lib
      .lookupFunction<Void Function(Pointer<Void>, _U8, IntPtr), void Function(Pointer<Void>, _U8, int)>(
        'tk_digest_update',
      );
  static final digestFinal = lib.lookupFunction<Int32 Function(Pointer<Void>, _U8), int Function(Pointer<Void>, _U8)>(
    'tk_digest_final',
  );
  static final hmac = lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, _U8),
        int Function(int, _U8, int, _U8, int, _U8)
      >('tk_hmac');
  static final pbkdf2 = lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, Uint32, _U8, IntPtr),
        int Function(int, _U8, int, _U8, int, int, _U8, int)
      >('tk_pbkdf2');
  static final hkdf = lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr),
        int Function(int, _U8, int, _U8, int, _U8, int, _U8, int)
      >('tk_hkdf');
  static final argon2id = lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, _U8, IntPtr, Uint32, Uint32, Uint32, _U8, IntPtr),
        int Function(_U8, int, _U8, int, int, int, int, _U8, int)
      >('tk_argon2id');
  static final seal = lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr, _U8),
        int Function(int, _U8, int, _U8, int, _U8, int, _U8, int, _U8)
      >('tk_seal');
  static final open = lib
      .lookupFunction<
        Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr, _U8),
        int Function(int, _U8, int, _U8, int, _U8, int, _U8, int, _U8)
      >('tk_open');
  static final ed25519Public = lib.lookupFunction<Int32 Function(_U8, _U8), int Function(_U8, _U8)>(
    'tk_ed25519_public',
  );
  static final ed25519Sign = lib
      .lookupFunction<Int32 Function(_U8, _U8, IntPtr, _U8), int Function(_U8, _U8, int, _U8)>('tk_ed25519_sign');
  static final ed25519Verify = lib
      .lookupFunction<Int32 Function(_U8, _U8, IntPtr, _U8), int Function(_U8, _U8, int, _U8)>('tk_ed25519_verify');
  static final p256Public = lib.lookupFunction<Int32 Function(_U8, _U8), int Function(_U8, _U8)>('tk_p256_public');
  static final p256Sign = lib.lookupFunction<Int32 Function(_U8, _U8, IntPtr, _U8), int Function(_U8, _U8, int, _U8)>(
    'tk_p256_sign',
  );
  static final p256Verify = lib
      .lookupFunction<Int32 Function(_U8, IntPtr, _U8, IntPtr, _U8), int Function(_U8, int, _U8, int, _U8)>(
        'tk_p256_verify',
      );
  static final crc32 = lib.lookupFunction<Uint32 Function(Uint32, _U8, IntPtr), int Function(int, _U8, int)>(
    'tk_crc32',
  );
  static final rsaVerify = lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, Uint32, _U8, IntPtr, _U8, IntPtr),
        int Function(_U8, int, int, _U8, int, _U8, int)
      >('tk_rsa_verify');
}

const _chunk = 1 << 20;

final class _NativeDigest implements _Digest {
  final Pointer<Void> _ctx;
  final _U8 _buffer = Native.malloc(_chunk);
  late final Uint8List _view = _buffer.asTypedList(_chunk);

  _NativeDigest(Hash algorithm) : _ctx = _N.digestNew(algorithm.index);

  @override
  void add(List<int> chunk) {
    for (var off = 0; off < chunk.length; off += _chunk) {
      final n = chunk.length - off < _chunk ? chunk.length - off : _chunk;
      _view.setRange(0, n, chunk, off);
      _N.digestUpdate(_ctx, _buffer, n);
    }
  }

  @override
  Uint8List finish() {
    try {
      return Native.withOut(64, (out) => _N.digestFinal(_ctx, out));
    } finally {
      Native.free(_buffer);
    }
  }
}

/// Runs [body] with two byte arguments in native memory.
R _with2<R>(List<int> a, List<int> b, R Function(_U8, int, _U8, int) body) =>
    Native.withBytes(a, (pa, la) => Native.withBytes(b, (pb, lb) => body(pa, la, pb, lb)));

R _with3<R>(List<int> a, List<int> b, List<int> c, R Function(_U8, int, _U8, int, _U8, int) body) =>
    _with2(a, b, (pa, la, pb, lb) => Native.withBytes(c, (pc, lc) => body(pa, la, pb, lb, pc, lc)));

/// CRC-32 continuing from [seed]: native, or the table in Dart.
int _crc32(int seed, List<int> data) {
  if (Native.isAvailable) return Native.withBytes(data, (p, n) => _N.crc32(seed, p, n));
  var c = seed ^ 0xFFFFFFFF;
  for (var i = 0; i < data.length; i++) {
    c = _crcTable[(c ^ data[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c;
  }
  return table;
}();
