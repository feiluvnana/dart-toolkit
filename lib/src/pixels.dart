/// What a `Tui` region needs to draw a picture, so `tui` never loads the
/// image codecs and `image` never loads the `Tui`. `image`'s Image
/// implements it.
library;

/// A grid of 8-bit RGB pixels.
abstract interface class Pixels {
  int width();
  int height();
  (int, int, int) pixel(int x, int y);
}
