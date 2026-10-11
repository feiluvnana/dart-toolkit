# 08: Image Processing

High-performance native image manipulation powered by Rust FFI.

---

## 1. Load, Transform & Save

```dart
// Load, resize preserving aspect ratio, and save
await Image.load('photo.jpg')
  .fit(800, 600)
  .save('thumb.webp');
```

---

## 2. Transformations

```dart
final img = await Image.load('raw.png');

// Crop box: x, y, width, height
final cropped = img.crop(10, 10, 200, 200);

// Resize to exact dimensions
final resized = img.resize(400, 300);

// Scale by factor
final scaled = img.scale(0.5);

// Apply blur
final blurred = img.blur(radius: 5);
```

---

## 3. Metadata Without Full Decode

Fast zero-allocation header inspection:

```dart
final meta = await Image.info('photo.jpg');

print(meta.w);   // width
print(meta.h);   // height
print(meta.fmt); // 'jpeg'
```

---

## 4. Advanced Use Cases

### 4.1 Batch Image Thumbnailing with Worker Pool
Process hundreds of images in parallel across multiple CPU cores without UI stutter:

```dart
void batchThumbnail(Dir srcDir, Dir outDir) async {
  final pool = Pool(8);
  await outDir.make();

  final files = await srcDir.find('*.jpg');
  for (final file in files) {
    pool.run(() async {
      final img = await Image.load(file);
      final outPath = outDir.path / '${file.name}.webp';
      
      await img
        .fit(300, 300)
        .save(outPath.str, quality: 80);
    });
  }

  await pool.wait();
  await pool.close();
}
```

### 4.2 Stream Network Image directly to Processed Avatar
```dart
// Download, crop avatar to square, and write to disk
final resp = await Http.get('https://example.com/profile.png');
final img  = await Image.load(resp);

final size = img.w < img.h ? img.w : img.h;
await img
  .crop(0, 0, size, size)
  .fit(128, 128)
  .save('avatar.webp');
```

### 4.3 Watermarking (Overlaying Images)
```dart
final base  = await Image.load('landscape.jpg');
final logo  = await Image.load('watermark.png');

// Overlay logo at bottom-right corner
base.draw(logo, x: base.w - logo.w - 20, y: base.h - logo.h - 20);
await base.save('branded.jpg');
```
