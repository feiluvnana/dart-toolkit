import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final tempDir = Path.temp / 'toolkit_file_demo';
  await tempDir.mkdir();

  try {
    final note = tempDir / 'hello.txt';
    await note.writeText('Hello from Dart Toolkit!');
    Logger.ok('Created file at $note (size: ${await note.size()} bytes)');

    final sha = (await note.readBytes()).sha256;
    Logger.info('SHA-256: $sha');

    final zipPath = tempDir / 'archive.zip';
    await tempDir.zipTo(zipPath.path);
    Logger.ok('Zipped directory into $zipPath');
  } finally {
    await tempDir.delete(recursive: true);
    Logger.info('Cleaned up temp files.');
  }
}
