// Unit tests for the key decoder in lib/src/terminal.dart.
//
// Regression coverage for Console.choose on Windows consoles, where arrows
// and friends arrive as two-byte 0xE0/0x00 + scan-code sequences instead of
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

    test('navigation also arrives under the 0x00 prefix', () {
      expect(keyName([0x00, 0x48]), 'up');
      expect(keyName([0x00, 0x50]), 'down');
      expect(keyName([0x00, 0x47]), 'home');
      expect(keyName([0x00, 0x4f]), 'end');
    });
  });

  group('windows function keys (0x00 prefix)', () {
    test('F1-F10', () {
      const expected = {
        0x3b: 'f1',
        0x3c: 'f2',
        0x3d: 'f3',
        0x3e: 'f4',
        0x3f: 'f5',
        0x40: 'f6',
        0x41: 'f7',
        0x42: 'f8',
        0x43: 'f9',
        0x44: 'f10',
      };
      for (final entry in expected.entries) {
        expect(keyName([0x00, entry.key]), entry.value);
      }
    });

    test('F11-F12', () {
      expect(keyName([0x00, 0x85]), 'f11');
      expect(keyName([0x00, 0x86]), 'f12');
    });
  });

  group('prefix safety', () {
    test('a split pair across reads is held, not emitted', () {
      for (final prefix in [0xe0, 0x00]) {
        final r = decodeKeys([prefix]);
        expect(r.consumed, 0);
        expect(r.events, isEmpty);
      }
    });

    test('an unknown 0x00 pair is skipped silently', () {
      // Alt+A scan code: not a key we name, and never valid UTF-8 either.
      final r = decodeKeys([0x00, 0x1e]);
      expect(r.consumed, 2);
      expect(r.events, isEmpty);
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

    test('an F-code under the 0xE0 prefix is not a key', () {
      expect(windowsKey(0xe0, 0x3b), isNull);
      expect(windowsKey(0x00, 0x3b), 'f1');
      expect(windowsKey(0xe0, 0x00), isNull);
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
}
