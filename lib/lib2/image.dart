/// # Images
///
/// An RGBA raster with one-word transforms — `crop`, `fit`, `resize`,
/// `grayscale`, `blur`, `draw`, `thumbnail` — and codec load/save: PNG/QOI
/// pure Dart, JPEG/GIF/WebP/BMP natively (else `UnsupportedError`).
/// `Image.load()` doubles as the pipe sink; an image pipes as PNG bytes.
library;

export 'src/image/image.dart';
