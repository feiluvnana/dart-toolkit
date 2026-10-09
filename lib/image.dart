/// # Images
///
/// Decoding (JPEG, PNG, WebP, GIF, BMP, TIFF), pure in-memory transforms (resize, crop, colour,
/// filters, watermarks, text), encoding with one [Quality] setting, compression of files, and
/// perceptual hashing. Decoded images are upright: the EXIF orientation is applied.
///
/// ```dart
/// final img = await Image.read('photo.jpg', maxSide: 2048);
/// await img.resize(width: 800).sharpen().save('out.webp', quality: Quality.visual(90));
/// await img.close();
/// await photos.parallelize((p) => p.compress()).show('Compressing');
/// ```
///
/// Transforms run synchronously at native SIMD speed; reading, encoding and compressing are
/// asynchronous, a large image on a worker.
///
/// {@category Image}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'src/core.dart';
import 'src/native.dart';
import 'path.dart';

export 'core.dart';
export 'path.dart';
export 'src/native.dart' show NativeException;

part 'src/image/compress.dart';
part 'src/image/exif.dart';
part 'src/image/image.dart';
part 'src/image/image_info.dart';
part 'src/image/native.dart';
part 'src/image/quality.dart';
part 'src/image/similar.dart';
