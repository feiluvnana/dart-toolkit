/// # Images
///
/// An RGBA raster with one-word transforms — `crop`, `fit`, `resize`,
/// `grayscale`, `blur`, `draw`, `thumbnail` — and codec load/save through the
/// native engine (QOI encode is the Dart codec; without the library codecs
/// are `UnsupportedError`). `Image.load()` doubles as the pipe sink; an image
/// pipes as PNG bytes.
library;

export 'src/image/image.dart';
