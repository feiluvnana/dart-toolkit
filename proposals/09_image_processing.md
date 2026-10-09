# Module Proposal 09: Image Processing (`lib/image.dart`)

## 1. Overview & Vision

The Image Processing module provides high-speed native image manipulation (JPEG, PNG, WebP, GIF, BMP, TIFF), upright EXIF orientation handling, non-destructive transforms, color adjustments, and optimized format encoding.

### Core Problems in the Existing API
1. **Manual Resource Management**: Because decoded images use native memory handles via FFI, forgetting to call `await img.close()` leads to native memory leaks.
2. **Intermediate Variable Pollution**: Multi-step image transformation pipelines require declaring intermediate variables and tracking multiple `close()` calls.
3. **Format Conversion Ceremony**: Converting formats requires manual `Quality` configuration and file writing steps.

---

## 2. Detailed Before vs After Comparison

### 2.1 Auto-Disposed Image Pipeline

#### Before:
```dart
final img = await Image.read('photo.jpg', maxSide: 2048);
try {
  final resized = img.resize(width: 800, height: 600);
  final cropped = resized.cropAspect(16 / 9);
  final filtered = cropped.sharpen().adjust(contrast: 1.1);
  await filtered.save('out.webp', quality: Quality.visual(90));
} finally {
  await img.close();
}
```

#### After (Proposed):
```dart
// 1. Scoped pipeline with guaranteed automatic memory disposal
await Image.pipeline('photo.jpg', (img) => img
    .resize(width: 800, height: 600)
    .cropAspect(16 / 9)
    .sharpen()
    .adjust(contrast: 1.1)
    .toWebp(quality: 90)
    .save('out.webp'),
);

// 2. Direct single-expression thumbnail generation on Path
await Path('photo.jpg').resizeImage(
  width: 300,
  height: 300,
  fit: BoxFit.cover,
  saveTo: 'thumb.webp',
);
```

---

### 2.2 Instant Format Converters

#### Before:
```dart
final img = await Image.read('banner.png');
try {
  final webpBytes = await img.encode(Format.webp, quality: Quality.visual(85));
  await File('banner.webp').writeAsBytes(webpBytes);
} finally {
  await img.close();
}
```

#### After (Proposed):
```dart
// Direct format conversion methods
await Image.pipeline('banner.png', (img) => img.toWebp(quality: 85).save('banner.webp'));
await Image.pipeline('banner.png', (img) => img.toJpeg(quality: 90).save('banner.jpg'));
await Image.pipeline('banner.png', (img) => img.toPng().save('banner_clean.png'));
```

---

### 2.3 Image Metadata & EXIF Inspection

#### Before:
```dart
final info = await ImageInfo.read('photo.jpg');
final dims = (info.width, info.height);
```

#### After (Proposed):
```dart
// Fast header-only dimensions reading without full pixel decode
final (width, height) = await Path('photo.jpg').imageDimensions;
final exifData = await Path('photo.jpg').readExif();
print('Camera: ${exifData.model}, Date: ${exifData.dateTime}');
```

---

## 3. What is Better vs Old API

| Feature | Old API | Proposed New API | Impact |
|---|---|---|---|
| **Memory Safety** | Manual `img.close()` in `finally` | Scoped `Image.pipeline()` | **Zero native leaks**, automatic disposal |
| **Pipeline Flow** | Multi-variable assignments | Fluent method chaining | Clean, readable transformations |
| **Format Conversion** | Verbose `Quality` objects | `.toWebp()`, `.toJpeg()`, `.toPng()` | Instant format export |
| **Dimension Checks** | Multi-class setup | `path.imageDimensions` | Instant, zero-decode metadata reads |

---

## 4. Trade-Offs & Backward Compatibility

### Trade-Offs:
- `Image.pipeline()` takes ownership of the loaded handle and closes all intermediate handles when the block finishes.
  - *Recommendation*: If an image instance must be held across multiple long-lived operations, the manual `Image.read()` constructor remains available.

### Backward Compatibility:
- 100% backward compatible. The underlying `Image`, `Quality`, `Exif`, and `NativeBridge` implementations remain completely supported.
