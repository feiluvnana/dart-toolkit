/// # Images
///
/// An immutable RGBA raster with one-word transforms — `crop`, `fit`,
/// `resize`, `grayscale`, `blur`, `draw` — and codec decode/encode through
/// the native engine (QOI encode is the Dart codec; without the library
/// codecs are `UnsupportedError`). `source.image()` decodes any source;
/// `image.save(File)` writes it back.
library;

export 'src/core/errors.dart';
export 'src/core/pipe.dart';
export 'src/core/traits.dart';
export 'src/image/image.dart';
