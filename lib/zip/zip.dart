/// # Zip Domain (`zip.*`)
///
/// Pack a folder, unpack an archive, look inside one without unpacking it, and
/// squeeze bytes. The format comes from the file name — `.zip`, `.tar`,
/// `.tar.gz`, `.tgz` and `.tar.bz2` are all understood — so one pair of calls
/// covers every archive a script meets.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../src/fs.dart';

// ============================================================================
// ZIP DOMAIN (zip.*)
// ============================================================================

/// The archive formats [ZipAccessor] reads and writes.
enum Format {
  /// A `.zip` container.
  zip,

  /// An uncompressed `.tar` container.
  tar,

  /// A gzip-compressed tar, `.tar.gz` or `.tgz`.
  gz,

  /// A bzip2-compressed tar, `.tar.bz2` or `.tbz`.
  bz2;

  /// The format [path]'s name implies, defaulting to [Format.zip].
  ///
  /// ```dart
  /// Format.of('backup.tar.gz'); // Format.gz
  /// ```
  static Format of(String path) {
    final name = path.toLowerCase();
    if (name.endsWith('.tar.gz') || name.endsWith('.tgz')) return Format.gz;
    if (name.endsWith('.tar.bz2') || name.endsWith('.tbz')) return Format.bz2;
    if (name.endsWith('.tar')) return Format.tar;
    return Format.zip;
  }
}

/// One entry inside an archive.
class Entry {
  /// The entry's path within the archive, using forward slashes.
  final String name;

  /// Uncompressed size in bytes; zero for a directory.
  final int size;

  /// Whether this entry is a directory rather than a file.
  final bool folder;

  /// Creates an entry description.
  const Entry(this.name, this.size, {this.folder = false});

  @override
  String toString() => folder ? '$name/' : '$name ($size bytes)';
}

/// The `zip` domain: packing, unpacking and inspecting archives.
const ZipAccessor zip = ZipAccessor();

/// Entry point for archives, reachable as [zip].
///
/// ```dart
/// await zip.pack('site', 'site.zip');
/// for (final entry in await zip.list('site.zip')) print(entry.name);
/// await zip.unpack('site.zip', 'restored');
/// ```
class ZipAccessor {
  /// Creates the accessor. Prefer the shared [zip] instance.
  const ZipAccessor();

  /// Packs [source] — a file or a whole folder — into the archive at [dest].
  ///
  /// The format follows [dest]'s name; pass [format] to override it. Paths
  /// inside the archive are relative to [source], so unpacking recreates the
  /// tree without the leading directories. Existing archives are replaced, and
  /// the write is atomic.
  Future<File> pack(String source, String dest, {Format? format}) async {
    final archive = Archive();
    final type = FileSystemEntity.typeSync(source);

    if (type == FileSystemEntityType.directory) {
      final root = Directory(source);
      await for (final entity in root.list(recursive: true)) {
        final name = p
            .relative(entity.path, from: source)
            .replaceAll(r'\', '/');
        if (entity is File) {
          archive.add(ArchiveFile.bytes(name, await entity.readAsBytes()));
        } else if (entity is Directory) {
          archive.add(ArchiveFile.directory(name));
        }
      }
    } else if (type == FileSystemEntityType.file) {
      final file = File(source);
      archive.add(
        ArchiveFile.bytes(p.basename(source), await file.readAsBytes()),
      );
    } else {
      throw FileSystemException('Nothing to pack', source);
    }

    return Fs.save(dest, _encode(archive, format ?? Format.of(dest)));
  }

  /// Packs [files] — a map of archive path to contents — into [dest].
  ///
  /// For building an archive from data that never touched the disk.
  ///
  /// ```dart
  /// await zip.bundle('out.zip', {'notes.txt': utf8.encode('hi')});
  /// ```
  Future<File> bundle(
    String dest,
    Map<String, List<int>> files, {
    Format? format,
  }) async {
    final archive = Archive();
    for (final entry in files.entries) {
      archive.add(ArchiveFile.bytes(entry.key, entry.value));
    }
    return Fs.save(dest, _encode(archive, format ?? Format.of(dest)));
  }

  /// Unpacks the archive at [source] into the folder [dest].
  ///
  /// Returns the files written. Entries that would escape [dest] — a `..`
  /// segment or an absolute path, the "zip slip" attack — are skipped rather
  /// than trusted, since an archive is usually something you downloaded.
  Future<List<File>> unpack(
    String source,
    String dest, {
    Format? format,
  }) async {
    final archive = _decode(
      await File(source).readAsBytes(),
      format ?? Format.of(source),
    );
    final root = p.normalize(p.absolute(dest));
    final written = <File>[];

    for (final entry in archive) {
      final target = p.normalize(p.join(root, entry.name));
      if (!p.isWithin(root, target)) continue;
      if (!entry.isFile) {
        await Directory(target).create(recursive: true);
        continue;
      }
      await Directory(p.dirname(target)).create(recursive: true);
      final file = File(target);
      await file.writeAsBytes(entry.readBytes() ?? const <int>[]);
      written.add(file);
    }
    return written;
  }

  /// Lists what the archive at [source] holds, without unpacking it.
  Future<List<Entry>> list(String source, {Format? format}) async {
    final archive = _decode(
      await File(source).readAsBytes(),
      format ?? Format.of(source),
    );
    return [
      for (final entry in archive)
        Entry(entry.name, entry.size, folder: !entry.isFile),
    ];
  }

  /// Reads one entry's bytes out of the archive at [source].
  ///
  /// Returns `null` when [name] is not in the archive.
  Future<List<int>?> read(String source, String name, {Format? format}) async {
    final archive = _decode(
      await File(source).readAsBytes(),
      format ?? Format.of(source),
    );
    return archive.find(name)?.readBytes();
  }

  /// Gzip-compresses [bytes].
  List<int> deflate(List<int> bytes) => GZipEncoder().encodeBytes(bytes);

  /// Reverses [deflate].
  List<int> inflate(List<int> bytes) =>
      GZipDecoder().decodeBytes(_asBytes(bytes));

  static Uint8List _asBytes(List<int> bytes) =>
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  static List<int> _encode(Archive archive, Format format) => switch (format) {
    Format.zip => ZipEncoder().encode(archive),
    Format.tar => TarEncoder().encode(archive),
    Format.gz => GZipEncoder().encodeBytes(TarEncoder().encode(archive)),
    Format.bz2 => BZip2Encoder().encode(TarEncoder().encode(archive)),
  };

  static Archive _decode(List<int> bytes, Format format) {
    final raw = _asBytes(bytes);
    return switch (format) {
      Format.zip => ZipDecoder().decodeBytes(raw),
      Format.tar => TarDecoder().decodeBytes(raw),
      Format.gz => TarDecoder().decodeBytes(GZipDecoder().decodeBytes(raw)),
      Format.bz2 => TarDecoder().decodeBytes(
        _asBytes(BZip2Decoder().decodeBytes(raw)),
      ),
    };
  }
}
