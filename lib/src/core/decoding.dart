import 'dart:typed_data';

/// A source that knows how its bytes become text: an HTTP body in the charset its
/// `Content-Type` (or the page's `<meta charset>`) declares. The core `text` and `lines`
/// readings ask it; everything else is UTF-8. Package-internal: no topic exports it.
abstract interface class Decoding {
  String decode(Uint8List bytes);
}
