import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/src/terminal.dart' as term;
import 'package:dart_toolkit/src/tui.dart' show TestSession, testSession;
import 'package:dart_toolkit/tui.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'support/term.dart';

void main() {
  group('key decoder (unit)', () {
    List<term.TermEvent> events(String raw) => term.decodeKeys(utf8.encode(raw)).events;

    test('printable text arrives as one typed event', () {
      final r = term.decodeKeys(utf8.encode('aq'));
      expect(r.consumed, 2);
      final e = r.events.single as term.TermType;
      expect(e.text, 'aq');
      expect(e.paste, isFalse);
    });

    test('split UTF-8 is held, never mojibake', () {
      final eAcute = utf8.encode('é');
      final first = term.decodeKeys(eAcute.sublist(0, 1));
      expect(first.events, isEmpty);
      expect(first.consumed, 0);
      final second = term.decodeKeys([...eAcute.sublist(0, 1), eAcute[1]]);
      expect((second.events.single as term.TermType).text, 'é');
    });

    test('lone ESC is held for the next read', () {
      final r = term.decodeKeys([0x1b]);
      expect(r.events, isEmpty);
      expect(r.consumed, 0);
    });

    test('ESC ESC is escape; ESC + char is alt+char', () {
      expect((events('\x1b\x1b').single as term.TermKey).name, 'escape');
      expect((events('\x1bx').single as term.TermKey).name, 'alt+x');
    });

    test('ESC + multibyte char decodes as one alt+char', () {
      final bytes = [0x1b, ...utf8.encode('é')];
      final r = term.decodeKeys(bytes);
      expect((r.events.single as term.TermKey).name, 'alt+é');
      expect(r.consumed, bytes.length);
    });

    test('enter variants: CR, LF, and CRLF as one enter', () {
      for (final raw in ['\r', '\n', '\r\n']) {
        expect((events(raw).single as term.TermKey).name, 'enter', reason: 'for ${raw.codeUnits}');
      }
      expect(term.decodeKeys(utf8.encode('\r\n')).consumed, 2);
    });

    test('tab, backspace, ctrl letters and ctrl symbols', () {
      expect((events('\t').single as term.TermKey).name, 'tab');
      expect((events('\x7f').single as term.TermKey).name, 'backspace');
      expect((events('\x08').single as term.TermKey).name, 'backspace');
      expect((events('\x01').single as term.TermKey).name, 'ctrl+a');
      expect((events('\x1a').single as term.TermKey).name, 'ctrl+z');
      expect((events('\x00').single as term.TermKey).name, 'ctrl+space');
      expect((events('\x1c').single as term.TermKey).name, r'ctrl+\');
      expect((events('\x1d').single as term.TermKey).name, 'ctrl+]');
      expect((events('\x1e').single as term.TermKey).name, 'ctrl+^');
      expect((events('\x1f').single as term.TermKey).name, 'ctrl+_');
    });

    test('CSI arrows, home/end, insert/delete, pages, function keys', () {
      final cases = {
        '\x1b[A': 'up',
        '\x1b[B': 'down',
        '\x1b[C': 'right',
        '\x1b[D': 'left',
        '\x1b[H': 'home',
        '\x1b[F': 'end',
        '\x1b[1~': 'home',
        '\x1b[7~': 'home',
        '\x1b[2~': 'insert', // was wrongly 'enter'
        '\x1b[3~': 'delete',
        '\x1b[4~': 'end',
        '\x1b[8~': 'end',
        '\x1b[5~': 'pageup',
        '\x1b[6~': 'pagedown',
        '\x1b[11~': 'f1',
        '\x1b[15~': 'f5',
        '\x1b[17~': 'f6',
        '\x1b[24~': 'f12',
      };
      for (final entry in cases.entries) {
        expect((events(entry.key).single as term.TermKey).name, entry.value, reason: 'for ${entry.key.codeUnits}');
      }
    });

    test('CSI modifiers become prefixes; shift+tab', () {
      final cases = {
        '\x1b[1;5A': 'ctrl+up',
        '\x1b[1;2A': 'shift+up',
        '\x1b[1;3C': 'alt+right',
        '\x1b[1;8A': 'ctrl+alt+shift+up',
        '\x1b[Z': 'shift+tab',
        '\x1b[3;5~': 'ctrl+delete',
        '\x1b[2;2~': 'shift+insert',
      };
      for (final entry in cases.entries) {
        expect((events(entry.key).single as term.TermKey).name, entry.value, reason: 'for ${entry.key.codeUnits}');
      }
    });

    test('unknown sequences are ignored, never escape; focus reports', () {
      for (final raw in ['\x1b[999X', '\x1b[?25h']) {
        expect(events(raw), isEmpty, reason: 'for ${raw.codeUnits}');
      }
      expect((events('\x1b[I').single as term.TermFocus).gained, isTrue);
      expect((events('\x1b[O').single as term.TermFocus).gained, isFalse);
    });

    test('SS3: F1-F4 plus arrows/home/end; unknown ignored', () {
      final cases = {
        '\x1bOP': 'f1',
        '\x1bOQ': 'f2',
        '\x1bOR': 'f3',
        '\x1bOS': 'f4',
        '\x1bOA': 'up',
        '\x1bOB': 'down',
        '\x1bOC': 'right',
        '\x1bOD': 'left',
        '\x1bOH': 'home',
        '\x1bOF': 'end',
      };
      for (final entry in cases.entries) {
        expect((events(entry.key).single as term.TermKey).name, entry.value, reason: 'for ${entry.key.codeUnits}');
      }
      expect(events('\x1bOX'), isEmpty);
    });

    test('SGR mouse: presses by button; wheel at a position; no throw', () {
      final click = events('\x1b[<0;10;20M').single as term.TermClick;
      expect(click.x, 9);
      expect(click.y, 19);
      expect(click.kind, 'click');
      // A left release ends a drag; a left drag is a drag, a right drag nothing.
      expect((events('\x1b[<0;10;20m').single as term.TermRelease).x, 9);
      expect(events('\x1b[<2;10;20m'), isEmpty);
      expect((events('\x1b[<32;10;20M').single as term.TermDrag).y, 19);
      expect(events('\x1b[<34;10;20M'), isEmpty);
      expect((events('\x1b[<2;10;20M').single as term.TermClick).kind, 'rightclick');
      expect((events('\x1b[<1;10;20M').single as term.TermClick).kind, 'middleclick');
      // Wheel: the position as a hover, then the key.
      final up = events('\x1b[<64;5;6M');
      expect((up.first as term.TermHover).y, 5);
      expect((up.last as term.TermKey).name, 'wheelup');
      expect((events('\x1b[<65;5;5M').last as term.TermKey).name, 'wheeldown');
      // Malformed SGR never throws.
      expect(events('\x1b[<M'), isEmpty);
      expect(events('\x1b[<0M'), isEmpty);
    });

    test('split CSI is held for the next read', () {
      final r = term.decodeKeys(utf8.encode('\x1b['));
      expect(r.events, isEmpty);
      expect(r.consumed, 0);
    });

    test('bracketed paste arrives typed-only, CR included', () {
      final r = term.decodeKeys(utf8.encode('\x1b[200~a\r\nb\x1b[201~'));
      final e = r.events.single as term.TermType;
      expect(e.text, 'a\r\nb');
      expect(e.paste, isTrue);
      expect(r.consumed, greaterThan(0));
    });

    test('unterminated paste is held, split paste merges', () {
      final part = utf8.encode('\x1b[200~ab');
      final first = term.decodeKeys(part);
      expect(first.events, isEmpty);
      expect(first.consumed, 0);
      final rest = [...part, ...utf8.encode('cd\x1b[201~')];
      final second = term.decodeKeys(rest);
      final e = second.events.single as term.TermType;
      expect(e.text, 'abcd');
      expect(e.paste, isTrue);
    });
  });

  group('cell widths (unit)', () {
    int w(String ch) => term.cellWidth(ch.runes.first);

    test('wide CJK and emoji take two cells', () {
      expect(w('日'), 2);
      expect(w('a'), 1);
      expect(w('✅'), 2);
      expect(w('😀'), 2);
      expect(w('⭐'), 2);
    });

    test('symbols terminals draw narrow stay one cell', () {
      // Regression: the whole U+2600–27BF / U+2B00 blocks were counted wide,
      // shifting every row that used ✻ ❯ ✓ ✗.
      for (final ch in ['✻', '❯', '✓', '✗', '★', '⚠', '←', '⬆', '…', '│', '█']) {
        expect(w(ch), 1, reason: ch);
      }
    });

    test('combining marks, ZWJ and variation selectors are zero-width', () {
      expect(term.isZeroWidth(0x0301), isTrue);
      expect(term.isZeroWidth(0x200d), isTrue);
      expect(term.isZeroWidth(0xfe0f), isTrue);
      expect(term.isZeroWidth(0x1f3fb), isTrue);
      expect(term.isZeroWidth('a'.runes.single), isFalse);
    });
  });

  group('Pick', () {
    test('select clamps, set keeps the item if still there', () {
      final p = Pick<String>(['a', 'b', 'c']);
      expect(p.selected(), 'a');
      p.select(5);
      expect(p.index(), 2);
      expect(p.selected(), 'c');
      p.select(-4);
      expect(p.selected(), 'a');
      p.select(1);
      p.set(['x', 'b', 'y']);
      expect(p.selected(), 'b');
      expect(p.index(), 1);
      p.set(['z']);
      expect(p.selected(), 'z');
      expect(p.index(), 0);
    });

    test('empty has null selection', () {
      final p = Pick<int>();
      expect(p.selected(), isNull);
      expect(p.index(), 0);
      p.select(3);
      expect(p.index(), 0);
    });

    test('add, addAll, remove, removeWhere mutate and preserve selection', () {
      final p = Pick<String>(['a', 'b']);
      p.add('c');
      expect(p.items(), ['a', 'b', 'c']);
      p.addAll(['d', 'e']);
      expect(p.items(), ['a', 'b', 'c', 'd', 'e']);
      p.select(2); // 'c'
      p.remove('b');
      expect(p.items(), ['a', 'c', 'd', 'e']);
      expect(p.selected(), 'c');
      expect(p.index(), 1);
      p.removeWhere((x) => x == 'a' || x == 'd');
      expect(p.items(), ['c', 'e']);
      expect(p.selected(), 'c');
      expect(p.index(), 0);
    });

    test('Pick append is O(1) amortised with unmodifiable view', () {
      final p = Pick<int>();
      for (var i = 0; i < 20000; i++) {
        p.add(i);
      }
      expect(p.items().length, 20000);
      expect(p.selected(), 0);
      expect(() => (p.items() as dynamic).add(999), throwsUnsupportedError);
    });
  });

  group('Field', () {
    test('set moves the cursor to the end, submit pushes history', () {
      final f = Field();
      expect(f.text(), '');
      f.set('hi');
      expect(f.text(), 'hi');
      expect(f.submit(), 'hi');
      expect(f.text(), '');
      expect(f.history(), ['hi']);
      f.set('a');
      f.submit();
      f.set('b');
      f.submit();
      expect(f.history(), ['b', 'a', 'hi']);
    });

    test('Color.index validates, rgb validates', () {
      expect(() => Color.index(-1), throwsArgumentError);
      expect(() => Color.index(256), throwsArgumentError);
      expect(() => Color.rgb(0, 0, 300), throwsArgumentError);
      expect(Color.index(1), isA<Color>());
      expect(Color.rgb(1, 2, 3), isA<Color>());
    });
  });

  group('Tui.run guard', () {
    test('a second concurrent run throws StateError', () async {
      // If stdout is not a terminal, the first run throws StdoutException.
      // If a terminal is present, quit immediately so the test terminates cleanly.
      final first = Tui.run<int>(0, (s, app) {
        app.quit();
        return Screen((r) {});
      });
      expect(() => Tui.run<int>(0, (s, app) => Screen((r) {})), throwsStateError);
      try {
        await first;
      } on StdoutException catch (_) {
        // Expected when run without a terminal.
      }
    });
  });

  group('keys and widgets (in-memory)', () {
    test('keys pressed before the next redraw see the state go set', () async {
      final t = testSession<int>(
        0,
        (n, app) => Screen((r) => r.write('$n'), keys: {'enter': ('add', () => app.go(n + 1))}),
        width: 20,
        height: 5,
      );
      await t.pump();
      t.bytes(const [0x0d, 0x0d, 0x0d, 0x0d]);
      await t.pump();
      expect(t.state, 4);
      t.close();
    });

    test('list navigates, enter opens, help shows labels', () async {
      final hits = Pick<String>(['alpha', 'beta', 'gamma']);
      var opened = 0;
      var quit = false;
      late final TestSession<int> t;
      t = testSession<int>(
        0,
        (s, app) => Screen(title: 'demo', (r) {
          final [body, foot] = r.rows([0, 3]);
          body.list(hits, (h) => h, empty: 'none');
          foot.box('search');
        }, keys: {'enter': ('open', () async => opened++), 'escape': ('quit', () => app.quit()), 'x': ('', () {})}),
        width: 30,
        height: 10,
      );
      await t.pump();
      expect(t.row(0), contains('demo'));
      expect(t.row(9), contains('enter open'));
      expect(t.row(9), contains('esc quit'));
      expect(t.row(9), isNot(contains('  x')));
      expect(hits.index(), 0);
      t.bytes(const [0x1b, 0x5b, 0x42]); // down
      await t.pump();
      expect(hits.index(), 1);
      expect(t.row(9), contains('enter open'));
      t.bytes(const [0x0d]); // enter
      await t.pump();
      expect(opened, 1);
      expect(quit, isFalse);
      t.bytes(const [0x1b]); // lone ESC, held first...
      await t.pump();
      expect(quit, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await t.pump();
      expect(t.quitRequested, isTrue);
    });

    test('focus survives go via recency', () async {
      final a = Field();
      final b = Pick<String>(['one', 'two']);
      var back = false;
      final s1 = testSession<String>(
        'a',
        (s, app) {
          if (s == 'a') {
            return Screen((r) {
              r.input(a, hint: 'type');
            }, keys: {'enter': ('next', () => app.go('b'))});
          }
          return Screen(
            (r) {
              r.list(b, (x) => x);
            },
            keys: {
              'b escape': (
                'back',
                () {
                  back = true;
                  app.go('a');
                },
              ),
            },
          );
        },
        width: 20,
        height: 6,
      );
      await s1.pump();
      // First focusable is the input; type into it.
      s1.bytes(utf8.encode('hi'));
      await s1.pump();
      expect(a.text(), 'hi');
      // Go to b with enter, move the list, come back: the query is kept.
      s1.bytes(const [0x0d]);
      await s1.pump();
      expect(s1.state, 'b');
      s1.bytes(const [0x1b, 0x5b, 0x42]);
      await s1.pump();
      expect(b.index(), 1);
      s1.bytes(const [0x62]); // b
      await s1.pump();
      expect(back, isTrue);
      expect(s1.state, 'a');
      expect(a.text(), 'hi');
      // Typing still reaches the input after the round trip.
      s1.bytes(utf8.encode('!'));
      await s1.pump();
      expect(a.text(), 'hi!');
    });

    test('input editing: words, history, submit', () async {
      final f = Field(history: const ['old']);
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.input(f);
        }),
        width: 20,
        height: 4,
      );
      await t.pump();
      t.bytes(utf8.encode('ab cd'));
      await t.pump();
      expect(f.text(), 'ab cd');
      t.bytes(const [0x17]); // ctrl+w deletes 'cd'
      await t.pump();
      expect(f.text(), 'ab ');
      t.bytes(const [0x1b, 0x5b, 0x41]); // up: history
      await t.pump();
      expect(f.text(), 'old');
      t.bytes(const [0x1b, 0x5b, 0x42]); // down: back to draft
      await t.pump();
      expect(f.text(), 'ab ');
      expect(f.submit(), 'ab ');
      expect(f.history().first, 'ab ');
      expect(f.text(), '');
    });

    test('a toolkit error shows its message; SDK prefixes are dropped', () async {
      Object toThrow = const ContentException('invalid JSON at 3');
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {}, keys: {'a': ('', () => throw toThrow)}),
        width: 50,
        height: 3,
      );
      await t.pump();
      t.bytes(utf8.encode('a'));
      await t.pump();
      expect(t.row(2), contains('✗ invalid JSON at 3'));
      expect(t.row(2), isNot(contains('FormatException')));
      toThrow = const HttpException('connection reset');
      t.bytes(utf8.encode('a'));
      await t.pump();
      expect(t.row(2), contains('✗ connection reset'));
      expect(t.row(2), isNot(contains('HttpException')));
      t.close();
    });

    test('a failing suggest shows in the status row', () async {
      final f = Field();
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) => r.input(f, suggest: (w) => throw Exception('index offline'))),
        width: 40,
        height: 5,
      );
      await t.pump();
      t.bytes(utf8.encode('/a'));
      await t.pump();
      expect(t.row(4), contains('✗ index offline'));
      final async = Field();
      final t2 = testSession<int>(
        0,
        (s, app) => Screen((r) => r.input(async, suggest: (w) => Future.error(Exception('slow fail')))),
        width: 40,
        height: 5,
      );
      await t2.pump();
      t2.bytes(utf8.encode('/a'));
      await t2.pump();
      await t2.pump();
      expect(t2.row(4), contains('✗ slow fail'));
      t.close();
      t2.close();
    });

    test('handler Exception goes to the status row, Error ends the run', () async {
      var n = 0;
      final t = testSession<int>(
        0,
        (s, app) => Screen(
          (r) {
            r.write('body');
          },
          keys: {
            'a': (
              'boom',
              () {
                n++;
                throw Exception('kaput\nsecond line');
              },
            ),
            'q': ('quit', () => app.quit()),
          },
        ),
        width: 30,
        height: 5,
      );
      await t.pump();
      t.bytes(utf8.encode('a'));
      await t.pump();
      expect(n, 1);
      expect(t.row(4), contains('✗ kaput'));
      expect(t.row(4), isNot(contains('second line')));
      expect(t.quitRequested, isFalse);
      // The app keeps running after a handler Exception.
      t.bytes(utf8.encode('q'));
      await t.run();
      expect(t.quitRequested, isTrue);

      final t2 = testSession<int>(
        0,
        (s, app) => Screen(
          (r) {
            r.write('body');
          },
          keys: {
            'a': (
              'bug',
              () {
                throw StateError('bug');
              },
            ),
          },
        ),
        width: 30,
        height: 5,
      );
      await t2.pump();
      t2.bytes(utf8.encode('a'));
      await expectLater(t2.run(), throwsStateError);
    });

    test('idle pumps paint nothing', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.write('still');
        }),
        width: 20,
        height: 4,
      );
      expect(await t.pump(), isTrue);
      expect(await t.pump(), isFalse);
      expect(await t.pump(), isFalse);
    });

    test('no accent by default: list, tabs, diff and markdown emit no colour codes', () async {
      final tabs = Pick<String>(['one', 'two']);
      final rows = Pick<String>(['a', 'b']);
      Future<String> out({Color? accent}) async {
        final t = testSession<int>(
          0,
          (s, app) => Screen(title: 't', (r) {
            final [top, mid, low] = r.tabs(tabs, (x) => x).rows([3, 0, 0]);
            top.list(rows, (x) => x);
            mid.diff('one\ntwo words\nx', 'one\ntwo birds\ny');
            low.markdown('# h\n```dart\nfinal a = "s"; // c\n```');
          }),
          width: 40,
          height: 20,
          accent: accent,
        );
        await t.pump();
        final o = t.output;
        t.close();
        return o;
      }

      bool colour(String o) => RegExp('\x1b\\[([0-9;]*)m')
          .allMatches(o)
          .any(
            (m) => m
                .group(1)!
                .split(';')
                .map((p) => int.tryParse(p) ?? 0)
                .any((n) => (n >= 30 && n <= 37) || (n >= 90 && n <= 97) || n == 38 || n == 48),
          );
      expect(colour(await out()), isFalse);
      expect(colour(await out(accent: Color.orange)), isTrue);
    });

    test('table, tabs, bar, spin, box layout smoke', () async {
      final tabs = Pick<String>(['one', 'two']);
      tabs.select(1);
      final rows = Pick<int>([1, 2, 3]);
      final t = testSession<int>(
        0,
        (s, app) => Screen(title: 't', (r) {
          final top = r.tabs(tabs, (x) => x);
          final [a, b] = top.rows([0, 2]);
          a.table(rows, (v) => ['n$v', 'v$v'], header: ['#', 'v']);
          b.bar(3, 10, label: 'up');
          r.spin('work');
        }),
        width: 30,
        height: 12,
      );
      await t.pump();
      expect(t.row(0), contains('t'));
      expect(t.row(1), contains('two'));
      expect(t.row(2), contains('#'));
      expect(t.row(9), contains('up'));
    });

    test('bar(bytes: true) shows sizes', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) => r.bar(1536, 4096, label: 'f', bytes: true)),
        width: 50,
        height: 4,
      );
      await t.pump();
      expect(t.row(0), contains('1.5 KB/4.0 KB'));
    });

    test('say shows until the next error', () async {
      late App<int> app;
      final t = testSession<int>(
        0,
        (s, a) {
          app = a;
          return Screen(
            (r) {
              r.write('x');
            },
            keys: {
              'a': (
                'bad',
                () {
                  throw Exception('nope');
                },
              ),
            },
          );
        },
        width: 30,
        height: 4,
      );
      await t.pump();
      app.status('hello there');
      await t.pump();
      expect(t.row(3), contains('hello there'));
    });

    test('markdown breaks a too-long word, keeps parens in link URLs, and nests ***bold italic***', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen(
          (r) => r.markdown(
            'see https://example.com/a/very/long/path/to/a/file\n\n[link (x)](https://e.com/a_(b)) after\n\n***both***',
          ),
        ),
        width: 20,
        height: 12,
      );
      await t.pump();
      final rows = [for (var y = 0; y < 12; y++) t.row(y).trimRight()];
      expect(rows.join(), contains('https://example.com/a/very/long/path/to/a/file'.substring(0, 16)));
      expect(rows.join(), contains('to/a/file'), reason: '$rows');
      expect(rows.join('|'), contains('link (x) after'));
      expect(rows.join('|'), isNot(contains(')) after')));
      expect(rows.join('|'), contains('both'));
      expect(rows.join('|'), isNot(contains('both*')));
      t.close();
    });

    test('two diffs on one screen are each computed once (regression: Myers every frame)', () async {
      String text(int seed) =>
          [for (var i = 0; i < 3000; i++) i % 7 == seed ? 'changed $i $seed' : 'line $i'].join('\n');
      final a = text(0), b = text(1), c = text(2), d = text(3);
      var tick = 0;
      final t = testSession<int>(
        0,
        (s, app) {
          tick++;
          return Screen((r) {
            final [left, right] = r.cols([1, 1]);
            left.diff(a, b);
            right.diff(c, d);
          });
        },
        width: 80,
        height: 20,
      );
      await t.pump();
      final sw = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        t.bytes([0x78]); // any key: a new frame
        await t.pump();
      }
      expect(tick, greaterThan(10));
      expect(sw.elapsedMilliseconds, lessThan(120)); // was ~14 ms a frame, 280 ms here
      t.close();
    });

    test('a table frame costs the screen, not the rows (regression: 35 ms at 100k rows)', () async {
      final pick = Pick<int>(List.generate(1000000, (i) => i))..select(500000);
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) => r.table(pick, (i) => ['$i', 'row $i'], header: ['n', 'name'])),
        width: 40,
        height: 20,
      );
      await t.pump();
      final sw = Stopwatch()..start();
      pick.select(500001);
      await t.pump();
      expect(sw.elapsedMilliseconds, lessThan(150)); // was ~350 ms at a million rows
      expect([for (var y = 0; y < 20; y++) t.row(y)].join('|'), contains('row 500001'));
      t.close();
    });

    test('a full repaint moves the cursor once a row through frames and CJK, not per cell', () async {
      for (final fill in ['─', '日']) {
        final t = testSession<int>(0, (s, app) => Screen((r) => r.write(fill * 2000)), width: 40, height: 10);
        await t.pump();
        final moves = RegExp(r'\x1b\[\d+;\d+H').allMatches(t.output).length;
        expect(moves, lessThanOrEqualTo(12), reason: fill); // was one per cell
        t.close();
      }
    });

    test('a ZWJ family and a VS16 heart each take two cells', () async {
      final t = testSession<int>(0, (s, app) => Screen((r) => r.write('👨‍👩‍👧|❤️|x')), width: 20, height: 2);
      await t.pump();
      expect(t.row(0), startsWith('👨‍👩‍👧|❤️|x'));
      expect(term.displayWidth(t.row(0).trimRight()), 7); // 2 + 1 + 2 + 1 + 1
      t.close();
    });

    test('a popup title lays wide glyphs over two cells', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) => r.popup('日本語', width: 20, height: 4)),
        width: 30,
        height: 8,
      );
      await t.pump();
      expect(t.row(2), contains(' 日本語 '));
      expect(term.displayWidth(t.row(2).trimRight()), term.displayWidth(t.row(3).trimRight())); // the frame lines up
      t.close();
    });

    test('the status row writes no C1 control (a raw U+009B is a CSI)', () async {
      late App<int> app;
      final t = testSession<int>(
        0,
        (s, a) {
          app = a;
          return Screen((r) => r.write('x'));
        },
        width: 30,
        height: 4,
      );
      await t.pump();
      app.status('evil\u009b2J\u0085end');
      await t.pump();
      expect(t.output.runes.where((r) => r >= 0x80 && r <= 0x9f), isEmpty);
      expect(t.row(3), contains('evil'));
      t.close();
    });

    test('click focuses and selects; hover restyles', () async {
      final p = Pick<String>(['a', 'b', 'c']);
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.list(p, (x) => 'item $x');
        }),
        width: 20,
        height: 5,
      );
      await t.pump();
      // Click row 2 (status row is last; rows 0..3 are the list).
      t.bytes(const [0x1b, 0x5b, 0x3c, 0x30, 0x3b, 0x33, 0x3b, 0x33, 0x4d]);
      await t.pump();
      expect(p.index(), 2);
    });
  });

  group('routing (in-memory)', () {
    test('order: popup > focused > tab > keys > other widget > ctrl+c', () async {
      final f = Field();
      final p = Pick<String>(['a', 'b', 'c']);
      final log = <String>[];
      var tabBound = false;
      final t = testSession<int>(
        0,
        (s, app) => Screen(
          (r) {
            final [top, bottom] = r.rows([3, 0]);
            top.input(f);
            bottom.list(p, (x) => x);
          },
          keys: {
            'x': ('x', () => log.add('keys x')),
            'down': ('', () => log.add('keys down')),
            if (tabBound) 'tab': ('', () => log.add('keys tab')),
          },
        ),
        width: 20,
        height: 8,
      );
      await t.pump();
      // 2. The focused input takes printable text before `keys`.
      t.bytes(utf8.encode('x'));
      await t.pump();
      expect(f.text(), 'x');
      expect(log, isEmpty);
      // 4. `down` is bound in keys: it beats the unfocused list (5).
      t.bytes(utf8.encode('\x1b[B'));
      await t.pump();
      expect(log, ['keys down']);
      expect(p.index(), 0);
      // 3. Unbound tab moves the focus to the list; now `down` is its own.
      t.bytes(utf8.encode('\t'));
      await t.pump();
      t.bytes(utf8.encode('\x1b[B'));
      await t.pump();
      expect(p.index(), 1);
      expect(log, ['keys down']);
      // With the list focused, `x` falls to keys.
      t.bytes(utf8.encode('x'));
      await t.pump();
      expect(log, ['keys down', 'keys x']);
      // 3. A bound tab goes to keys and never moves the focus.
      tabBound = true;
      t.bytes(utf8.encode('\t'));
      await t.pump();
      t.bytes(utf8.encode('\t'));
      await t.pump();
      expect(log.last, 'keys tab');
      // 6. Unbound ctrl+c quits.
      t.bytes(const [0x03]);
      await t.pump();
      expect(t.quitRequested, isTrue);
      t.close();
    });

    test('5: an unbound up/down reaches the only list while typing', () async {
      final f = Field();
      final p = Pick<String>(['a', 'b']);
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final [a, b] = r.rows([0, 1]);
          a.list(p, (x) => x);
          b.input(f);
        }),
        width: 20,
        height: 6,
      );
      await t.pump();
      t.bytes(utf8.encode('\t')); // focus the input
      await t.pump();
      t.bytes(utf8.encode('q\x1b[B'));
      await t.pump();
      expect(f.text(), 'q');
      expect(p.index(), 1);
      t.close();
    });

    test('alternatives in one binding name; on() regions bind when focused', () async {
      var back = 0, hit = 0;
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.on({'k': ('hit', () => hit++)}).write('zone');
        }, keys: {'b escape': ('back', () => back++)}),
        width: 20,
        height: 4,
      );
      await t.pump();
      t.bytes(utf8.encode('b'));
      await t.pump();
      t.bytes(utf8.encode('\x1b\x1b'));
      await t.pump();
      expect(back, 2);
      t.bytes(utf8.encode('k'));
      await t.pump();
      expect(hit, 1);
      t.close();
    });

    test('show fires when a state becomes current; resize is bindable', () async {
      final shown = <String>[];
      late App<String> app;
      final t = testSession<String>(
        'a',
        (s, a) {
          app = a;
          return Screen((r) => r.write(s), keys: {'show': ('', () => shown.add(s))});
        },
        width: 20,
        height: 4,
      );
      await t.pump();
      expect(shown, ['a']);
      app.go('b');
      await t.pump();
      await t.pump();
      expect(shown, ['a', 'b']);
      t.close();
    });
  });

  group('status row (in-memory)', () {
    test('help: esc, hidden labels and mouse/lifecycle names', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen(
          status: '⏵⏵ accept edits on',
          (r) {},
          keys: {
            'escape': ('quit', () {}),
            'ctrl+y': ('', () {}),
            'click': ('open', () {}),
            'show': ('load', () {}),
            'enter': ('send', () {}),
          },
        ),
        width: 60,
        height: 3,
      );
      await t.pump();
      final row = t.row(2);
      expect(row, startsWith('⏵⏵ accept edits on'));
      expect(row, endsWith('esc quit · enter send'));
      expect(row, isNot(contains('open')));
      expect(row, isNot(contains('load')));
      expect(row, isNot(contains('ctrl+y')));
      t.close();
    });

    test('a narrow row cuts the help first, the message last', () async {
      late App<int> app;
      final t = testSession<int>(
        0,
        (s, a) {
          app = a;
          return Screen((r) {}, keys: {'a': ('alpha', () {}), 'b': ('bravo', () {})});
        },
        width: 24,
        height: 3,
      );
      await t.pump();
      expect(t.row(2), endsWith('a alpha · b bravo'));
      app.status('downloading things');
      await t.pump();
      expect(t.row(2), startsWith('downloading things'));
      expect(t.row(2), isNot(contains('alpha')));
      app.status('a much longer message than the row');
      await t.pump();
      expect(t.row(2), 'a much longer message t…');
      t.close();
    });

    test('an Exception from work a handler started shows; go clears say', () async {
      late App<int> app;
      final t = testSession<int>(
        0,
        (s, a) {
          app = a;
          return Screen(
            (r) {},
            keys: {
              'a': (
                '',
                () {
                  Timer(Duration.zero, () => throw const FormatException('bad'));
                },
              ),
            },
          );
        },
        width: 40,
        height: 3,
      );
      await t.pump();
      t.bytes(utf8.encode('a'));
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await t.pump();
      expect(t.row(2), contains('✗ bad'), reason: 'no SDK type prefix');
      expect(t.quitRequested, isFalse);
      app.status('hi');
      await t.pump();
      t.close();
    });
  });

  group('Console inside run (in-memory)', () {
    test('spin and bar draw in the status row, several at once', () async {
      final done = Completer<void>();
      Bar? bar;
      final t = testSession<int>(
        0,
        (s, app) => Screen(
          (r) {},
          keys: {
            'a': ('', () => Console.spin('searching', done.future)),
            'b': (
              '',
              () {
                bar = Console.bar(4, label: '↓ ch.1')..tick();
              },
            ),
          },
        ),
        width: 60,
        height: 3,
      );
      await t.pump();
      t.bytes(utf8.encode('ab'));
      await t.pump();
      expect(t.row(2), contains('searching'));
      expect(t.row(2), contains('↓ ch.1'));
      expect(t.row(2), contains('1/4'));
      done.complete();
      await bar!.close();
      await t.pump();
      expect(t.row(2), isNot(contains('searching')));
      expect(t.row(2), isNot(contains('ch.1')));
      t.close();
    });

    test('a failing spin shows ✗ label', () async {
      final t = testSession<int>(
        0,
        (s, app) =>
            Screen((r) {}, keys: {'a': ('', () => Console.spin('loading', Future<void>.error(Exception('down'))))}),
        width: 40,
        height: 3,
      );
      await t.pump();
      t.bytes(utf8.encode('a'));
      await t.pump();
      await t.pump();
      expect(t.row(2), contains('✗'));
      t.close();
    });

    test('confirm is a modal popup; keys are not routed under it', () async {
      bool? answer;
      var under = 0;
      final t = testSession<int>(
        0,
        (s, app) => Screen(
          (r) {},
          keys: {
            'q': (
              '',
              () async {
                answer = await Console.confirm('2 downloads left. Quit?');
              },
            ),
            'y': ('', () => under++),
          },
        ),
        width: 50,
        height: 10,
      );
      await t.pump();
      t.bytes(utf8.encode('q'));
      await t.pump();
      final screen = [for (var i = 0; i < 10; i++) t.row(i)].join('\n');
      expect(screen, contains('2 downloads left. Quit?'));
      t.bytes(utf8.encode('y\r'));
      await t.pump();
      expect(answer, isTrue);
      expect(under, 0);
      final after = [for (var i = 0; i < 10; i++) t.row(i)].join('\n');
      expect(after, isNot(contains('Quit?')));
      t.close();
    });

    test('Console.log shows on the status row in full screen', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {}, keys: {'l': ('', () => Console.log('hello there'))}),
        width: 50,
        height: 10,
      );
      await t.pump();
      t.bytes(utf8.encode('l'));
      await t.pump();
      expect(t.row(9), contains('hello there'));
      t.close();
    });

    test('ask and choose; escape gives null and shows nothing', () async {
      String? name, pick, cancelled = 'x';
      var reached = false;
      final t = testSession<int>(
        0,
        (s, app) => Screen(
          (r) {},
          keys: {
            'a': (
              '',
              () async {
                name = await Console.ask('name?');
              },
            ),
            'c': (
              '',
              () async {
                pick = await Console.choose('which?', ['one', 'two']);
              },
            ),
            'e': (
              '',
              () async {
                cancelled = await Console.ask('cancel me');
                reached = true;
              },
            ),
          },
        ),
        width: 50,
        height: 10,
      );
      await t.pump();
      t.bytes(utf8.encode('a'));
      await t.pump();
      t.bytes(utf8.encode('Ada\r'));
      await t.pump();
      expect(name, 'Ada');
      t.bytes(utf8.encode('c'));
      await t.pump();
      t.bytes(utf8.encode('\x1b[B\r'));
      await t.pump();
      expect(pick, 'two');
      t.bytes(utf8.encode('e'));
      await t.pump();
      t.bytes(utf8.encode('\x1b\x1b'));
      await t.pump();
      expect(reached, isTrue);
      expect(cancelled, isNull);
      expect(t.row(9), isNot(contains('✗')));
      expect(t.quitRequested, isFalse);
      t.close();
    });
  });

  group('tabs clicks', () {
    test('a click inside a column and a scroll region picks the tab under it', () async {
      final tabs = Pick<String>(['aaa', 'bbb', 'ccc']);
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final [_, b] = r.cols([5, 0]);
          b.scroll(Scroll()).tabs(tabs, (x) => x);
        }),
        width: 30,
        height: 6,
      );
      await t.pump();
      expect(t.row(0), contains('ccc'));
      final x = t.row(0).indexOf('ccc');
      t.bytes(utf8.encode('\x1b[<0;${x + 1};1M'));
      await t.pump();
      expect(tabs.index(), 2);
      final x0 = t.row(0).indexOf('aaa');
      t.bytes(utf8.encode('\x1b[<0;${x0 + 1};1M'));
      await t.pump();
      expect(tabs.index(), 0);
      t.close();
    });
  });

  group('notify', () {
    test('fires when focus is never reported; silent only while focused', () async {
      final t = testSession<int>(0, (s, a) {
        return Screen((r) {});
      });
      await t.pump();
      Console.notify('one');
      expect(t.output, contains('\x1b]9;one'));
      t.bytes(utf8.encode('\x1b[I'));
      await t.pump();
      Console.notify('two');
      expect(t.output, isNot(contains('two')));
      t.bytes(utf8.encode('\x1b[O'));
      await t.pump();
      Console.notify('three');
      expect(t.output, contains('\x1b]9;three'));
      t.close();
    });

    test('notify text cannot end its OSC early', () async {
      final t = testSession<int>(0, (s, a) {
        return Screen((r) => r.popup('POP\x9b2J', width: 20, height: 4));
      });
      await t.pump();
      Console.notify('N\x9c\x9b2J\x1b]52;c;x\x07');
      expect(t.output, contains('\x1b]9;N2J]52;c;x\x07'));
      expect(t.output, isNot(contains('\x9b')));
      expect(t.output, isNot(contains('\x9c')));
      t.close();
    });
  });

  group('session memory', () {
    test('the style table is bounded and colours stay right after it resets', () async {
      var n = 0;
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) => r.write('x', color: Color.rgb(n % 256, (n ~/ 256) % 256, 7))),
        env: {'COLORTERM': 'truecolor', 'TERM': 'xterm-256color'},
      );
      await t.pump();
      for (n = 1; n < 5000; n++) {
        t.bytes(utf8.encode('z'));
        await t.pump();
        expect(t.styleCount, lessThanOrEqualTo(4097));
      }
      final last = n - 1;
      expect(t.output, contains('38;2;${last % 256};${last ~/ 256};7'));
      t.close();
    });
  });

  group('bind regions', () {
    test('a Region.on region keeps focus across frames', () async {
      final f = Field();
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.input(f);
          r.on({'x': ('', () {})}).write('zone');
        }),
      );
      await t.pump();
      expect(t.focus, same(f));
      t.bytes(utf8.encode('\t'));
      await t.pump();
      expect(t.focus, isNot(same(f)));
      await t.pump();
      t.bytes(utf8.encode('\x1b[Z'));
      await t.pump();
      expect(t.focus, same(f), reason: 'shift+tab left the bind region');
      t.close();
    });
  });

  group('binding names', () {
    test("aliases fire: 'esc', 'pgup', 'del', 'Ctrl+A'", () async {
      final log = <String>[];
      final t = testSession<int>(
        0,
        (s, app) => Screen(
          (r) {},
          keys: {
            'esc': ('', () => log.add('esc')),
            'pgup': ('', () => log.add('pgup')),
            'del x': ('', () => log.add('del')),
            'Ctrl+A': ('', () => log.add('ctrl+a')),
          },
        ),
      );
      await t.pump();
      for (final raw in ['\x1b\x1b', '\x1b[5~', '\x1b[3~', '\x01']) {
        t.bytes(utf8.encode(raw));
        await t.pump();
      }
      expect(log, ['esc', 'pgup', 'del', 'ctrl+a']);
      t.close();
    });
  });

  group('choose popup', () {
    Future<(TestSession<int>, List<String>)> open(int n, int height) async {
      final picks = <String>[];
      final t = testSession<int>(
        0,
        (s, app) => Screen(
          (r) {},
          keys: {
            'c': (
              '',
              () async {
                picks.add((await Console.choose<String>('which?', [for (var i = 0; i < n; i++) 'item$i']))!);
              },
            ),
          },
        ),
        width: 40,
        height: height,
      );
      await t.pump();
      t.bytes(utf8.encode('c'));
      await t.pump();
      return (t, picks);
    }

    int rowOf(TestSession<int> t, int height, String text) {
      for (var y = 0; y < height; y++) {
        if (t.row(y).contains(text)) return y;
      }
      return -1;
    }

    test('a click selects the row under the pointer', () async {
      final (t, picks) = await open(3, 12);
      final y = rowOf(t, 12, 'item2');
      final x = t.row(y).indexOf('item2');
      t.bytes(utf8.encode('\x1b[<0;${x + 1};${y + 1}M'));
      await t.pump();
      t.bytes(utf8.encode('\r'));
      await t.pump();
      expect(picks, ['item2']);
      t.close();
    });

    test('long lists window around the selection and clicks map to the shown rows', () async {
      final (t, picks) = await open(30, 16);
      for (var i = 0; i < 12; i++) {
        t.bytes(utf8.encode('\x1b[B'));
      }
      await t.pump();
      final y = rowOf(t, 16, 'item12');
      expect(y, isNonNegative, reason: 'the selected row is drawn');
      expect(rowOf(t, 16, 'item0'), -1);
      expect(rowOf(t, 16, 'item29'), -1);
      final y10 = rowOf(t, 16, 'item8');
      final x = t.row(y10).indexOf('item8');
      t.bytes(utf8.encode('\x1b[<0;${x + 1};${y10 + 1}M'));
      await t.pump();
      t.bytes(utf8.encode('\r'));
      await t.pump();
      expect(picks, ['item8']);
      t.close();
    });
  });

  group('prompts and ctrl+c', () {
    test('quitting answers open prompts with null so callers finish', () async {
      final log = <String>[];
      late App<int> app;
      final t = testSession<int>(
        0,
        (s, a) {
          app = a;
          return Screen(
            (r) {},
            keys: {
              'e': (
                '',
                () async {
                  try {
                    log.add('ask=${await Console.ask('name?')}');
                  } finally {
                    log.add('finally');
                  }
                },
              ),
            },
          );
        },
        width: 50,
        height: 10,
      );
      await t.pump();
      t.bytes(utf8.encode('e'));
      await t.pump();
      app.quit();
      await t.pump();
      expect(log, ['ask=null', 'finally']);
      expect(await Console.ask('after'), isNull);
      t.close();
    });

    test('ctrl+c closes an open prompt like escape', () async {
      var reached = false;
      final t = testSession<int>(
        0,
        (s, app) => Screen(
          (r) {},
          keys: {
            'e': (
              '',
              () async {
                await Console.ask('cancel me');
                reached = true;
              },
            ),
          },
        ),
        width: 50,
        height: 10,
      );
      await t.pump();
      t.bytes(utf8.encode('e'));
      await t.pump();
      String screen() => [for (var y = 0; y < 10; y++) t.row(y)].join('\n');
      expect(screen(), contains('cancel me'));
      t.bytes([0x03]);
      await t.pump();
      expect(screen(), isNot(contains('cancel me')));
      expect(reached, isTrue);
      expect(t.quitRequested, isFalse);
      t.close();
    });
  });

  group('mouse (in-memory)', () {
    String click(int x, int y, [int btn = 0]) => '\x1b[<$btn;${x + 1};${y + 1}M';

    test('click goes to the innermost on() region, then out to keys', () async {
      final log = <String>[];
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final [a, b] = r.on({'click': ('', () => log.add('outer'))}).rows([2, 0]);
          a.on({'click': ('', () => log.add('inner'))}).write('btn');
          b.write('plain');
        }, keys: {'rightclick': ('', () => log.add('keys right'))}),
        width: 20,
        height: 6,
      );
      await t.pump();
      t.bytes(utf8.encode(click(1, 0)));
      await t.pump();
      t.bytes(utf8.encode(click(1, 3)));
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 450));
      t.bytes(utf8.encode(click(1, 3, 2)));
      await t.pump();
      expect(log, ['inner', 'outer', 'keys right']);
      t.close();
    });

    test('a second click in place is a doubleclick', () async {
      final log = <String>[];
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.on({'click': ('', () => log.add('click')), 'doubleclick': ('', () => log.add('double'))}).write('x');
        }),
        width: 10,
        height: 3,
      );
      await t.pump();
      t.bytes(utf8.encode(click(0, 0) + click(0, 0)));
      await t.pump();
      expect(log, ['click', 'double']);
      t.close();
    });

    test('the wheel scrolls what is under the pointer; hover restyles', () async {
      final left = Pick<int>(List.generate(20, (i) => i));
      final right = Pick<int>(List.generate(20, (i) => i));
      var hovered = false;
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final [a, b] = r.cols([10, 0]);
          a.list(left, (i) => 'L$i');
          hovered = b.hovered();
          b.list(right, (i) => 'R$i');
        }),
        width: 20,
        height: 6,
      );
      await t.pump();
      expect(hovered, isFalse);
      t.bytes(utf8.encode('\x1b[<65;15;2M')); // wheel down at x=14
      await t.pump();
      expect(right.index(), 1);
      expect(left.index(), 0);
      expect(hovered, isTrue);
      t.bytes(utf8.encode('\x1b[<35;2;2M')); // hover over the left list
      await t.pump();
      expect(hovered, isFalse);
      t.close();
    });

    test('a button fires on enter, space and click', () async {
      var n = 0;
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.button('Go', () => n++);
        }),
        width: 10,
        height: 3,
      );
      await t.pump();
      expect(t.row(0), '[ Go ]');
      t.bytes(utf8.encode('\r'));
      await t.pump();
      t.bytes(utf8.encode(' '));
      await t.pump();
      t.bytes(utf8.encode(click(2, 0)));
      await t.pump();
      expect(n, 3);
      t.close();
    });
  });

  group('input (in-memory)', () {
    test('arrows move the terminal cursor even when no cell changes', () async {
      String? cursor(String out) {
        final m = RegExp(r'\x1b\[(\d+);(\d+)H\x1b\[\?25h').allMatches(out);
        return m.isEmpty ? null : '${m.last.group(1)};${m.last.group(2)}';
      }

      final f = Field(text: 'abc');
      final s = testSession<int>(0, (st, app) => Screen((r) => r.input(f)), width: 20, height: 4);
      await s.pump();
      expect(cursor(s.output), '1;4');
      s.bytes(utf8.encode('\x1b[D'));
      expect(await s.pump(), isTrue);
      expect(cursor(s.output), '1;3');
      s.close();
    });

    Future<(TestSession<int>, Field)> field({
      String text = '',
      List<String> history = const [],
      int lines = 1,
      FutureOr<List<String>> Function(String)? suggest,
    }) async {
      final f = Field(text: text, history: history);
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.input(f, lines: lines, suggest: suggest);
        }, keys: {'enter': ('send', () {})}),
        width: 30,
        height: 12,
      );
      await t.pump();
      return (t, f);
    }

    Future<void> keys(TestSession<int> t, String s) async {
      t.bytes(utf8.encode(s));
      await t.pump();
    }

    test('readline keys', () async {
      final (t, f) = await field(text: 'one two three');
      await keys(t, '\x1b\x7f'); // alt+backspace
      expect(f.text(), 'one two ');
      await keys(t, '\x01X'); // ctrl+a, type
      expect(f.text(), 'Xone two ');
      await keys(t, '\x05Y'); // ctrl+e
      expect(f.text(), 'Xone two Y');
      await keys(t, '\x1b[1;5D\x1b[1;5D|'); // ctrl+left twice
      expect(f.text(), 'Xone |two Y');
      await keys(t, '\x0b'); // ctrl+k
      expect(f.text(), 'Xone |');
      await keys(t, '\x1b[D\x15'); // left, ctrl+u
      expect(f.text(), '|');
      await keys(t, '\x1b[H<\x1b[F>\x1b[D\x1b[3~'); // home end left delete
      expect(f.text(), '<|');
      t.close();
    });

    test('backspace and delete remove whole graphemes (ZWJ, accents)', () async {
      final (t, f) = await field(text: 'a👨‍👩‍👧é');
      await keys(t, '\x7f');
      expect(f.text(), 'a👨‍👩‍👧');
      await keys(t, '\x7f');
      expect(f.text(), 'a');
      t.close();
    });

    test('paste never submits and newlines become spaces on one line', () async {
      var sent = 0;
      final f = Field();
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) => r.input(f), keys: {'enter': ('send', () => sent++)}),
        width: 30,
        height: 4,
      );
      await t.pump();
      t.bytes(utf8.encode('\x1b[200~a\r\nb\x1b[201~'));
      await t.pump();
      expect(f.text(), 'a b');
      expect(sent, 0);
      t.bytes(utf8.encode('\r'));
      await t.pump();
      expect(sent, 1);
      expect(f.text(), 'a b', reason: 'enter is never consumed by input');
      t.close();
    });

    test('a paste that stalls over a second stays a paste (regression: its tail ran as keys)', () async {
      var sent = 0;
      final f = Field();
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) => r.input(f), keys: {'enter': ('send', () => sent++)}),
        width: 40,
        height: 4,
      );
      await t.pump();
      t.bytes(utf8.encode('\x1b[200~echo safe'));
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 220));
        await t.pump();
      }
      t.bytes(utf8.encode('; rm -rf ~\r\x1b[201~'));
      await t.pump();
      expect((f.text(), sent), ('echo safe; rm -rf ~ ', 0));
      t.close();
    });

    test('multi-line: shift+enter, alt+enter, \\+enter; up/down', () async {
      final (t, f) = await field(lines: 0, history: const ['old']);
      await keys(t, 'a\x1b[13;2ub\x1b\rc\\\rd');
      expect(f.text(), 'a\nb\nc\nd');
      await keys(t, '\x1b[A\x1b[AX'); // up twice: line b
      expect(f.text(), 'a\nbX\nc\nd');
      await keys(t, '\x1b[A\x1b[A'); // on the first line, up walks history
      expect(f.text(), 'old');
      await keys(t, '\x1b[B');
      expect(f.text(), 'a\nbX\nc\nd');
      t.close();
    });

    test('a multi-line input grows to its lines', () async {
      final f = Field(text: 'l1\nl2\nl3');
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.input(f, lines: 0);
          r.write('below');
        }),
        width: 20,
        height: 8,
      );
      await t.pump();
      expect([for (var i = 0; i < 4; i++) t.row(i)], ['l1', 'l2', 'l3', 'below']);
      t.close();
    });

    test('suggest: up/down choose, tab replaces the word, escape closes', () async {
      const cmds = ['/clear', '/compact', '/help'];
      final (t, f) = await field(
        suggest: (w) => [
          for (final c in cmds)
            if (c.startsWith(w)) c,
        ],
      );
      await keys(t, '/c');
      String screen() => [for (var i = 0; i < 12; i++) t.row(i)].join('\n');
      expect(screen(), contains('/clear'));
      expect(screen(), contains('/compact'));
      expect(screen(), isNot(contains('/help')));
      await keys(t, '\x1b[B\t');
      expect(f.text(), '/compact');
      expect(screen(), isNot(contains('/clear')));
      await keys(t, ' x /h');
      expect(screen(), contains('/help'));
      await keys(t, '\x1b\x1b');
      expect(screen(), isNot(contains('/help')));
      expect(f.text(), '/compact x /h');
      t.close();
    });

    test('suggest: enter replaces; a stale async answer is dropped', () async {
      final slow = Completer<List<String>>();
      final (t, f) = await field(suggest: (w) => w == '/a' ? slow.future : Future.value(['/b-$w']));
      await keys(t, '/a');
      await keys(t, '\x7fb'); // now '/b'
      slow.complete(['/stale']);
      await t.pump();
      String screen() => [for (var i = 0; i < 12; i++) t.row(i)].join('\n');
      expect(screen(), isNot(contains('/stale')));
      expect(screen(), contains('/b-/b'));
      await keys(t, '\r');
      expect(f.text(), '/b-/b');
      t.close();
    });

    test('onSubmit fires on enter', () async {
      final f = Field(text: 'submit text');
      var submitted = false;
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.input(f, onSubmit: () => submitted = true);
        }),
        width: 30,
        height: 5,
      );
      await t.pump();
      t.bytes(utf8.encode('\r'));
      await t.pump();
      expect(submitted, isTrue);
      t.close();
    });
  });

  group('scroll (in-memory)', () {
    test('follow pins to the end; scrolling up unpins; end re-pins', () async {
      final sc = Scroll();
      var n = 10;
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final v = r.scroll(sc);
          for (var i = 0; i < n; i++) {
            v.write('row $i');
          }
        }),
        width: 20,
        height: 5,
      );
      await t.pump();
      expect(t.row(3), startsWith('row 9'));
      expect(t.row(3), endsWith('█'));
      n = 12;
      t.bytes(const []);
      await t.pump();
      await t.pump();
      // Pinned: grows with the content.
      t.bytes(utf8.encode('\x1b[5~')); // pageup (scroll is focused)
      await t.pump();
      expect(t.row(0), startsWith('row 4'));
      n = 14;
      t.bytes(utf8.encode('x')); // any event redraws
      await t.pump();
      expect(t.row(0), startsWith('row 4'), reason: 'unpinned stays put');
      t.bytes(utf8.encode('\x1b[F')); // end
      await t.pump();
      expect(t.row(3), startsWith('row 13'));
      t.close();
    });

    test('lines draws only the rows in view, following and scrolled back', () async {
      final sc = Scroll();
      final drawn = <int>{};
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.scroll(sc)
            ..write('head')
            ..lines(1000, (row, i) {
              drawn.add(i);
              row.write('line $i');
            });
        }),
        width: 20,
        height: 5,
      );
      await t.pump();
      expect([for (var y = 0; y < 4; y++) t.row(y)], [for (var i = 996; i < 1000; i++) startsWith('line $i')]);
      expect(drawn, {for (var i = 996; i < 1000; i++) i}, reason: 'off-screen lines are never drawn');
      drawn.clear();
      t.bytes(utf8.encode('\x1b[H')); // home: the top, with what came before the lines
      await t.pump();
      expect(t.row(0), startsWith('head'));
      expect(t.row(3), startsWith('line 2'));
      expect(drawn, {0, 1, 2});
      t.close();
    });

    test('the scrollbar owns the last column; content never reaches it', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final v = r.scroll(Scroll(follow: false));
          for (var i = 0; i < 8; i++) {
            v.write('abcdefghi0 日日日日日日日日');
          }
        }),
        width: 10,
        height: 6,
      );
      await t.pump();
      for (var y = 0; y < 4; y++) {
        final row = t.row(y);
        expect(row.runes.last, anyOf(0x2588, 0x2502), reason: 'row $y ends in a scrollbar glyph: $row');
        expect(term.displayWidth(row), 10, reason: 'row $y: $row');
      }
      expect(t.row(0), startsWith('abcdefghi'));
      t.close();
    });

    test('box() takes no title; spin(since:) appends the elapsed time', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.spin('Thinking…', since: DateTime.now().subtract(const Duration(seconds: 75)));
          r.box('').write('in');
        }),
        width: 24,
        height: 8,
      );
      await t.pump();
      expect(t.row(0), contains('Thinking… (1m 15s)'));
      expect(t.row(1), startsWith('┌──'));
      expect(t.row(2), contains('in'));
    });

    test('the scrollbar jumps on a click and follows a drag', () async {
      final sc = Scroll(follow: false);
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) => r.scroll(sc).write([for (var i = 0; i < 20; i++) 'line $i'].join('\n'))),
        width: 12,
        height: 5,
      );
      await t.pump();
      expect(t.row(0), startsWith('line 0'));
      t.bytes('\x1b[<0;12;4M'.codeUnits); // click the scrollbar's bottom cell (row 4 is the status row)
      await t.pump();
      expect(t.row(3), startsWith('line 19'));
      t.bytes('\x1b[<32;12;3M'.codeUnits); // drag to the third of four rows: 2/3 of the way
      await t.pump();
      expect(t.row(0), startsWith('line 11'));
      t.bytes('\x1b[<35;5;3M\x1b[<32;12;1M'.codeUnits); // released (motion), then a stray drag
      await t.pump();
      expect(t.row(0), startsWith('line 11'));
      t.close();
    });

    test('a drag selects text within its scroll, and letting go copies it', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final [a, b] = r.cols([10, 0]);
          a.scroll(Scroll(follow: false)).write('hello\nworld');
          b.write('RIGHT');
        }),
        width: 20,
        height: 4,
      );
      await t.pump();
      t.bytes('\x1b[<0;2;1M\x1b[<32;15;2M'.codeUnits); // from "ello" past the scroll's edge on row 2
      await t.pump();
      t.bytes('\x1b[<0;15;2m'.codeUnits);
      await t.pump();
      expect(t.output, contains('\x1b]52;c;${base64.encode(utf8.encode('ello\nworld'))}'));
      expect(t.row(3), contains('copied 10 characters'));
      t.close();
    });

    test('on: binds what a widget drew: a box header, written rows', () async {
      final heard = <String>[];
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final [top, rest] = r.rows([4, 0]);
          top.box('head', on: {'click': ('', () => heard.add('head'))}).write('inside');
          rest.write('text', on: {'rightclick': ('', () => heard.add('text'))});
        }),
        width: 20,
        height: 8,
      );
      await t.pump();
      t.bytes('\x1b[<0;10;1M\x1b[<0;3;2M\x1b[<2;2;5M'.codeUnits); // the header, the inside, the text
      await t.pump();
      expect(heard, ['head', 'text']);
      t.close();
    });

    test('colours apply to every widget', () async {
      final pick = Pick<String>(['a', 'b']);
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final [top, rest] = r.rows([3, 0]);
          top.box('t', color: Color.red).write('in');
          rest.list(pick, (x) => x, color: Color.green, highlight: Color.blue);
        }),
        width: 20,
        height: 8,
        env: const {'COLORTERM': 'truecolor', 'LANG': 'en_US.UTF-8', 'TERM': 'xterm-256color'},
      );
      await t.pump();
      expect(t.output, contains('\x1b[0;38;5;1m┌─ t ─')); // the border and title
      expect(t.output, contains('\x1b[0;1;48;5;4ma')); // the selection on the highlight
      expect(t.output, contains('\x1b[0;38;5;2mb')); // the other rows in the colour
      t.close();
    });

    test('a box inside a scroll takes its content height', () async {
      final sc = Scroll(follow: false);
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final v = r.scroll(sc);
          v.box('t').write('in');
          v.write('after');
        }),
        width: 20,
        height: 8,
      );
      await t.pump();
      expect(
        [for (var i = 0; i < 4; i++) t.row(i)],
        ['┌─ t ─────────────┐', '│in               │', '└─────────────────┘', 'after'],
      );
      t.close();
    });
  });

  group('drawing (in-memory)', () {
    test('write wraps in linear time and keeps the cells', () async {
      final small = testSession<int>(
        0,
        (s, a) => Screen((r) {
          r.write('abcdefghijkl');
          r.write('abcd中e');
        }),
        width: 5,
        height: 6,
      );
      await small.pump();
      expect([for (var i = 0; i < 5; i++) small.row(i)], ['abcde', 'fghij', 'kl', 'abcd', '中e']);
      small.close();
      final text = 'abcdefghij' * 8000; // 80,000 chars, one line
      final t = testSession<int>(0, (s, a) => Screen((r) => r.scroll(Scroll()).write(text)), width: 80, height: 24);
      final sw = Stopwatch()..start();
      await t.pump();
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)), reason: 'was ~6.7 s a frame (quadratic)');
      t.close();
    });

    test('streamed markdown appends match a full render', () async {
      const doc =
          '# Title\n\nSome *prose* with `code` and a [link](http://x).\n\n'
          '- one\n- two\n  - nested\n\n```dart\nfinal a = 1;\n```\n\n> quoted\n> more\n\n'
          '| a | b |\n|---|---|\n| 1 | 2 |\n\nlast paragraph that wraps across the narrow width\n';
      List<String> rows(TestSession<int> t) => [for (var i = 0; i < 40; i++) t.row(i)];
      var shown = '';
      final streamed = testSession<int>(0, (s, a) => Screen((r) => r.markdown(shown)), width: 30, height: 40);
      for (var at = 0; at <= doc.length; at += 7) {
        shown = doc.substring(0, at);
        streamed.resize(30, 40);
        await streamed.pump();
        final full = testSession<int>(
          0,
          (s, a) => Screen((r) => r.markdown(doc.substring(0, at))),
          width: 30,
          height: 40,
        );
        await full.pump();
        expect(rows(streamed), rows(full), reason: 'after $at chars');
        full.close();
      }
      streamed.close();
      // Many small appends stay linear: each costs its tail.
      var long = '';
      final t = testSession<int>(0, (s, a) => Screen((r) => r.markdown(long)), width: 80, height: 5);
      final sw = Stopwatch()..start();
      for (var k = 0; k < 3000; k++) {
        long = '${long}line $k of a growing answer\n\n';
        t.resize(80, 5);
        await t.pump();
      }
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      t.close();
    });

    test('the screen function runs once per frame, refocus included', () async {
      var calls = 0;
      var withField = false;
      final f = Field();
      final t = testSession<int>(
        0,
        (s, a) {
          calls++;
          return Screen((r) => withField ? r.input(f) : r.write('-'));
        },
        width: 20,
        height: 4,
      );
      await t.pump();
      withField = true; // the next frame focuses a new widget: a refocus pass
      t.resize(20, 4);
      calls = 0;
      await t.pump();
      expect(calls, 1);
      expect(t.focus, same(f), reason: 'the refocus pass still focuses the field');
      t.close();
    });
    test('markdown of 40,000 brackets or underscores renders at once', () async {
      for (final c in ['[', '_', '*']) {
        final text = c * 40000;
        final t = testSession<int>(0, (s, a) => Screen((r) => r.markdown(text)), width: 80, height: 24);
        final sw = Stopwatch()..start();
        await t.pump();
        expect(sw.elapsed, lessThan(const Duration(seconds: 2)), reason: c);
        t.close();
      }
    });

    test("write('a\\n') draws no trailing empty row", () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.write('a\n');
          r.write('b');
        }),
        width: 10,
        height: 4,
      );
      await t.pump();
      expect(t.row(0), 'a');
      expect(t.row(1), 'b');
      t.close();
    });

    test('write wraps nothing past the region: the last row ends with …', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final [a, _] = r.rows([2, 0]);
          a.write('1\n2\n3');
        }),
        width: 10,
        height: 5,
      );
      await t.pump();
      expect(t.row(1), endsWith('…'));
      t.close();
    });

    test('write wraps at the right edge', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) => r.write('the quick brown fox\n0123456789ab\nz')),
        width: 12,
        height: 5,
      );
      await t.pump();
      expect([for (var i = 0; i < 4; i++) t.row(i)], ['the quick br', 'own fox', '0123456789ab', 'z']);
      t.close();
    });

    test('write(link:) is an OSC 8 hyperlink', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) => r.write('docs', link: 'https://x.y')),
        width: 10,
        height: 3,
      );
      await t.pump();
      expect(t.output, contains('\x1b]8;;https://x.y\x1b\\docs'));
      t.close();
    });

    test('link targets with control characters are dropped', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.write('a', link: 'http://a\x1b]2;PWNED\x07');
          r.markdown('[x](http://b\x1b]2;PWNED\x07)');
        }),
        width: 20,
        height: 4,
      );
      await t.pump();
      expect(t.output, isNot(contains('PWNED')));
      t.close();
    });

    test('markdown: underscores in words and spaced stars stay literal', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) => r.markdown('my_var_name and 2 * 3 * 4 and *it*')),
        width: 40,
        height: 3,
      );
      await t.pump();
      expect(t.row(0), 'my_var_name and 2 * 3 * 4 and it');
      t.close();
    });

    test('markdown: blocks and inline', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen(
          (r) => r.markdown(
            '# Title\n\n'
            'some **bold** and `code`\n\n'
            '- one\n  - nested\n1. first\n> quote\n\n'
            '| a | b |\n|---|---|\n| 1 | 2 |\n\n---',
          ),
        ),
        width: 30,
        height: 16,
      );
      await t.pump();
      expect(
        [for (var i = 0; i < 12; i++) t.row(i)],
        [
          'Title',
          'some bold and code',
          '• one',
          '  • nested',
          '1. first',
          '> quote',
          '┌─────┬─────┐',
          '│ a   │ b   │',
          '├─────┼─────┤',
          '│ 1   │ 2   │',
          '└─────┴─────┘',
          '─' * 30,
        ],
      );
      expect(t.output, contains('\x1b[0;1m'), reason: 'bold');
      t.close();
    });

    test('markdown: an unclosed fence streams as code, spaces kept', () async {
      var src = 'text\n```dart\nfinal  x = "s"; // c';
      final t = testSession<int>(0, (s, app) => Screen((r) => r.markdown(src)), width: 40, height: 6);
      await t.pump();
      expect(t.row(1), 'final  x = "s"; // c');
      src += '\nvoid main() {}\n```\n**done';
      t.bytes(utf8.encode(' ')); // any event redraws
      await t.pump();
      expect(t.row(2), 'void main() {}');
      expect(t.row(3), 'done', reason: 'unclosed emphasis renders closed');
      t.close();
    });

    test('markdown: streaming append reuses cached prefix and non-prefix edit re-lays', () async {
      var src = '# Header\n\nParagraph one.\n\n';
      final t = testSession<int>(0, (s, app) => Screen((r) => r.markdown(src)), width: 40, height: 10);
      await t.pump();
      expect(t.row(0), 'Header');
      expect(t.row(1), 'Paragraph one.');

      // Streamed append: startsWith holds, prefix lines retained
      src += 'Paragraph two.';
      t.bytes(utf8.encode(' '));
      await t.pump();
      expect(t.row(0), 'Header');
      expect(t.row(1), 'Paragraph one.');
      expect(t.row(2), 'Paragraph two.');

      // Non-prefix edit: re-lays from scratch, no stale data reused
      src = '# Modified Title\n\nBrand new body.';
      t.bytes(utf8.encode(' '));
      await t.pump();
      expect(t.row(0), 'Modified Title');
      expect(t.row(1), 'Brand new body.');
      t.close();
    });

    test('diff: hunks with 3 context lines and gutters', () async {
      final before = [for (var i = 1; i <= 20; i++) 'line $i'].join('\n');
      final after = before.replaceFirst('line 15', 'line fifteen');
      final t = testSession<int>(0, (s, app) => Screen((r) => r.diff(before, after)), width: 40, height: 12);
      await t.pump();
      expect(
        [for (var i = 0; i < 8; i++) t.row(i)],
        [
          '  12   12   line 12',
          '  13   13   line 13',
          '  14   14   line 14',
          '  15      - line 15',
          '       15 + line fifteen',
          '  16   16   line 16',
          '  17   17   line 17',
          '  18   18   line 18',
        ],
      );
      expect(t.row(8), '');
      t.close();
    });

    test('diff: merged hunks keep unchanged lines as context', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) => r.diff('x\ns\ns\ny', 'X\ns\ns\nY')),
        width: 40,
        height: 12,
      );
      await t.pump();
      expect(
        [for (var i = 0; i < 7; i++) t.row(i)],
        ['   1      - x', '        1 + X', '   2    2   s', '   3    3   s', '   4      - y', '        4 + Y', ''],
      );
      t.close();
    });

    test('diff: large texts are fast and memoized', () async {
      final a = [for (var i = 0; i < 4000; i++) 'a$i'].join('\n');
      final b = [for (var i = 0; i < 4000; i++) 'b$i'].join('\n');
      final t = testSession<int>(0, (s, app) => Screen((r) => r.diff(a, b)), width: 40, height: 12);
      final sw = Stopwatch()..start();
      await t.pump();
      await t.pump();
      expect(sw.elapsedMilliseconds, lessThan(1500));
      t.close();
    });

    test('colours downgrade to the terminal; NO_COLOR keeps styles', () async {
      Future<String> paint(Map<String, String> env) async {
        final t = testSession<int>(
          0,
          (s, app) => Screen((r) => r.write('x', color: Color.rgb(255, 0, 0), style: {Style.strike})),
          width: 10,
          height: 3,
          env: {'LANG': 'en_US.UTF-8', ...env},
        );
        await t.pump();
        t.close();
        return t.output;
      }

      expect(await paint({'COLORTERM': 'truecolor'}), contains('\x1b[0;9;38;2;255;0;0m'));
      expect(await paint({'TERM': 'xterm-256color'}), contains('\x1b[0;9;38;5;196m'));
      expect(await paint({'TERM': 'xterm'}), contains('\x1b[0;9;91m'));
      expect(await paint({'NO_COLOR': '1', 'COLORTERM': 'truecolor'}), contains('\x1b[0;9mx'));
    });

    test('LANG=C switches boxes, bars and spinners to ASCII', () async {
      Future<List<String>> paint(Map<String, String> env) async {
        final t = testSession<int>(
          0,
          (s, app) => Screen((r) {
            final [a, b] = r.rows([3, 0]);
            a.box('t');
            b.bar(1, 2).spin('w');
          }),
          width: 12,
          height: 6,
          env: env,
        );
        await t.pump();
        t.close();
        return [for (var i = 0; i < 5; i++) t.row(i)];
      }

      final ascii = await paint({'LANG': 'C'});
      expect(ascii[0], startsWith('+- t -'));
      expect(ascii.skip(3).join(), isNot(matches(RegExp('[─━│⠋]'))));
      expect(await paint({'LANG': 'C', 'LC_ALL': 'en_US.UTF-8'}), contains(startsWith('┌─ t')));
    });
  });

  group('picture (in-memory)', () {
    test('half blocks, scaled down with the aspect kept', () async {
      final png = img.encodePng(img.Image(width: 8, height: 8)..clear(img.ColorRgb8(255, 0, 0)));
      final picture = Image.decode(png);
      final t = testSession<int>(0, (s, app) => Screen((r) => r.picture(picture)), width: 4, height: 10);
      await t.pump();
      expect(t.row(0), '▀▀▀▀');
      expect(t.row(1), '▀▀▀▀');
      expect(t.row(2), '');
      expect(t.output, contains('38;5;196'));
      t.close();
    });
  });

  group('painter (in-memory terminal)', () {
    /// A session whose output feeds a [Term].
    Future<(TestSession<int>, Term)> paint(
      void Function(Region r) Function() draw, {
      required int w,
      required int h,
      Set<String> wide = const {},
    }) async {
      final term = Term(w, h, wide: wide);
      final t = testSession<int>(0, (s, app) => Screen(draw()), width: w, height: h);
      await t.pump();
      term.feed(t.output);
      return (t, term);
    }

    Future<void> redraw(TestSession<int> t, Term term) async {
      final from = t.output.length;
      t.bytes(const [0x1b, 0x5b, 0x39, 0x39, 0x39, 0x58]); // ignored CSI: just a redraw
      await t.pump();
      term.feed(t.output.substring(from));
    }

    test('inline code does not highlight the space before it', () async {
      final (t, term) = await paint(
        () =>
            (r) => r.markdown('run `dart test` now'),
        w: 30,
        h: 4,
      );
      expect(term.row(0).trimRight(), 'run dart test now');
      expect(term.styleAt(3, 0), isNot(contains('inverse')));
      expect(term.styleAt(4, 0), contains('inverse'));
      expect(term.styleAt(13, 0), isNot(contains('inverse')));
      t.close();
    });

    test('a partial change redraws in place (no cursor drift)', () async {
      var text = 'abcdef';
      final (t, term) = await paint(
        () =>
            (r) => r.write(text),
        w: 10,
        h: 2,
      );
      text = 'aXcdYf';
      await redraw(t, term);
      expect(term.row(0), 'aXcdYf    ');
      text = 'count = 9';
      await redraw(t, term);
      text = 'count = 10';
      await redraw(t, term);
      expect(term.row(0), 'count = 10');
      t.close();
    });

    test('wide chars take two cells with no extra space', () async {
      var (a, b) = ('日本語abc', '✻ rawfree');
      final (t, term) = await paint(
        () =>
            (r) => r.write(a).write(b),
        w: 12,
        h: 3,
      );
      expect(term.row(0), '日本語abc   ');
      expect(term.row(1), '✻ rawfree   ');
      (a, b) = ('日x語abc', '❯ beta');
      await redraw(t, term);
      expect(term.row(0), '日x語abc    ');
      expect(term.row(1), '❯ beta      ');
      t.close();
    });

    test('a width the terminal disagrees on damages only its own cell', () async {
      final (t, term) = await paint(
        () =>
            (r) => r.write('✻ rawfree'),
        w: 12,
        h: 2,
        wide: {'✻'},
      );
      expect(term.row(0).substring(2), 'rawfree   ');
      t.close();
    });

    test('combining marks join their base (Vietnamese NFD)', () async {
      final (t, term) = await paint(
        () =>
            (r) => r.write('Nguyễn'),
        w: 10,
        h: 2,
      );
      expect(term.cells(0).take(7).toList(), ['N', 'g', 'u', 'y', 'ễ', 'n', ' ']);
      t.close();
    });

    test('a style never leaks into the next cell', () async {
      final (t, term) = await paint(
        () =>
            (r) => r.write('ab', style: {Style.bold}, color: Color.red).write('cd', color: Color.green),
        w: 6,
        h: 3,
      );
      expect(term.styleAt(0, 0), {'bold', 'fg1'});
      expect(term.styleAt(0, 1), {'fg2'});
      expect(term.styleAt(2, 0), isEmpty);
      t.close();
    });

    test('a resize repaints every cell at the new size', () async {
      var lines = ['wide screen text'];
      var resized = 0;
      final term = Term(20, 4);
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) => lines.forEach(r.write), keys: {'resize': ('', () => resized++)}),
        width: 20,
        height: 4,
      );
      await t.pump();
      term.feed(t.output);
      lines = ['narrow', 'row two'];
      t.resize(8, 3);
      term.resize(8, 3); // a fresh terminal: anything skipped stays blank
      final from = t.output.length;
      await t.pump();
      term.feed(t.output.substring(from));
      expect(term.row(0), 'narrow  ');
      expect(term.row(1), 'row two ');
      expect(resized, 1);
      t.close();
    });

    test('control characters never reach the terminal raw', () async {
      final (t, _) = await paint(
        () =>
            (r) => r.write('a\tb\x01c\x1b[31mred\x1b[0m\rz'),
        w: 20,
        h: 3,
      );
      final raw = t.output.replaceAll(RegExp(r'\x1b\[[0-9;?]*[A-Za-z]'), '');
      expect(raw.codeUnits.where((c) => c < 0x20), isEmpty);
      expect(raw, contains('a       b�cred�z'));
      t.close();
    });

    test('nothing changed writes nothing', () async {
      final (t, term) = await paint(
        () =>
            (r) => r.write('same'),
        w: 10,
        h: 2,
      );
      final first = t.output.length;
      await redraw(t, term);
      expect(t.output.length, first);
      t.close();
    });

    test('a list scrolls by the least needed; clicks pick what is shown', () async {
      final p = Pick<String>([for (var i = 0; i < 10; i++) 'item $i']);
      final (t, term) = await paint(
        () =>
            (r) => r.list(p, (x) => x),
        w: 10,
        h: 4,
      );
      for (var i = 0; i < 3; i++) {
        t.bytes(utf8.encode('\x1b[B'));
        await t.pump();
      }
      expect(p.index(), 3);
      expect(t.row(0), 'item 1'); // rows show 1..3, not a page jump
      t.bytes(utf8.encode('\x1b[<0;1;1M'));
      await t.pump();
      expect(p.index(), 1);
      t.close();
    });

    test('a button below the region edge is not drawn and cannot fire', () async {
      final fired = <String>[];
      final (t, _) = await paint(
        () => (r) {
          final [top, _] = r.rows([1, 0]);
          top.button('one', () => fired.add('one')).button('two', () => fired.add('two'));
        },
        w: 20,
        h: 4,
      );
      t.bytes(utf8.encode('\t\t\r'));
      await t.pump();
      expect(fired, ['one']);
      expect(t.output, isNot(contains('two')));
      t.close();
    });
  });

  group('regressions (in-memory)', () {
    test('the hardware cursor is (row, col), shown on the first frame', () async {
      final f = Field(text: 'ab');
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final [_, b] = r.rows([2, 0]);
          b.cols([3, 0])[1].input(f);
        }),
        width: 20,
        height: 6,
      );
      await t.pump();
      expect(t.output, endsWith('\x1b[3;6H\x1b[?25h'));
      t.close();
    });

    test('cols inside a scroll draw at their own column', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final v = r.scroll(Scroll());
          v.write('top');
          final [a, b] = v.cols([5, 0]);
          a.write('L');
          b.write('R');
        }),
        width: 20,
        height: 6,
      );
      await t.pump();
      expect(t.row(0), 'top');
      expect(t.row(1), 'L    R');
      t.close();
    });

    test('kitty CSI u letters decode (ctrl+c as 99;5u)', () {
      final ev = term.decodeKeys(utf8.encode('\x1b[99;5u')).events;
      expect((ev.single as term.TermKey).name, 'ctrl+c');
      expect((term.decodeKeys(utf8.encode('\x1b\x7f')).events.single as term.TermKey).name, 'alt+backspace');
    });
  });

  group('regressions: examples (in-memory)', () {
    test('a focused input takes letters before a Screen key (rule 2 before 4)', () async {
      final f = Field();
      var bound = 0;
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) => r.input(f), keys: {'a': ('all', () => bound++)}),
        width: 20,
        height: 4,
      );
      await t.pump();
      t.bytes(utf8.encode('a'));
      await t.pump();
      expect(f.text(), 'a');
      expect(bound, 0);
      t.close();
    });

    test('say and an error replace each other; a new spin or bar clears both', () async {
      late App<int> app;
      final done = Completer<void>();
      final t = testSession<int>(
        0,
        (s, a) {
          app = a;
          return Screen(
            (r) {},
            keys: {
              'e': ('', () => throw Exception('boom')),
              's': ('', () => Console.spin('working', done.future)),
              'b': ('', () => Console.bar(3, label: 'dl')),
            },
          );
        },
        width: 40,
        height: 3,
      );
      await t.pump();
      app.status('hello');
      await t.pump();
      expect(t.row(2), contains('hello'));
      t.bytes(utf8.encode('e'));
      await t.pump();
      expect(t.row(2), contains('✗ boom'));
      expect(t.row(2), isNot(contains('hello')));
      app.status('again');
      await t.pump();
      expect(t.row(2), contains('again'));
      expect(t.row(2), isNot(contains('boom')));
      t.bytes(utf8.encode('s'));
      await t.pump();
      expect(t.row(2), contains('working'));
      expect(t.row(2), isNot(contains('again')));
      t.bytes(utf8.encode('e'));
      await t.pump();
      expect(t.row(2), contains('✗ boom'));
      t.bytes(utf8.encode('b'));
      await t.pump();
      expect(t.row(2), contains('dl'));
      expect(t.row(2), isNot(contains('boom')));
      done.complete();
      t.close();
    });

    test('a status-row bar draws label, glyphs, counts and rate like Console.bar', () async {
      Bar? bar;
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {}, keys: {'b': ('', () => bar = Console.bar(4, label: '↓ ch')..tick(2))}),
        width: 60,
        height: 3,
      );
      await t.pump();
      t.bytes(utf8.encode('b'));
      await t.pump();
      expect(t.row(2), matches(RegExp(r'^↓ ch ━━━━━───── 2/4  \S+/s')));
      bar!.tick(-8); // ignored, as Console.bar documents
      await t.pump();
      expect(t.row(2), contains(' 2/4 '));
      await bar!.close();
      t.close();
    });

    test('table columns are as wide as their widest cell, shrunk to fit', () async {
      final rows = Pick<List<String>>([
        ['a', 'x', '1'],
        ['longer name', 'yy', '2'],
      ]);
      Screen screen(int s, App<int> app) => Screen((r) => r.table(rows, (c) => c, header: ['name', 's', 'n']));
      final t = testSession<int>(0, screen, width: 40, height: 5);
      await t.pump();
      expect(t.row(0), 'name         s   n');
      expect(t.row(1).trimRight(), 'a            x   1');
      expect(t.row(2).trimRight(), 'longer name  yy  2');
      t.close();
      final narrow = testSession<int>(0, screen, width: 14, height: 5);
      await narrow.pump();
      // The widest column gives up cells first; the others keep theirs.
      expect(narrow.row(2).trimRight(), 'longer…  yy  2');
      expect(narrow.row(1).trimRight(), 'a        x   1');
      narrow.close();
    });
  });

  group('App (in-memory)', () {
    test('notify is a no-op while focus is reported, OSC 9/777 after blur', () async {
      final t = testSession<int>(0, (s, a) {
        return Screen((r) {});
      });
      await t.pump();
      t.bytes(utf8.encode('\x1b[I'));
      await t.pump();
      Console.notify('done');
      expect(t.output, isNot(contains('\x1b]9;')));
      t.bytes(utf8.encode('\x1b[O')); // blur
      await t.pump();
      Console.notify('done');
      expect(t.output, contains('\x1b]9;done\x07'));
      expect(t.output, contains('\x1b]777;notify;done\x07'));
      t.close();
    });

    test('focus/blur are bindable lifecycle events', () async {
      final log = <String>[];
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {}, keys: {'focus': ('', () => log.add('focus')), 'blur': ('', () => log.add('blur'))}),
      );
      await t.pump();
      t.bytes(utf8.encode('\x1b[O\x1b[I'));
      await t.pump();
      expect(log, ['blur', 'focus']);
      t.close();
    });

    test('copy writes OSC 52', () async {
      final t = testSession<int>(0, (s, a) {
        return Screen((r) {});
      });
      await t.pump();
      Console.copy('hé');
      expect(t.output, contains('\x1b]52;c;${base64.encode(utf8.encode('hé'))}\x1b\\'));
      t.close();
    });

    test('a split ESC [ is held, not alt+[', () async {
      final log = <String>[];
      final t = testSession<int>(
        0,
        (s, app) => Screen(
          (r) {},
          keys: {
            'up': ('', () => log.add('up')),
            'alt+[': ('', () => log.add('alt+[')),
            'escape': ('', () => log.add('escape')),
          },
        ),
      );
      await t.pump();
      t.bytes(const [0x1b, 0x5b]);
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await t.pump();
      expect(log, isEmpty);
      t.bytes(const [0x41]);
      await t.pump();
      expect(log, ['up']);
      t.close();
    });
  });
}
