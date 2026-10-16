import 'dart:convert';

import 'package:dart_toolkit/src/charset.dart';
import 'package:dart_toolkit/src/names.dart' show isReserved;
import 'package:dart_toolkit/src/origin.dart';
import 'package:test/test.dart';

void main() {
  redactTests();
  charsetTests();
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

    test('P4: every Windows device name is reserved', () {
      for (final n in ['COM0', 'lpt0.log', 'COM\u00b9', 'LPT\u00b3.txt', 'CONIN\$', 'conout\$.x', 'nul .txt', 'Aux']) {
        expect(isReserved(n), isTrue, reason: n);
      }
      for (final n in ['COM10', 'console', 'nul_', 'auxiliary.txt', 'lpt']) {
        expect(isReserved(n), isFalse, reason: n);
      }
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

void redactTests() {
  group('redact', () {
    test('masks exact secret names only (regression: shortcode/keyword/author were masked)', () {
      expect(
        redact('https://u:p@x.com/p?shortcode=ABC&keyword=dart&author=me&access_token=T&API-Key=K&code=C&sig=S'),
        'https://x.com/p?shortcode=ABC&keyword=dart&author=me&access_token=***&API-Key=***&code=***&sig=***',
      );
      expect(redact('https://x.com/?page=2'), 'https://x.com/?page=2');
    });

    test('S9: masks secrets in the fragment and in token-bearing paths', () {
      expect(
        redact('https://app.example/cb#access_token=T&token_type=bearer&state=s'),
        'https://app.example/cb#access_token=***&token_type=bearer&state=s',
      );
      expect(
        redact('https://api.telegram.org/bot123456:AAE-secretBotToken/sendMessage?chat_id=1'),
        'https://api.telegram.org/bot***/sendMessage?chat_id=1',
      );
      expect(redact('https://hooks.slack.com/services/T000/B000/XXXXsecret'), 'https://hooks.slack.com/services/***');
      expect(redact('https://discord.com/api/webhooks/123/tokenSECRET'), 'https://discord.com/api/webhooks/***');
      expect(redact('https://x.com/robots/bot/page#top'), 'https://x.com/robots/bot/page#top');
    });
  });

  group('filename* astral', () {
    test('an emoji survives raw and percent-encoded (regression: raw astral became U+FFFD)', () {
      expect(dispositionName("attachment; filename*=UTF-8''%F0%9F%98%80.txt"), '😀.txt');
      expect(dispositionName("attachment; filename*=UTF-8''😀 x.txt"), '😀 x.txt');
      expect(percentDecode('😀'), utf8.encode('😀'));
    });
  });
}

void charsetTests() {
  group('Charset', () {
    final jsonWithMeta = utf8.encode('{"html": "<meta charset=windows-1252>", "name": "café"}');

    test('JSON is UTF-8 whatever a meta tag says (regression: windows-1252 mojibake)', () {
      expect(Charset.decode(jsonWithMeta, contentType: 'application/json'), contains('café'));
      expect(Charset.decode(jsonWithMeta, contentType: 'application/ld+json; charset=iso-8859-1'), contains('café'));
      expect(Charset.decode(jsonWithMeta, contentType: 'text/plain'), contains('café'));
    });

    test('<meta charset> is sniffed for HTML and untyped bodies only', () {
      final page = [...ascii.encode('<html><meta charset="windows-1252">caf'), 0xE9];
      expect(Charset.decode(page, contentType: 'text/html'), endsWith('café'));
      expect(Charset.decode(page, contentType: 'application/xhtml+xml'), endsWith('café'));
      expect(Charset.decode(page), endsWith('café'));
      expect(Charset.decode(page, contentType: 'text/plain'), endsWith('caf\uFFFD'));
    });

    test('single-byte decoding maps every byte (one table pass)', () {
      final bytes = List.generate(256, (i) => i);
      final text = Charset.decode(bytes, contentType: 'text/plain; charset=windows-1252');
      expect(text.length, 256);
      expect(text.codeUnitAt(0x41), 0x41);
      expect(text.codeUnitAt(0x80), 0x20AC);
      expect(text.codeUnitAt(0xE9), 0xE9);
      final koi = Charset.decode([0xC1, 0x41], contentType: 'text/plain; charset=koi8-r');
      expect(koi, 'аA');
      final chunked = IncrementalDecoder('windows-1252');
      expect(chunked.add([0x80]) + chunked.add([0x41]) + chunked.finish(), '€A');
    });
  });
}
