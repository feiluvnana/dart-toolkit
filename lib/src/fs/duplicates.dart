part of '../../path.dart';

// `duplicates` binds the native digest itself, so `path` needs no `hash`.

/// The native code of XXH3, the quick digest of a file's first 4 KiB that rules most out.
const _xxh3 = 19;

/// The native code of BLAKE3, the digest of a whole file that says two are the same: a
/// collision of a non-cryptographic digest could be built, and its answer is often deleted.
const _blake3 = 14, _blake3Length = 32;

typedef _DigestBuf = Int32 Function(Uint32, Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr);
typedef _DigestBufDart = int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int);

final _tkDigest = NativeBridge.main.require().lookupFunction<_DigestBuf, _DigestBufDart>('tk_digest');
final _tkDigestFiles = NativeBridge.main
    .require()
    .lookupFunction<
      Int32 Function(Uint32, Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr, Pointer<Uint8>),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint8>)
    >('tk_digest_files');

/// [PathExtensions.duplicates].
Future<List<List<Path>>> _duplicates(Work work, String dir) async {
  if (!await Directory(dir).exists()) throw FileBridge.notFound(dir, 'Cannot find duplicates in');
  work.step('comparing');
  final groups = await NativeBridge.main.run(work, _duplicatesCall(dir));
  return [
    for (final group in groups) [for (final f in group) Path(f)],
  ];
}

/// What a worker runs to find the duplicates under [dir]: only plain values cross with it.
List<List<String>> Function(NativeProgress, Pointer<Uint8>) _duplicatesCall(String dir) =>
    (_, stop) => _sameBytes(dir, stop);

/// The files under [dir] with the same bytes, grouped, largest first: files sharing a non-zero
/// size and the digest of their first 4 KiB are hashed whole, on every core; same-size files
/// that differ early are never read to the end. Blocks: for a worker.
List<List<String>> _sameBytes(String dir, Pointer<Uint8> stop) {
  final bySize = <int, List<String>>{};
  for (final f in _walkSync(Directory(dir)).whereType<File>()) {
    (bySize[f.lengthSync()] ??= []).add(f.path);
  }
  bySize.remove(0);
  final candidates = <(int, String)>[];
  final head = NativeBridge.main.alloc(4096 + 8);
  try {
    for (final MapEntry(key: size, value: paths) in bySize.entries) {
      if (paths.length < 2) continue;
      if (stop.value != 0) throw const CancelledException();
      final byHead = <int, List<String>>{};
      for (final path in paths) {
        final raf = File(path).openSync();
        final int n;
        try {
          n = raf.readIntoSync(head.asTypedList(4096));
        } finally {
          raf.closeSync();
        }
        _tkDigest(_xxh3, head, n, head + 4096, 8);
        (byHead[ByteData.sublistView((head + 4096).asTypedList(8)).getInt64(0)] ??= []).add(path);
      }
      for (final same in byHead.values) {
        if (same.length > 1) candidates.addAll([for (final p in same) (size, p)]);
      }
    }
  } finally {
    NativeBridge.main.free(head, 4096 + 8);
  }
  if (candidates.isEmpty) return const [];
  final paths = [for (final (_, p) in candidates) p];
  final cap = _blake3Length * paths.length;
  final digests = NativeBridge.main.withText(paths.join('\x00'), (p, n) {
    final out = NativeBridge.main.alloc(cap);
    try {
      if (_tkDigestFiles(_blake3, p, n, out, cap, stop) < 0) {
        if (stop.value != 0) throw const CancelledException();
        final error = NativeBridge.main.lastError();
        // `<path>: <reason>`: the file that failed leads the message.
        final at = error.indexOf(': ');
        final failed = NativeBridge.fileError(error, at < 0 ? '' : error.substring(0, at), 'Cannot read');
        throw failed is FormatException ? FileSystemException('Cannot read: ${failed.message}') : failed;
      }
      return Uint8List.fromList(out.asTypedList(cap));
    } finally {
      NativeBridge.main.free(out, cap);
    }
  });
  final groups = <(int, String), List<String>>{};
  for (final (i, (size, path)) in candidates.indexed) {
    final digest = String.fromCharCodes(Uint8List.sublistView(digests, i * _blake3Length, (i + 1) * _blake3Length));
    (groups[(size, digest)] ??= []).add(path);
  }
  return [
    for (final MapEntry(:value) in groups.entries.toList()..sort((a, b) => b.key.$1.compareTo(a.key.$1)))
      if (value.length > 1) value..sort(),
  ];
}
