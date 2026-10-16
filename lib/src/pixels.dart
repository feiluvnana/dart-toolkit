/// What a `Tui` region needs to draw a picture, so `tui` never loads the
/// image codecs and `image` never loads the `Tui`. `image`'s
/// `image.pixels()` returns one.
library;

/// A grid of 8-bit RGB pixels.
abstract interface class Pixels {
  /// Width in pixels.
  int width();

  /// Height in pixels.
  int height();

  /// The `(r, g, b)` at column [x], row [y].
  (int, int, int) pixel(int x, int y);
}
