part of '../../archive.dart';

/// Zip archive operations on [Path].
///
/// Every operation streams: memory is constant in the size of the archive. Compression is
/// the platform's zlib through `dart:io`; the container is written and read here.
///
/// {@category Files}
extension PathArchiveExtensions on Path {
  /// Compresses this directory or file into a zip archive at [destination].
  ///
  /// Entries are relative to this path; a file becomes one entry named after itself.
  /// [level] is zlib's, 0–9. Symbolic links are skipped.
  Future<File> zipTo(String destination, {int level = 6}) => _zip(this, destination, level);

  /// Compresses this directory or file into a zip archive at [destination] synchronously.
  File zipToSync(String destination, {int level = 6}) => _zipSync(this, destination, level);

  /// Extracts the archive at this path into [destination].
  ///
  /// Throws [FormatException] on a corrupt entry or a CRC mismatch, [UnsupportedError] on
  /// an encrypted entry or an unknown compression method, and [FileSystemException] on an
  /// entry that would land outside [destination].
  Future<Directory> extractTo(String destination) async {
    final dest = Directory(destination);
    await dest.create(recursive: true);
    final root = p.normalize(p.absolute(destination));
    final reader = await _ZipReader.open(asFile);
    try {
      for (final entry in await reader.entries()) {
        final out = _target(root, entry);
        if (entry.isDir) {
          await Directory(out).create(recursive: true);
        } else {
          await reader.extract(entry, File(out), asFile);
        }
      }
    } finally {
      await reader.close();
    }
    return dest;
  }

  /// Extracts the archive at this path into [destination] synchronously; see [extractTo].
  Directory extractToSync(String destination) {
    final dest = Directory(destination)..createSync(recursive: true);
    final root = p.normalize(p.absolute(destination));
    final reader = _ZipReader.openSync(asFile);
    try {
      for (final entry in reader.entriesSync()) {
        final out = _target(root, entry);
        if (entry.isDir) {
          Directory(out).createSync(recursive: true);
        } else {
          reader.extractSync(entry, File(out));
        }
      }
    } finally {
      reader.closeSync();
    }
    return dest;
  }

  /// The entries of the archive at this path, from its central directory, without extracting.
  Future<List<ZipEntry>> zipEntries() async {
    final reader = await _ZipReader.open(asFile);
    try {
      return await reader.entries();
    } finally {
      await reader.close();
    }
  }

  /// The entries of the archive at this path, synchronously.
  List<ZipEntry> zipEntriesSync() {
    final reader = _ZipReader.openSync(asFile);
    try {
      return reader.entriesSync();
    } finally {
      reader.closeSync();
    }
  }
}
