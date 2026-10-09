part of '../../image.dart';

/// Finding the same picture among many files.
///
/// {@category Image}
extension PathsImageExtensions on Iterable<Path> {
  /// Groups of these image files that show the same picture (re-encodes, resizes, light crops of
  /// one shot), by perceptual hash: [distance] is the most of the 64 bits two hashes may differ
  /// by (6 holds a re-encode). Each group is two or more, best copy first: most pixels, then
  /// lossless (PNG, TIFF, BMP) before the highest JPEG [ImageInfo.quality], then the largest
  /// file. A file that does not decode is left out. Reports the files hashed; byte-identical
  /// copies are `dir.duplicates()`'s.
  ///
  /// ```dart
  /// final groups = await dir.files(only: '**/*.{jpg,png}').toList().then((f) => f.similar()).show('Hashing');
  /// ```
  Task<List<List<Path>>> similar({int distance = 6}) {
    _within(distance, 0, 64, 'distance');
    final paths = [...this];
    final abs = [for (final p in paths) File(p).absolute.path];
    return TaskInternals.start(paths, '${paths.length} images', (work) async {
      if (paths.isEmpty) return const [];
      final (hashes, ok) = await NativeBridge.main.run(
        work,
        _hashCall(abs),
        onProgress: (r) => work.amount(r.completed, total: r.total, unit: Unit.items),
      );
      final groups = _group(hashes, ok, distance);
      // A lossless copy beats any JPEG; a JPEG ranks by its estimated quality.
      int rank(ImageInfo? i) => switch (i?.format) {
        ImageFormat.png || ImageFormat.bmp || ImageFormat.tiff => 101,
        null => -1,
        _ => i!.quality ?? 0,
      };
      return [
        for (final members in groups)
          [
            for (final (path, _, _)
                in [
                  for (final i in members)
                    (
                      paths[i],
                      await ImageInfo.read(paths[i]).then<ImageInfo?>((v) => v, onError: (Object _) => null),
                      await File(paths[i]).length(),
                    ),
                ]..sort((a, b) {
                  final byPixels = ((b.$2?.width ?? 0) * (b.$2?.height ?? 0)).compareTo(
                    (a.$2?.width ?? 0) * (a.$2?.height ?? 0),
                  );
                  if (byPixels != 0) return byPixels;
                  final byQuality = rank(b.$2).compareTo(rank(a.$2));
                  return byQuality != 0 ? byQuality : b.$3.compareTo(a.$3);
                }))
              path,
          ],
      ];
    });
  }
}

/// How many files one native call hashes: between calls the worker reports and checks the stop.
const _hashBatch = 32;

/// The worker's call for [PathsImageExtensions.similar]: every file's pHash, and whether it
/// decoded. Top level, so the worker is sent only [paths].
(List<int>, List<bool>) Function(NativeProgress, Pointer<Uint8>) _hashCall(List<String> paths) => (progress, stop) {
  final report = progress == nullptr
      ? null
      : progress.asFunction<void Function(int, int, int, int, Pointer<Uint8>, int)>();
  final hashes = <int>[], ok = <bool>[];
  for (var first = 0; first < paths.length; first += _hashBatch) {
    // The caller's stop: it reads any failure then as its cancel.
    if (stop.value != 0) throw StateError('stopped');
    final batch = paths.sublist(first, (first + _hashBatch).clamp(0, paths.length));
    final n = batch.length;
    final out = NativeBridge.main.alloc(8 * n).cast<Uint64>();
    final flags = NativeBridge.main.alloc(n);
    try {
      final done = NativeBridge.main.withText(
        batch.join('\x00'),
        (p, len) => _ImageNative.phashFiles(p, len, out, flags, n),
      );
      if (done != n) throw NativeException('hash images', NativeBridge.main.lastError());
      for (var i = 0; i < n; i++) {
        hashes.add(out[i]);
        ok.add(flags[i] == 1);
      }
    } finally {
      NativeBridge.main.free(out.cast(), 8 * n);
      NativeBridge.main.free(flags, n);
    }
    report?.call(hashes.length, paths.length, 0, 0, nullptr, 0);
  }
  return (hashes, ok);
};

/// The indices of [hashes] in groups of two or more within [distance] bits, by union-find;
/// those not [ok] are left out.
List<List<int>> _group(List<int> hashes, List<bool> ok, int distance) {
  final n = hashes.length;
  final parent = List<int>.generate(n, (i) => i);
  int root(int i) {
    while (parent[i] != i) {
      i = parent[i] = parent[parent[i]];
    }
    return i;
  }

  void near(int a, int b) {
    if (PerceptualHash(hashes[a]).distance(PerceptualHash(hashes[b])) <= distance) parent[root(a)] = root(b);
  }

  if (distance <= 7) {
    // Two hashes within 7 bits agree on at least one of their 8 bytes, so only pairs sharing a
    // byte at the same place are compared.
    final buckets = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      if (!ok[i]) continue;
      for (var b = 0; b < 8; b++) {
        (buckets[b << 8 | (hashes[i] >>> (8 * b)) & 0xFF] ??= []).add(i);
      }
    }
    for (final bucket in buckets.values) {
      for (var x = 0; x < bucket.length; x++) {
        for (var y = x + 1; y < bucket.length; y++) {
          near(bucket[x], bucket[y]);
        }
      }
    }
  } else {
    for (var a = 0; a < n; a++) {
      for (var b = a + 1; b < n; b++) {
        if (ok[a] && ok[b]) near(a, b);
      }
    }
  }
  final groups = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    if (ok[i]) (groups[root(i)] ??= []).add(i);
  }
  return [
    for (final g in groups.values)
      if (g.length > 1) g,
  ];
}
