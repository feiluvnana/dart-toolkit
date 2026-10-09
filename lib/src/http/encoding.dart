part of '../http.dart';

/// A `content-encoding` this client asks for and can undo.
///
/// Browsers ask for brotli, 15–20 % smaller than gzip on markup, and `dart:io` asking for
/// gzip alone is a bot signal; zstd is what newer CDNs serve. The native decoders fail a body
/// cut off half-way, where `dart:io`'s gzip returned the half; without the library only gzip
/// is asked for. `deflate` is not: servers disagree whether it is zlib-wrapped.
enum _Encoding {
  gzip('gzip', 1),
  brotli('br', 3),
  zstd('zstd', 4);

  final String token;

  /// See [NativeBridge.main.inflate].
  final int codec;

  const _Encoding(this.token, this.codec);

  /// The encoding [header] names, or `null` — left on the body for the caller to see.
  static _Encoding? of(String? header) => switch (header?.trim().toLowerCase()) {
    'gzip' || 'x-gzip' => _Encoding.gzip,
    'br' => _Encoding.brotli,
    'zstd' => _Encoding.zstd,
    _ => null,
  };
}

/// What a request asks for: the native decoders' encodings only once a request needs them, so
/// a script that sends none never loads the library.
final String _acceptEncoding = [
  for (final encoding in _Encoding.values)
    if (encoding == _Encoding.gzip || NativeBridge.main.isLoaded) encoding.token,
].join(', ');

/// [body] with [encoding] undone; bytes that do not decode, or stop early, are a
/// [ClientException].
Stream<List<int>> _inflated(Stream<List<int>> body, _Encoding encoding, Uri url) =>
    (NativeBridge.main.isLoaded ? NativeBridge.main.inflate(body, encoding.codec) : gzip.decoder.bind(body))
        .handleError(
          (Object e) => throw ClientException('${encoding.token} body: ${(e as FormatException).message}', url),
          test: (e) => e is FormatException,
        );

var _charsetsReady = false;

/// Gives [Response.text] the native library's charsets, and cookies `Clock.current`, the first
/// time a client or a scope is made.
void _charsets() {
  if (_charsetsReady) return;
  _charsetsReady = true;
  MessageInternals.clock = () => Clock.current.now();
  MessageInternals.charsets = (label, bytes) =>
      NativeBridge.main.isLoaded ? NativeBridge.main.decodeText(label, bytes) : null;
}

/// Whether a response has a body to decode: a 204, a 304 or a HEAD answer may name a
/// `content-encoding` and carry no bytes.
bool _hasBody(int status, String method) => status != 204 && status != 304 && method != 'HEAD';
