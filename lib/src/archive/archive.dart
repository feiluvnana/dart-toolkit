/// # Archives
///
/// {@category Files}
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../fs/path.dart';

/// Zip archive operations on [Path].
///
/// Every operation streams: memory is constant in the size of the archive.
///
/// {@category Files}
extension PathArchiveExtensions on Path {
  /// Compresses this directory or file into a zip archive at [destination].
  Future<File> zipTo(String destination) async {
    final zipFile = File(destination);
    await zipFile.parent.create(recursive: true);
    final encoder = ZipFileEncoder();
    if (await type() == PathType.dir) {
      await encoder.zipDirectory(asDir, filename: destination);
    } else {
      encoder.create(destination);
      await encoder.addFile(asFile);
      await encoder.close();
    }
    return zipFile;
  }

  /// Compresses this directory or file into a zip archive at [destination] synchronously.
  File zipToSync(String destination) {
    final zipFile = File(destination);
    zipFile.parent.createSync(recursive: true);
    final encoder = ZipFileEncoder()..create(destination);
    if (typeSync() == PathType.dir) {
      for (final entity in asDir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) encoder.addFileSync(entity, p.relative(entity.path, from: path));
      }
    } else {
      encoder.addFileSync(asFile);
    }
    encoder.closeSync();
    return zipFile;
  }

  /// Extracts the archive at this path into [destination].
  Future<Directory> extractTo(String destination) async {
    final dest = Directory(destination);
    await dest.create(recursive: true);
    await extractFileToDisk(path, destination);
    return dest;
  }

  /// Extracts the archive at this path into [destination] synchronously.
  Directory extractToSync(String destination) {
    final dest = Directory(destination)..createSync(recursive: true);
    final input = InputFileStream(path);
    try {
      final root = p.normalize(p.absolute(destination));
      for (final entry in ZipDecoder().decodeStream(input)) {
        final outPath = p.normalize(p.join(root, entry.name));
        // An entry named `../x` must not land outside [destination].
        if (!p.isWithin(root, outPath)) throw FileSystemException('Archive entry escapes destination', entry.name);
        if (entry.isFile) {
          final out = OutputFileStream(outPath);
          try {
            entry.writeContent(out);
          } finally {
            out.closeSync();
          }
        } else {
          Directory(outPath).createSync(recursive: true);
        }
      }
    } finally {
      input.closeSync();
    }
    return dest;
  }
}
