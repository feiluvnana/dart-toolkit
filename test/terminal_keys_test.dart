// Unit tests for the key decoder in lib/src/terminal.dart.
//
// Regression coverage for Console.choose on Windows consoles, where arrows
// and friends arrive as two-byte 0xE0 + scan-code sequences instead of
// CSI/SS3 escapes. A decoder that doesn't know the prefix swallows them as
// "printable" mojibake and the menu never moves.
import 'dart:convert';

import 'package:dart_toolkit/src/terminal.dart';
import 'package:test/test.dart';

/// Decode [bytes] and expect exactly one named key back.
String keyName(List<int> bytes) {
  final r = decodeKeys(bytes);
  expect(r.consumed, bytes.length, reason: 'bytes $bytes');
  expect(r.events, hasLength(1), reason: 'bytes $bytes');
  final event = r.events.single;
  expect(event, isA<TermKey>(), reason: 'bytes $bytes');
  return (event as TermKey).name;
}

void main() {
  group('windows extended keys (0xE0 prefix)', () {
    test('arrows', () {
      expect(keyName([0xe0, 0x48]), 'up');
      expect(keyName([0xe0, 0x50]), 'down');
      expect(keyName([0xe0, 0x4b]), 'left');
      expect(keyName([0xe0, 0x4d]), 'right');
    });

    test('navigation block', () {
      expect(keyName([0xe0, 0x47]), 'home');
      expect(keyName([0xe0, 0x4f]), 'end');
      expect(keyName([0xe0, 0x49]), 'pageup');
      expect(keyName([0xe0, 0x51]), 'pagedown');
      expect(keyName([0xe0, 0x52]), 'insert');
      expect(keyName([0xe0, 0x53]), 'delete');
    });
  });

  group('prefix safety', () {
    test('a split pair across reads is held, not emitted', () {
      final r = decodeKeys([0xe0]);
      expect(r.consumed, 0);
      expect(r.events, isEmpty);
    });

    test('NUL is ctrl+space and never eats the next byte', () {
      expect(keyName([0x00]), 'ctrl+space');
      final r = decodeKeys([0x00, 0x48, 0x61]);
      expect(r.consumed, 3);
      expect(r.events.map((e) => e is TermKey ? e.name : (e as TermType).text), ['ctrl+space', 'Ha']);
    });

    test('real UTF-8 text starting with 0xE0 is not eaten', () {
      // U+0800 (ࠀ) is E0 A0 80; its second byte never matches a scan code.
      final bytes = utf8.encode('aࠀb');
      final r = decodeKeys(bytes);
      expect(r.consumed, bytes.length);
      expect(r.events, hasLength(1));
      final event = r.events.single;
      expect(event, isA<TermType>());
      expect((event as TermType).text, 'aࠀb');
    });
  });

  group('posix sequences still decode', () {
    test('csi arrows and enter', () {
      expect(keyName([0x1b, 0x5b, 0x41]), 'up');
      expect(keyName([0x1b, 0x5b, 0x42]), 'down');
      expect(keyName([0x0d]), 'enter');
    });

    test('printable text stays text', () {
      final r = decodeKeys(utf8.encode('ws'));
      expect(r.events, hasLength(1));
      final event = r.events.single;
      expect(event, isA<TermType>());
      expect((event as TermType).text, 'ws');
    });
  });

  group('sanitisers', () {
    const evil = 'Q\x1b]0;T\x07\x9d52;c;SGk=\x9c\u202etxt\x1b[2J';

    test('plainLabel replaces C0, DEL, C1 and bidi overrides', () {
      expect(plainLabel(evil), 'Q\uFFFD]0;T\uFFFD\uFFFD52;c;SGk=\uFFFD\uFFFDtxt\uFFFD[2J');
      expect(plainLabel('a\nb\x7f'), 'a\uFFFDb\uFFFD');
    });

    test('safeText keeps SGR colour, newlines and tabs, nothing else', () {
      expect(safeText('\x1b[1;32mok\x1b[0m\n\tnext'), '\x1b[1;32mok\x1b[0m\n\tnext');
      expect(safeText(evil), plainLabel(evil));
      expect(safeText('plain'), 'plain');
    });
  });

  group('TerminalCaps', () {
    test('TERM=dumb takes no styling or motion unless forced', () {
      final dumb = TerminalCaps.of({'TERM': 'dumb', 'LANG': 'en_US.UTF-8'}, hasTerminal: true);
      expect((dumb.styled, dumb.animated), (false, false));
      final forced = TerminalCaps.of({'TERM': 'dumb', 'FORCE_COLOR': '1'}, hasTerminal: true);
      expect((forced.styled, forced.animated), (true, false));
      final xterm = TerminalCaps.of({'TERM': 'xterm-256color', 'LANG': 'en_US.UTF-8'}, hasTerminal: true);
      expect((xterm.styled, xterm.animated, xterm.color256, xterm.ascii), (true, true, true, false));
      expect(TerminalCaps.isDumb({'TERM': 'DUMB'}), isTrue);
    });
  });

  test('combining marks, ZWSP and medial jamo take no cell (as wcwidth)', () {
    expect(displayWidth('\u0e2a\u0e27\u0e31\u0e2a\u0e14\u0e35'), 4); // Thai สวัสดี
    expect(displayWidth('\u0928\u092e\u0938\u094d\u0924\u0947'), 4); // Devanagari नमस्ते
    expect(displayWidth('\u05e9\u05b8\u05c1\u05dc\u05d5\u05b9\u05dd'), 4); // Hebrew with points
    expect(displayWidth('a\u200bb'), 2);
    expect(displayWidth('\u1100\u1161'), 2); // decomposed 가
    expect(displayWidth('e\u0301'), 1);
    expect(displayWidth('\u00ad'), 1); // soft hyphen stays visible
  });

  group('kitty, wheel and X10 reports', () {
    List<int> b(String s) => utf8.encode(s);

    test('Caps and Num Lock keep the other modifiers', () {
      expect(keyName(b('\x1b[99;69u')), 'ctrl+c'); // ctrl + caps lock
      expect(keyName(b('\x1b[99;133u')), 'ctrl+c'); // ctrl + num lock
      expect(keyName(b('\x1b[1;67A')), 'alt+up');
    });

    test('keypad and non-ASCII keys decode', () {
      expect(keyName(b('\x1b[57400u')), '1');
      expect(keyName(b('\x1b[57414u')), 'enter');
      expect(keyName(b('\x1b[233;3u')), 'alt+é');
    });

    test('a horizontal wheel scrolls nothing', () {
      expect(decodeKeys(b('\x1b[<66;5;3M')).events, isEmpty);
      expect(decodeKeys(b('\x1b[<64;5;3M')).events.whereType<TermKey>().single.name, 'wheelup');
    });

    test('a legacy X10 click is a click, never typed text', () {
      final r = decodeKeys([0x1b, 0x5b, 0x4d, 0x20, 0x25, 0x23]); // left press at (4, 2)
      expect(r.consumed, 6);
      final click = r.events.single as TermClick;
      expect((click.x, click.y), (4, 2));
      expect(decodeKeys([0x1b, 0x5b, 0x4d, 0x20]).consumed, 0); // split: held
    });
  });
}
