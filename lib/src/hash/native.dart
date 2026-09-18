part of '../../hash.dart';

/// A streaming digest. Native — CommonCrypto on macOS, OpenSSL's libcrypto on Linux — when
/// the platform provides one, `package:crypto` otherwise. Same bytes out either way.
abstract interface class _Digest {
  void add(List<int> chunk);
  Uint8List finish();
}

_Digest _digest(Hash algorithm) => _Native.instance?.digest(algorithm) ?? _CryptoDigest(algorithm._crypto);

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

// ---------------------------------------------------------------------------------------------
// Pure Dart
// ---------------------------------------------------------------------------------------------

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
// Native
// ---------------------------------------------------------------------------------------------

typedef _MallocC = Pointer<Uint8> Function(IntPtr);
typedef _MallocD = Pointer<Uint8> Function(int);
typedef _FreeC = Void Function(Pointer<Uint8>);
typedef _FreeD = void Function(Pointer<Uint8>);

/// The platform's hashing library, looked up once; `null` where there is none we know.
abstract final class _Native {
  static final _Native? instance = _load();

  static _Native? _load() {
    try {
      if (Platform.isMacOS) return _CommonCrypto();
      if (Platform.isLinux) return _LibCrypto();
    } catch (_) {
      // No usable library: the pure-Dart path takes over.
    }
    return null;
  }

  _Digest digest(Hash algorithm);
}

/// Bytes are copied into one reusable native buffer, at most [_bufferSize] at a time.
const _bufferSize = 1 << 20;

// ---- macOS: CommonCrypto, linked into every process through libSystem.

typedef _CcInitC = Int32 Function(Pointer<Uint8>);
typedef _CcInitD = int Function(Pointer<Uint8>);
typedef _CcUpdateC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Uint32);
typedef _CcUpdateD = int Function(Pointer<Uint8>, Pointer<Uint8>, int);
typedef _CcFinalC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _CcFinalD = int Function(Pointer<Uint8>, Pointer<Uint8>);

final class _CommonCrypto extends _Native {
  final DynamicLibrary _lib = DynamicLibrary.process();
  late final _MallocD _malloc = _lib.lookupFunction<_MallocC, _MallocD>('malloc');
  late final _FreeD _free = _lib.lookupFunction<_FreeC, _FreeD>('free');

  _CommonCrypto() {
    _lib.lookup<NativeFunction<_CcInitC>>('CC_SHA256_Init'); // throws when absent
  }

  @override
  _Digest digest(Hash algorithm) => _CcDigest(this, algorithm._cc, algorithm.length);
}

final class _CcDigest implements _Digest {
  final _CommonCrypto _cc;
  final int _length;
  final _CcUpdateD _update;
  final _CcFinalD _final;
  final Pointer<Uint8> _ctx;
  final Pointer<Uint8> _buffer;
  late final Uint8List _view = _buffer.asTypedList(_bufferSize);

  _CcDigest(this._cc, String prefix, this._length)
    : _update = _cc._lib.lookupFunction<_CcUpdateC, _CcUpdateD>('${prefix}_Update'),
      _final = _cc._lib.lookupFunction<_CcFinalC, _CcFinalD>('${prefix}_Final'),
      _ctx = _cc._malloc(512), // the largest context, CC_SHA512_CTX, is 208 bytes
      _buffer = _cc._malloc(_bufferSize) {
    _cc._lib.lookupFunction<_CcInitC, _CcInitD>('${prefix}_Init')(_ctx);
  }

  @override
  void add(List<int> chunk) {
    for (var off = 0; off < chunk.length; off += _bufferSize) {
      final n = chunk.length - off < _bufferSize ? chunk.length - off : _bufferSize;
      _view.setRange(0, n, chunk, off);
      _update(_ctx, _buffer, n);
    }
  }

  @override
  Uint8List finish() {
    final out = _cc._malloc(_length);
    try {
      _final(out, _ctx);
      return Uint8List.fromList(out.asTypedList(_length));
    } finally {
      _cc._free(out);
      _cc._free(_ctx);
      _cc._free(_buffer);
    }
  }
}

// ---- Linux: OpenSSL's EVP interface, in libcrypto 3 or 1.1.

typedef _EvpNewC = Pointer<Void> Function();
typedef _EvpNewD = Pointer<Void> Function();
typedef _EvpMdC = Pointer<Void> Function();
typedef _EvpMdD = Pointer<Void> Function();
typedef _EvpInitC = Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _EvpInitD = int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _EvpUpdateC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _EvpUpdateD = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _EvpFinalC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);
typedef _EvpFinalD = int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);
typedef _EvpFreeC = Void Function(Pointer<Void>);
typedef _EvpFreeD = void Function(Pointer<Void>);

final class _LibCrypto extends _Native {
  late final DynamicLibrary _lib = _open();
  late final DynamicLibrary _libc = DynamicLibrary.process();
  late final _MallocD _malloc = _libc.lookupFunction<_MallocC, _MallocD>('malloc');
  late final _FreeD _free = _libc.lookupFunction<_FreeC, _FreeD>('free');
  late final _EvpNewD _new = _lib.lookupFunction<_EvpNewC, _EvpNewD>('EVP_MD_CTX_new');
  late final _EvpFreeD _freeCtx = _lib.lookupFunction<_EvpFreeC, _EvpFreeD>('EVP_MD_CTX_free');
  late final _EvpInitD _init = _lib.lookupFunction<_EvpInitC, _EvpInitD>('EVP_DigestInit_ex');
  late final _EvpUpdateD _update = _lib.lookupFunction<_EvpUpdateC, _EvpUpdateD>('EVP_DigestUpdate');
  late final _EvpFinalD _final = _lib.lookupFunction<_EvpFinalC, _EvpFinalD>('EVP_DigestFinal_ex');
  final Map<Hash, Pointer<Void>> _mds = {};

  _LibCrypto() {
    _new; // resolve now, so a missing library fails at load time and falls back
  }

  static DynamicLibrary _open() {
    Object? last;
    for (final name in ['libcrypto.so.3', 'libcrypto.so.1.1', 'libcrypto.so']) {
      try {
        return DynamicLibrary.open(name);
      } catch (e) {
        last = e;
      }
    }
    throw last!;
  }

  @override
  _Digest digest(Hash algorithm) =>
      _EvpDigest(this, _mds[algorithm] ??= _lib.lookupFunction<_EvpMdC, _EvpMdD>(algorithm._evp)(), algorithm.length);
}

final class _EvpDigest implements _Digest {
  final _LibCrypto _c;
  final int _length;
  final Pointer<Void> _ctx;
  final Pointer<Uint8> _buffer;
  late final Uint8List _view = _buffer.asTypedList(_bufferSize);

  _EvpDigest(this._c, Pointer<Void> md, this._length) : _ctx = _c._new(), _buffer = _c._malloc(_bufferSize) {
    _c._init(_ctx, md, nullptr);
  }

  @override
  void add(List<int> chunk) {
    for (var off = 0; off < chunk.length; off += _bufferSize) {
      final n = chunk.length - off < _bufferSize ? chunk.length - off : _bufferSize;
      _view.setRange(0, n, chunk, off);
      _c._update(_ctx, _buffer, n);
    }
  }

  @override
  Uint8List finish() {
    final out = _c._malloc(64);
    try {
      _c._final(_ctx, out, nullptr);
      return Uint8List.fromList(out.asTypedList(_length));
    } finally {
      _c._free(out);
      _c._freeCtx(_ctx);
      _c._free(_buffer);
    }
  }
}
