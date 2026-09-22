part of '../../http.dart';

/// A `content-encoding` this client asks for and can undo.
///
/// `dart:io` asks for `gzip` and nothing else, which is both slower and a thing to be
/// recognised by: every browser on the web asks for brotli, and brotli is 15–20% smaller than
/// gzip on markup — a page at a time, that is the difference between a crawl and a shorter
/// one. zstd is what the CDNs that moved on from brotli serve.
///
/// gzip is `dart:io`'s own decoder; brotli and zstd are the native library's, so a program
/// without it asks for neither and nothing about it changes. `deflate` is not asked for: what
/// a server means by it is zlib-wrapped in the specification and raw about half the time in
/// practice, and a codec that cannot be read without guessing is not worth one more token in
/// a header.
enum _Encoding {
  gzip('gzip', 1),
  brotli('br', 3),
  zstd('zstd', 4);

  /// What the header calls it.
  final String token;

  /// What the native library calls it; see [NativeBridge.inflate].
  final int codec;

  const _Encoding(this.token, this.codec);

  /// The encoding [header] names, or `null` for one that was not asked for and cannot be
  /// undone — which is left on the body for the caller to see.
  static _Encoding? of(String? header) => switch (header?.trim().toLowerCase()) {
    'gzip' || 'x-gzip' => _Encoding.gzip,
    'br' => _Encoding.brotli,
    'zstd' => _Encoding.zstd,
    _ => null,
  };
}

/// What this client tells a server it can read — asked of the native library once.
final String _acceptEncoding = [
  for (final encoding in _Encoding.values)
    if (encoding == _Encoding.gzip || Native.isAvailable) encoding.token,
].join(', ');

/// [body] with [encoding] undone as it arrives.
Stream<List<int>> _inflated(Stream<List<int>> body, _Encoding encoding) =>
    encoding == _Encoding.gzip ? gzip.decoder.bind(body) : NativeBridge.inflate(body, encoding.codec);

/// Whether a response with this status and method has a body worth decoding.
///
/// A 204 or a 304 can carry the `content-encoding` its entity would have had and no bytes at
/// all, and so can the answer to a HEAD; handing an empty stream to a decoder is an error
/// about nothing. A 206 is a slice of an encoded stream rather than an encoded stream, so it
/// is passed through as it came.
bool _hasBody(int status, String method) => status != 204 && status != 304 && status != 206 && method != 'HEAD';
