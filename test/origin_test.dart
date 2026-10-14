import 'package:dart_toolkit/src/origin.dart';
import 'package:test/test.dart';

void main() {
  group('fileName is portable', () {
    test('never returns .. or empty', () {
      expect(fileName(url: 'http://x/a%2F..'), 'download');
      expect(fileName(url: 'http://x/f', contentDisposition: 'attachment; filename=".."'), 'f');
    });

    test('reserved characters and device names', () {
      String h(String n) => fileName(url: 'http://x/f', contentDisposition: 'attachment; filename="$n"');
      expect(h('report 12:30.pdf'), 'report 12_30.pdf');
      expect(h('what?.html'), 'what_.html');
      expect(h('a|b'), 'a_b');
      expect(h('CON.txt'), '_CON.txt');
      expect(h('name.'), 'name');
      expect(h('../../etc/passwd'), 'passwd');
      expect(h('plain.txt'), 'plain.txt');
    });
  });
}
