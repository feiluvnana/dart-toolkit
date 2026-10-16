import 'package:dart_toolkit/src/charset.dart';
import 'package:test/test.dart';

/// Every text from Python's codecs, as hex: multi-byte leads, half-width
/// kana (EUC-JP 0x8E), CP949 extensions, GB18030 four-byte sequences,
/// UTF-16 surrogate pairs and a four-byte UTF-8 emoji.
const _samples = [
  ('shift_jis', '日本語テスト ｱｲｳ abc ①', '93fa967b8cea83658358836720b1b2b320616263208740'),
  ('euc-jp', '日本語テスト ｱｲｳ abc', 'c6fccbdcb8eca5c6a5b9a5c8208eb18eb28eb320616263'),
  ('euc-kr', '한국어 테스트 똠방각하 abc', 'c7d1b1b9beee20c5d7bdbac6ae208c63b9e6b0a2c7cf20616263'),
  ('gb18030', '中文测试 abc € 𠀀', 'd6d0cec4b2e2cad42061626320a2e32095328236'),
  ('big5', '中文測試 abc 繁體', 'a4a4a4e5b4fab8d52061626320c163c5e9'),
  ('utf-16le', 'héllo 😀 世界', '6800e9006c006c006f0020003dd800de2000164e4c75'),
  ('utf-16be', 'héllo 😀 世界', '006800e9006c006c006f0020d83dde0000204e16754c'),
  ('utf-8', 'héllo 😀 世界 ﬀ', '68c3a96c6c6f20f09f988020e4b896e7958c20efac80'),
];

List<int> _hex(String hex) => [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];

String _chunked(String name, List<List<int>> chunks) {
  final d = IncrementalDecoder(name);
  return chunks.map(d.add).join() + d.finish();
}

void main() {
  group('IncrementalDecoder', () {
    for (final (name, text, hex) in _samples) {
      final bytes = _hex(hex);
      // A stray byte, a lone lead mid-text and a lead cut at the end: the
      // U+FFFD placement must not depend on where the chunks split either.
      final broken = [...bytes, 0xFF, 0x20, 0x81, 0x41, bytes.first];

      test('$name decodes the same however the bytes are split', () {
        expect(Charset.decode(bytes, contentType: 'text/plain; charset=$name'), text);
        for (final input in [bytes, broken]) {
          final whole = _chunked(name, [input]);
          if (identical(input, bytes)) expect(whole, text);
          for (var i = 0; i <= input.length; i++) {
            expect(_chunked(name, [input.sublist(0, i), input.sublist(i)]), whole, reason: 'split at $i');
            for (var j = i; j <= input.length; j++) {
              expect(
                _chunked(name, [input.sublist(0, i), input.sublist(i, j), input.sublist(j)]),
                whole,
                reason: 'split at $i and $j',
              );
            }
          }
          expect(
            _chunked(name, [
              for (final b in input) [b],
            ]),
            whole,
            reason: 'one byte a chunk',
          );
        }
      });
    }
  });
}
