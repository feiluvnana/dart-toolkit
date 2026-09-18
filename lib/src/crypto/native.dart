part of '../../crypto.dart';

// ---------------------------------------------------------------------------------------------
// Bindings to dart_toolkit_native. Bytes cross as (pointer, length); fixed-size results land in
// a caller buffer through `Native.withOut`, variable-size ones in a Rust allocation through
// `Native.take`.
// ---------------------------------------------------------------------------------------------

typedef _U8 = Pointer<Uint8>;
typedef _PP = Pointer<Pointer<Uint8>>;
typedef _PL = Pointer<IntPtr>;

/// The native functions, looked up once on first use.
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
  static final digest = lib.lookupFunction<Int32 Function(Uint32, _U8, IntPtr, _U8), int Function(int, _U8, int, _U8)>(
    'tk_digest',
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
  static final argon2id = lib.lookupFunction<_SlowKdfC, _SlowKdf>('tk_argon2id');
  static final scrypt = lib.lookupFunction<_SlowKdfC, _SlowKdf>('tk_scrypt');
  static final passwordHash = lib
      .lookupFunction<
        Int32 Function(Uint32, Uint32, Uint32, Uint32, _U8, IntPtr, _PP, _PL),
        int Function(int, int, int, int, _U8, int, _PP, _PL)
      >('tk_password_hash');
  static final passwordVerify = lib
      .lookupFunction<Int32 Function(_U8, IntPtr, _U8, IntPtr), int Function(_U8, int, _U8, int)>('tk_password_verify');
  static final seal = lib.lookupFunction<_CipherC, _Cipher>('tk_seal');
  static final open = lib.lookupFunction<_CipherC, _Cipher>('tk_open');
  static final x25519Public = lib.lookupFunction<Int32 Function(_U8, _U8), int Function(_U8, _U8)>('tk_x25519_public');
  static final x25519Agree = lib.lookupFunction<Int32 Function(_U8, _U8, _U8), int Function(_U8, _U8, _U8)>(
    'tk_x25519_agree',
  );
  static final p256Agree = lib.lookupFunction<Int32 Function(_U8, _U8, IntPtr, _U8), int Function(_U8, _U8, int, _U8)>(
    'tk_p256_agree',
  );
  static final ed25519Public = lib.lookupFunction<Int32 Function(_U8, _U8), int Function(_U8, _U8)>(
    'tk_ed25519_public',
  );
  static final ed25519Sign = lib.lookupFunction<_SignC, _Sign>('tk_ed25519_sign');
  static final ed25519Verify = lib.lookupFunction<_SignC, _Sign>('tk_ed25519_verify');
  static final p256Public = lib.lookupFunction<Int32 Function(_U8, _U8), int Function(_U8, _U8)>('tk_p256_public');
  static final p256Sign = lib.lookupFunction<_SignC, _Sign>('tk_p256_sign');
  static final p256Verify = lib
      .lookupFunction<Int32 Function(_U8, IntPtr, _U8, IntPtr, _U8), int Function(_U8, int, _U8, int, _U8)>(
        'tk_p256_verify',
      );
  static final keyToPem = lib
      .lookupFunction<Int32 Function(Uint32, _U8, Int32, _PP, _PL), int Function(int, _U8, int, _PP, _PL)>(
        'tk_key_to_pem',
      );
  static final privateFromPem = lib.lookupFunction<_FromPemC, _FromPem>('tk_private_from_pem');
  static final publicFromPem = lib.lookupFunction<_FromPemC, _FromPem>('tk_public_from_pem');
  static final rsaGenerate = lib.lookupFunction<Int32 Function(Uint32, _PP, _PL), int Function(int, _PP, _PL)>(
    'tk_rsa_generate',
  );
  static final rsaPublicPem = lib
      .lookupFunction<Int32 Function(_U8, IntPtr, _PP, _PL), int Function(_U8, int, _PP, _PL)>('tk_rsa_public_pem');
  static final rsaSign = lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, Uint32, Int32, _U8, IntPtr, _PP, _PL),
        int Function(_U8, int, int, int, _U8, int, _PP, _PL)
      >('tk_rsa_sign');
  static final rsaVerify = lib
      .lookupFunction<
        Int32 Function(_U8, IntPtr, Uint32, Int32, _U8, IntPtr, _U8, IntPtr),
        int Function(_U8, int, int, int, _U8, int, _U8, int)
      >('tk_rsa_verify');
  static final rsaEncrypt = lib.lookupFunction<_RsaCryptC, _RsaCrypt>('tk_rsa_encrypt');
  static final rsaDecrypt = lib.lookupFunction<_RsaCryptC, _RsaCrypt>('tk_rsa_decrypt');
}

typedef _SlowKdfC = Int32 Function(_U8, IntPtr, _U8, IntPtr, Uint32, Uint32, Uint32, _U8, IntPtr);
typedef _SlowKdf = int Function(_U8, int, _U8, int, int, int, int, _U8, int);
typedef _CipherC = Int32 Function(Uint32, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr, _U8, IntPtr, _U8);
typedef _Cipher = int Function(int, _U8, int, _U8, int, _U8, int, _U8, int, _U8);
typedef _SignC = Int32 Function(_U8, _U8, IntPtr, _U8);
typedef _Sign = int Function(_U8, _U8, int, _U8);
typedef _FromPemC = Int32 Function(Uint32, _U8, IntPtr, _U8);
typedef _FromPem = int Function(int, _U8, int, _U8);
typedef _RsaCryptC = Int32 Function(_U8, IntPtr, Uint32, _U8, IntPtr, _PP, _PL);
typedef _RsaCrypt = int Function(_U8, int, int, _U8, int, _PP, _PL);

const _chunk = 1 << 20;

/// A digest fed in pieces, for files; `bytes.hashBytes` is the one-call form.
final class _Digest {
  final Pointer<Void> _ctx;
  final _U8 _buffer = Native.malloc(_chunk);
  late final Uint8List _view = _buffer.asTypedList(_chunk);

  _Digest(Hash algorithm) : _ctx = _N.digestNew(algorithm.index);

  void add(List<int> chunk) {
    for (var off = 0; off < chunk.length; off += _chunk) {
      final n = chunk.length - off < _chunk ? chunk.length - off : _chunk;
      _view.setRange(0, n, chunk, off);
      _N.digestUpdate(_ctx, _buffer, n);
    }
  }

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

/// A UTF-8 string the library allocated.
String _takeText(int Function(_PP, _PL) body) => utf8.decode(Native.take(body));

/// A 32-byte key (kind 0 Ed25519, 1 P-256) as PEM: PKCS#8, or SPKI of its public half.
String _pem(int kind, List<int> key, {required bool public}) =>
    Native.withBytes(key, (k, _) => _takeText((out, len) => _N.keyToPem(kind, k, public ? 1 : 0, out, len)));

Uint8List _fromPem(_FromPem f, int kind, String pem, int size) =>
    Native.withBytes(utf8.encode(pem), (p, pl) => Native.withOut(size, (out) => f(kind, p, pl, out)));
