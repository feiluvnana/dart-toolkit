import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  const baseFolderName = 'Key BOX -for two decades- (2019)';
  final base = baseFolderName.path;

  if (!await base.exist()) {
    Logger.warn('Directory "$baseFolderName" not found.');
    return;
  }

  var deletedCount = 0;
  await for (final dir in base.dirs(recursive: true).where((d) => d.name == 'flac')) {
    await dir.delete(recursive: true);
    Logger.ok('Deleted: $dir');
    deletedCount++;
  }

  stdout.writeln();
  if (deletedCount > 0) {
    Logger.ok('Successfully deleted $deletedCount "flac" directories.');
  } else {
    Logger.info('No "flac" directories found to delete.');
  }
}
