part of '../../crypto.dart';

/// TOTP (RFC 6238) and HOTP (RFC 4226): the codes authenticator apps show.
///
/// ```dart
/// final totp = Totp.fromBase32('JBSWY3DPEHPK3PXP');
/// totp.code();                 // '492039'
/// totp.verify(userInput);      // this period or the one either side
/// totp.uri('me@example.com', issuer: 'Example');  // for the QR code
/// ```
///
/// {@category Crypto}
final class Totp {
  final Key secret;
  final int digits;

  /// Seconds per code.
  final int period;

  /// SHA-1 is what every authenticator app supports.
  final Hash digest;

  const Totp(this.secret, {this.digits = 6, this.period = 30, this.digest = Hash.sha1});

  /// From the base32 secret a provisioning URI or QR code carries.
  Totp.fromBase32(String secret, {int digits = 6, int period = 30, Hash digest = Hash.sha1})
    : this(Key.fromBase32(secret), digits: digits, period: period, digest: digest);

  /// The code for [at], now by default.
  String code([DateTime? at]) => hotp(_counter(at));

  /// The HOTP code for [counter].
  String hotp(int counter) {
    final mac = (Uint8List(8)..buffer.asByteData().setUint64(0, counter)).hmacBytes(digest, secret.bytes);
    final o = mac.last & 0xf;
    final bin = ((mac[o] & 0x7f) << 24) | (mac[o + 1] << 16) | (mac[o + 2] << 8) | mac[o + 3];
    return (bin % pow(10, digits).toInt()).toString().padLeft(digits, '0');
  }

  /// Whether [code] is valid for [at], allowing [window] periods of clock drift either way.
  bool verify(String code, {DateTime? at, int window = 1}) {
    final c = _counter(at);
    final given = utf8.encode(code.replaceAll(' ', ''));
    for (var i = c - window; i <= c + window; i++) {
      if (i >= 0 && Crypto.equals(utf8.encode(hotp(i)), given)) return true;
    }
    return false;
  }

  /// The `otpauth://` URI authenticator apps enrol from.
  String uri(String account, {String? issuer}) {
    final label = Uri.encodeComponent(issuer == null ? account : '$issuer:$account');
    return Uri(
      scheme: 'otpauth',
      host: 'totp',
      path: '/$label',
      queryParameters: {
        'secret': secret.base32,
        'issuer': ?issuer,
        'algorithm': digest.name.toUpperCase(),
        'digits': '$digits',
        'period': '$period',
      },
    ).toString();
  }

  int _counter(DateTime? at) => (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 ~/ period;
}
