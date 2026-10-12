import 'dart:typed_data';

/// How a source's bytes become text when they may not be UTF-8: an HTTP body in the charset
/// its `Content-Type` (or the page's `<meta charset>`) declares. Package-internal: http
/// registers one per response and request in [textCodecs]; core's `text` and `lines` look it
/// up. No topic exports it, so nothing shows on the public types.
final class TextCodec {
  const TextCodec(this.decode, this.streamsUtf8);

  /// The whole body as text.
  final String Function(Uint8List bytes) decode;

  /// Whether the body is UTF-8 (or declares nothing), so `lines` can stream it through
  /// `utf8.decoder`. Asked once the source's reader is open, when the headers are known.
  final bool Function() streamsUtf8;
}

/// The codec of each source that has one (HTTP responses and requests).
final textCodecs = Expando<TextCodec>('text codec');

/// Where each source's bytes come from, for links to resolve against (an HTTP response's
/// final URL, a page's): asked after the body is read. Package-internal, like [textCodecs].
final sourceUrls = Expando<String? Function()>('source url');
