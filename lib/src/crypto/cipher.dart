part of '../../crypto.dart';

/// An authenticated cipher: [seal] chooses a fresh 12-byte nonce and prepends it, so the
/// output is `nonce ‖ ciphertext ‖ tag` and [open] needs only the key. A tampered byte, a
/// wrong key or a wrong [aad] makes [open] throw [CipherException]. Needs the native library.
///
/// ```dart
/// final box = Aes.gcm(Key.random());
/// final sealed = box.seal(utf8.encode('secret'), aad: header);
/// final plain = box.open(sealed, aad: header);
/// ```
///
/// {@category Crypto}
sealed class Cipher {
  final Key key;
  final int _alg;

  const Cipher._(this.key, this._alg);

  /// Encrypts [plain]; [aad] is authenticated but not encrypted.
  Uint8List seal(List<int> plain, {List<int> aad = const []}) {
    Native.require(_name);
    final nonce = _randomBytes(12);
    final ct = _with3(
      key.bytes,
      aad,
      plain,
      (k, kl, a, al, p, pl) => Native.withBytes(
        nonce,
        (n, nl) => Native.withOut(pl + 16, (out) => _N.seal(_alg, k, kl, n, nl, a, al, p, pl, out)),
      ),
    );
    return Uint8List.fromList([...nonce, ...ct]);
  }

  /// Decrypts what [seal] produced.
  Uint8List open(List<int> sealed, {List<int> aad = const []}) {
    Native.require(_name);
    if (sealed.length < 12 + 16) throw CipherException('Sealed data is too short');
    final nonce = sealed.sublist(0, 12);
    final body = sealed.sublist(12);
    final out = _with3(
      key.bytes,
      aad,
      body,
      (k, kl, a, al, c, cl) => Native.withBytes(nonce, (n, nl) {
        final ptr = Native.malloc(cl);
        try {
          final len = _N.open(_alg, k, kl, n, nl, a, al, c, cl, ptr);
          if (len == -3) throw CipherException('Authentication failed: wrong key, wrong aad, or tampered data');
          if (len < 0) throw StateError(Native.lastError());
          return Uint8List.fromList(ptr.asTypedList(len));
        } finally {
          Native.free(ptr);
        }
      }),
    );
    return out;
  }

  /// Encrypts [source] into [dest] in 1 MB sealed chunks; memory stays flat.
  Future<void> encryptFile(String source, String dest) async {
    final out = File(dest).openWrite();
    try {
      var index = 0;
      await for (final chunk in _chunks(File(source).openRead())) {
        final sealed = seal(chunk, aad: _counter(index++));
        out.add(_lengthPrefix(sealed.length));
        out.add(sealed);
      }
    } finally {
      await out.close();
    }
  }

  /// Decrypts what [encryptFile] produced.
  Future<void> decryptFile(String source, String dest) async {
    final out = File(dest).openWrite();
    try {
      final data = await File(source).readAsBytes();
      var pos = 0;
      var index = 0;
      while (pos < data.length) {
        final len = ByteData.sublistView(data, pos, pos + 4).getUint32(0);
        pos += 4;
        out.add(open(Uint8List.sublistView(data, pos, pos + len), aad: _counter(index++)));
        pos += len;
      }
    } finally {
      await out.close();
    }
  }

  String get _name => switch (this) {
    Aes() => 'AES-GCM',
    ChaCha20Poly1305() => 'ChaCha20-Poly1305',
  };

  static Uint8List _counter(int i) => Uint8List(8)..buffer.asByteData().setUint64(0, i);
  static Uint8List _lengthPrefix(int n) => Uint8List(4)..buffer.asByteData().setUint32(0, n);

  static Stream<Uint8List> _chunks(Stream<List<int>> source) async* {
    final buffer = BytesBuilder(copy: false);
    await for (final piece in source) {
      buffer.add(piece);
      while (buffer.length >= _chunk) {
        final all = buffer.takeBytes();
        yield Uint8List.sublistView(all, 0, _chunk);
        buffer.add(Uint8List.sublistView(all, _chunk));
      }
    }
    if (buffer.isNotEmpty) yield buffer.takeBytes();
  }
}

/// AES in GCM mode; the key is 16 or 32 bytes.
///
/// {@category Crypto}
final class Aes extends Cipher {
  const Aes.gcm(Key key) : super._(key, 0);
}

/// ChaCha20-Poly1305 (RFC 8439); the key is 32 bytes.
///
/// {@category Crypto}
final class ChaCha20Poly1305 extends Cipher {
  const ChaCha20Poly1305(Key key) : super._(key, 1);
}

/// Decryption failed: the data, the key or the aad is not what was sealed.
///
/// {@category Crypto}
final class CipherException implements Exception {
  final String message;
  const CipherException(this.message);
  @override
  String toString() => message;
}
