import 'dart:io';

import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/src/media.dart' as media;
import 'package:test/test.dart';

void main() {
  test('Compression.text() says what happened, in one wording for every script', () async {
    final dir = await Directory.systemTemp.createTemp('compression');
    addTearDown(() => dir.delete(recursive: true));
    final (old, newer) = (File('${dir.path}/a'), File('${dir.path}/b'));
    await old.writeAsBytes(List.filled(2831155, 0));
    await newer.writeAsBytes(List.filled(1677722, 0));
    final saved = await media.replaceIfSmaller(old.path, newer.path);
    expect(saved.text(), '1.6 MB (compressed from 2.7 MB, -41%)');
    expect(media.kept(KeptReason.notSmaller).text(), 'kept: re-encoding would not make it smaller');
    expect(KeptReason.lossy.text(), 're-encoding would lose something');
  });
}
