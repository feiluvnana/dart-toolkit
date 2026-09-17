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
/// {@category Files}
extension PathArchiveExtensions on Path {
  /// Compresses this directory or file into a zip archive at [destination].
  Future<File> zipTo(String destination) async {
    final targetPath = destination;
    final zipFile = File(targetPath);
    await zipFile.parent.create(recursive: true);
    final encoder = ZipFileEncoder();
    final t = await type();
    if (t == PathType.dir) {
      await encoder.zipDirectory(asDir, filename: targetPath);
    } else {
      encoder.create(targetPath);
      await encoder.addFile(asFile);
      encoder.close();
    }
    return zipFile;
  }

  /// Compresses this directory or file into a zip archive at [destination] synchronously.
  File zipToSync(String destination) {
    final targetPath = destination;
    final zipFile = File(targetPath);
    zipFile.parent.createSync(recursive: true);
    final encoder = ZipFileEncoder();
    final t = typeSync();
    if (t == PathType.dir) {
      encoder.create(targetPath);
      for (final entity in asDir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          final rel = p.relative(entity.path, from: path);
          final bytes = entity.readAsBytesSync();
          encoder.addArchiveFile(ArchiveFile(rel, bytes.length, bytes));
        }
      }
      encoder.close();
    } else {
      encoder.create(targetPath);
      final bytes = asFile.readAsBytesSync();
      encoder.addArchiveFile(ArchiveFile(p.basename(asFile.path), bytes.length, bytes));
      encoder.close();
    }
    return zipFile;
  }

  /// Extracts the archive at this path into [destination].
  Future<Directory> extractTo(String destination) async {
    final destPath = destination;
    final dest = Directory(destPath);
    await dest.create(recursive: true);
    final bytes = await readBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final entity in archive) {
      final outPath = p.join(destPath, entity.name);
      if (entity.isFile) {
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(entity.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
    return dest;
  }

  /// Extracts the archive at this path into [destination] synchronously.
  Directory extractToSync(String destination) {
    final destPath = destination;
    final dest = Directory(destPath);
    dest.createSync(recursive: true);
    final bytes = readBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final entity in archive) {
      final outPath = p.join(destPath, entity.name);
      if (entity.isFile) {
        final outFile = File(outPath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(entity.content as List<int>);
      } else {
        Directory(outPath).createSync(recursive: true);
      }
    }
    return dest;
  }
}
