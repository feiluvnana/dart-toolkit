import 'package:dart_toolkit/image.dart';
import 'package:test/test.dart';

void main() {
  test('Compression.text() says what happened, in one wording for every script', () {
    expect(const Compressed(2831155, 1677722).text(), '1.6 MB (compressed from 2.7 MB, -41%)');
    expect(const Kept(KeptReason.notSmaller).text(), 'kept: re-encoding would not make it smaller');
    expect(KeptReason.lossy.text(), 're-encoding would lose something');
  });
}
