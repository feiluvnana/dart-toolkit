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
      expect(h('.bashrc'), '_.bashrc');
      expect(h('-rf'), '_-rf');
    });
  });

  group('content-disposition', () {
    String? d(String h) => dispositionName(h);

    test('filename* (RFC 8187) wins and decodes its charset', () {
      expect(d("attachment; filename=\"a.txt\"; filename*=UTF-8''na%C3%AFve%20x.txt"), 'naïve x.txt');
      expect(d("attachment; filename*=iso-8859-1'en'caf%E9.txt"), 'café.txt');
      expect(d('attachment; filename*="UTF-8\'\'q%2Eu.txt"'), 'q.u.txt');
      expect(d("attachment; filename*=UTF-8''..%2F..%2Fetc%2Fpasswd"), 'passwd');
      expect(d("attachment; filename*=UTF-8''a%+1%-1%zz.txt"), 'a%+1%-1%zz.txt');
    });

    test('plain filename: quoted, bare, percent runs, absent', () {
      expect(d('inline; filename=report.pdf'), 'report.pdf');
      expect(d("attachment; filename='x y.zip'"), 'x y.zip');
      expect(d('attachment; FILENAME="up.TXT"'), 'up.TXT');
      expect(dispositionName(null), isNull);
      expect(d('attachment'), isNull);
      expect(d('attachment; filename=""'), isNull);
    });

    test('an empty filename* falls back to filename', () {
      expect(d("attachment; filename*=UTF-8''; filename=b.txt"), 'b.txt');
    });

    test('fileName falls back to the URL tail, decoded', () {
      expect(fileName(url: 'https://x/a/b%20c.tar.gz?q=1'), 'b c.tar.gz');
      expect(fileName(url: 'https://x/'), 'download');
    });
  });
}
