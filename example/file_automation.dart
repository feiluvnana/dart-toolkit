import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/hash.dart';

void main() async {
  final tempDir = Path.temp / 'toolkit_file_demo';
  await tempDir.mkdir();

  try {
    // A scraped or user-supplied name goes through .filename, never straight into a path.
    final note = tempDir / 'notes: draft/v1.txt'.filename;
    await note.writeText('Hello from Dart Toolkit!');
    Logger.ok('Created file at $note (size: ${await note.size()} bytes)');
    Logger.info('One component, whatever the input: ${note.name}');

    final sha = await note.sha256();
    Logger.info('SHA-256: $sha');

    // The archive must live outside the directory being zipped.
    final zipPath = Path.temp / 'toolkit_file_demo.zip';
    await tempDir.zipTo(zipPath);
    Logger.ok('Zipped directory into $zipPath (${await zipPath.size()} bytes)');
    await zipPath.delete();
  } finally {
    await tempDir.delete(recursive: true);
    Logger.info('Cleaned up temp files.');
  }
}
