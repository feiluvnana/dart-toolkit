import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final base = 'Key BOX -for two decades- (2019)'.path;
  await for (final dir in base.dirs(recursive: true).where((d) => d.name == 'flac')) {
    await dir.delete(recursive: true);
    Logger.ok('Deleted: $dir');
  }
}
