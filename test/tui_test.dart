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
      // Release and drag: nothing.
      expect(events('\x1b[<0;10;20m'), isEmpty);
      expect(events('\x1b[<32;10;20M'), isEmpty);
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

  group('Selection', () {
    test('select clamps, set keeps the item if still there', () {
      final p = Selection<String>(['a', 'b', 'c']);
      expect(p.selected(), 'a');
      p.select(5);
      expect(p.index(), 2);
      expect(p.selected(), 'c');
      p.select(-4);
      expect(p.selected(), 'a');
      p.select(1);
      p.setItems(['x', 'b', 'y']);
      expect(p.selected(), 'b');
      expect(p.index(), 1);
      p.setItems(['z']);
      expect(p.selected(), 'z');
      expect(p.index(), 0);
    });

    test('empty has null selection', () {
      final p = Selection<int>();
      expect(p.selected(), isNull);
      expect(p.index(), 0);
      p.select(3);
      expect(p.index(), 0);
    });

    test('add, addAll, remove, removeWhere mutate and preserve selection', () {
      final p = Selection<String>(['a', 'b']);
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

    test('Selection append is O(1) amortised with unmodifiable view', () {
      final p = Selection<int>();
      for (var i = 0; i < 20000; i++) {
        p.add(i);
      }
      expect(p.items().length, 20000);
      expect(p.selected(), 0);
      expect(() => (p.items() as dynamic).add(999), throwsUnsupportedError);
    });
  });

  group('TextField', () {
    test('set moves the cursor to the end, submit pushes history', () {
      final f = TextField();
      expect(f.text(), '');
      f.setText('hi');
      expect(f.text(), 'hi');
      expect(f.submit(), 'hi');
      expect(f.text(), '');
      expect(f.history(), ['hi']);
      f.setText('a');
      f.submit();
      f.setText('b');
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
    test('list navigates, enter opens, help shows labels', () async {
      final hits = Selection<String>(['alpha', 'beta', 'gamma']);
      var opened = 0;
      var quit = false;
      late final TestSession<int> t;
      t = testSession<int>(
        0,
        (s, app) => Screen(title: 'demo', (r) {
          final [body, foot] = r.splitRows([0, 3]);
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
      final a = TextField();
      final b = Selection<String>(['one', 'two']);
      var back = false;
      final s1 = testSession<String>(
        'a',
        (s, app) {
          if (s == 'a') {
            return Screen((r) {
              r.input(a, hint: 'type');
            }, keys: {'enter': ('next', () => app.goTo('b'))});
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
                  app.goTo('a');
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
      final f = TextField(history: const ['old']);
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

    test('table, tabs, bar, spin, box layout smoke', () async {
      final tabs = Selection<String>(['one', 'two']);
      tabs.select(1);
      final rows = Selection<int>([1, 2, 3]);
      final t = testSession<int>(
        0,
        (s, app) => Screen(title: 't', (r) {
          final top = r.tabs(tabs, (x) => x);
          final [a, b] = top.splitRows([0, 2]);
          a.table(rows, (v) => ['n$v', 'v$v'], header: ['#', 'v']);
          b.progressBar(3, 10, label: 'up');
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
      app.showStatus('hello there');
      await t.pump();
      expect(t.row(3), contains('hello there'));
    });

    test('click focuses and selects; hover restyles', () async {
      final p = Selection<String>(['a', 'b', 'c']);
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
      final f = TextField();
      final p = Selection<String>(['a', 'b', 'c']);
      final log = <String>[];
      var tabBound = false;
      final t = testSession<int>(
        0,
        (s, app) => Screen(
          (r) {
            final [top, bottom] = r.splitRows([3, 0]);
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
      final f = TextField();
      final p = Selection<String>(['a', 'b']);
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final [a, b] = r.splitRows([0, 1]);
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
          r.bind({'k': ('hit', () => hit++)}).write('zone');
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
      app.goTo('b');
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
      app.showStatus('downloading things');
      await t.pump();
      expect(t.row(2), startsWith('downloading things'));
      expect(t.row(2), isNot(contains('alpha')));
      app.showStatus('a much longer message than the row');
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
      expect(t.row(2), contains('✗ FormatException: bad'));
      expect(t.quitRequested, isFalse);
      app.showStatus('hi');
      await t.pump();
      t.close();
    });
  });

  group('Console inside run (in-memory)', () {
    test('spin and bar draw in the status row, several at once', () async {
      final done = Completer<void>();
      ProgressBar? bar;
      final t = testSession<int>(
        0,
        (s, app) => Screen(
          (r) {},
          keys: {
            'a': ('', () => Console.withSpinner('searching', () => done.future)),
            'b': (
              '',
              () {
                bar = Console.progressBar(4, label: '↓ ch.1')..tick();
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
        (s, app) => Screen(
          (r) {},
          keys: {
            'a': (
              '',
              () => Console.withSpinner('loading', () async {
                throw Exception('down');
              }),
            ),
          },
        ),
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

    test('ask and choose; escape is EOF and shows nothing', () async {
      String? name, pick;
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
                pick = await Console.choose('which?', ['one', 'two'], label: (s) => '$s');
              },
            ),
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
      expect(reached, isFalse);
      expect(t.row(9), isNot(contains('✗')));
      expect(t.quitRequested, isFalse);
      t.close();
    });
  });

  group('tabs clicks', () {
    test('a click inside a column and a scroll region picks the tab under it', () async {
      final tabs = Selection<String>(['aaa', 'bbb', 'ccc']);
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final [_, b] = r.splitColumns([5, 0]);
          b.scroll(ScrollPosition()).tabs(tabs, (x) => x);
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
      late App<int> app;
      final t = testSession<int>(0, (s, a) {
        app = a;
        return Screen((r) {});
      });
      await t.pump();
      app.notify('one');
      expect(t.output, contains('\x1b]9;one'));
      t.bytes(utf8.encode('\x1b[I'));
      await t.pump();
      app.notify('two');
      expect(t.output, isNot(contains('two')));
      t.bytes(utf8.encode('\x1b[O'));
      await t.pump();
      app.notify('three');
      expect(t.output, contains('\x1b]9;three'));
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
    test('a Region.bind region keeps focus across frames', () async {
      final f = TextField();
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.input(f);
          r.bind({'x': ('', () {})}).write('zone');
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
        (s, app) => Screen((r) {}, keys: {
          'esc': ('', () => log.add('esc')),
          'pgup': ('', () => log.add('pgup')),
          'del x': ('', () => log.add('del')),
          'Ctrl+A': ('', () => log.add('ctrl+a')),
        }),
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
        (s, app) => Screen((r) {}, keys: {
          'c': (
            '',
            () async {
              picks.add(await Console.choose<String>('which?', [for (var i = 0; i < n; i++) 'item$i'], label: (s) => s));
            },
          ),
        }),
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
    test('ctrl+c closes an open prompt like escape', () async {
      var reached = false;
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {}, keys: {
          'e': (
            '',
            () async {
              await Console.ask('cancel me');
              reached = true;
            },
          ),
        }),
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
      expect(reached, isFalse);
      expect(t.quitRequested, isFalse);
      t.close();
    });
  });

  group('inline suggest', () {
    test('the suggest popup follows the input when the live area scrolls', () async {
      final f = TextField();
      final t = testSession<int>(
        0,
        (s, app) => Screen(status: 'mode', (r) {
          for (var i = 0; i < 14; i++) {
            r.write('line $i');
          }
          r.input(f, suggest: (w) => ['/clear', '/compact']);
        }),
        width: 30,
        height: 10,
        fullscreen: false,
      );
      await t.pump();
      t.bytes(utf8.encode('/c'));
      await t.pump();
      await t.pump();
      final rows = [for (var i = 0; i < 10; i++) t.row(i)];
      final input = rows.indexWhere((r) => r.contains('/c') && !r.contains('/cl') && !r.contains('/co'));
      final pop = rows.indexWhere((r) => r.contains('/clear'));
      expect(input, isNonNegative, reason: rows.join('|'));
      expect(pop, greaterThan(input), reason: rows.join('|'));
      expect(rows.indexWhere((r) => r.contains('mode')), greaterThan(pop), reason: rows.join('|'));
      t.close();
    });
  });

  group('inline mode (in-memory)', () {
    test('the live area is as tall as its content; box and rows measure', () async {
      final f = TextField();
      final t = testSession<int>(
        0,
        (s, app) => Screen(status: 'mode', (r) {
          r.write('reply');
          r.box('').input(f, hint: 'type');
          final [a, b] = r.splitRows([0, 0]);
          a.write('a1\na2');
          b.write('b1');
        }),
        width: 20,
        height: 20,
        fullscreen: false,
      );
      await t.pump();
      expect(
        [for (var i = 0; i < 8; i++) t.row(i)],
        ['reply', '┌──────────────────┐', '│type              │', '└──────────────────┘', 'a1', 'a2', 'b1', 'mode'],
      );
      // The input shows the hardware cursor at its first cell.
      expect(t.output, endsWith('\x1b[6A\r\x1b[1C\x1b[?25h'));
      t.close();
    });

    test('print commits above the live area and leaves the redraw set', () async {
      late App<int> app;
      final t = testSession<int>(
        0,
        (s, a) {
          app = a;
          return Screen((r) => r.write('live'));
        },
        width: 20,
        height: 10,
        fullscreen: false,
      );
      await t.pump();
      app.printAbove((r) => r.box('').write('> hello'));
      await t.pump();
      final out = t.output;
      final commit = out.indexOf('> hello');
      expect(commit, greaterThan(0));
      expect(out.substring(commit), contains('└'));
      // The live area is drawn again below the commit.
      expect(out.lastIndexOf('live'), greaterThan(commit));
      expect(t.row(0), 'live');
      t.close();
    });

    test('print throws StateError in full screen', () async {
      late App<int> app;
      final t = testSession<int>(0, (s, a) {
        app = a;
        return Screen((r) {});
      });
      await t.pump();
      expect(() => app.printAbove((r) => r.write('x')), throwsStateError);
      t.close();
    });

    test('a repaint rewrites only changed rows, inside synchronized output', () async {
      var n = 0;
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          r.write('static top\nvalue $n');
        }),
        width: 20,
        height: 10,
        fullscreen: false,
      );
      await t.pump();
      expect(t.output, startsWith('\x1b[?2026h'));
      final before = t.output.length;
      n = 1;
      t.bytes(utf8.encode(' '));
      await t.pump();
      final delta = t.output.substring(before);
      expect(delta, contains('value 1'));
      expect(delta, isNot(contains('static top')));
      expect(delta, endsWith('\x1b[?2026l\x1b[?25l'));
      t.close();
    });

    test('content taller than the terminal shows its bottom', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          for (var i = 0; i < 10; i++) {
            r.write('line $i');
          }
        }),
        width: 20,
        height: 5,
        fullscreen: false,
      );
      await t.pump();
      expect([for (var i = 0; i < 4; i++) t.row(i)], ['line 6', 'line 7', 'line 8', 'line 9']);
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
          final [a, b] = r.bind({'click': ('', () => log.add('outer'))}).splitRows([2, 0]);
          a.bind({'click': ('', () => log.add('inner'))}).write('btn');
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
          r.bind({'click': ('', () => log.add('click')), 'doubleclick': ('', () => log.add('double'))}).write('x');
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
      final left = Selection<int>(List.generate(20, (i) => i));
      final right = Selection<int>(List.generate(20, (i) => i));
      var hovered = false;
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final [a, b] = r.splitColumns([10, 0]);
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
    Future<(TestSession<int>, TextField)> field({
      String text = '',
      List<String> history = const [],
      int lines = 1,
      FutureOr<List<String>> Function(String)? suggest,
    }) async {
      final f = TextField(text: text, history: history);
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
      final f = TextField();
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
      final f = TextField(text: 'l1\nl2\nl3');
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
      final f = TextField(text: 'submit text');
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
      final sc = ScrollPosition();
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

    test('the scrollbar owns the last column; content never reaches it', () async {
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final v = r.scroll(ScrollPosition(follow: false));
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

    test('a box inside a scroll takes its content height', () async {
      final sc = ScrollPosition(follow: false);
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
          final [a, _] = r.splitRows([2, 0]);
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
          0, (s, app) => Screen((r) => r.diff('x\ns\ns\ny', 'X\ns\ns\nY')),
          width: 40, height: 12);
      await t.pump();
      expect([for (var i = 0; i < 7; i++) t.row(i)], [
        '   1      - x',
        '        1 + X',
        '   2    2   s',
        '   3    3   s',
        '   4      - y',
        '        4 + Y',
        '',
      ]);
      t.close();
    });

    test('diff: large texts are fast and memoized', () async {
      final a = [for (var i = 0; i < 4000; i++) 'a$i'].join('\n');
      final b = [for (var i = 0; i < 4000; i++) 'b$i'].join('\n');
      final t = testSession<int>(0, (s, app) => Screen((r) => r.diff(a, b)),
          width: 40, height: 12);
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
            final [a, b] = r.splitRows([3, 0]);
            a.box('t');
            b.progressBar(1, 2).spin('w');
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
    /// A session whose output feeds a [_Term].
    Future<(TestSession<int>, _Term)> paint(
      void Function(Region r) Function() draw, {
      required int w,
      required int h,
      Set<String> wide = const {},
    }) async {
      final term = _Term(w, h, wide: wide);
      final t = testSession<int>(0, (s, app) => Screen(draw()), width: w, height: h);
      await t.pump();
      term.feed(t.output);
      return (t, term);
    }

    Future<void> redraw(TestSession<int> t, _Term term) async {
      final from = t.output.length;
      t.bytes(const [0x1b, 0x5b, 0x39, 0x39, 0x39, 0x58]); // ignored CSI: just a redraw
      await t.pump();
      term.feed(t.output.substring(from));
    }

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
      final term = _Term(20, 4);
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
      final p = Selection<String>([for (var i = 0; i < 10; i++) 'item $i']);
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
          final [top, _] = r.splitRows([1, 0]);
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
      final f = TextField(text: 'ab');
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {
          final [_, b] = r.splitRows([2, 0]);
          b.splitColumns([3, 0])[1].input(f);
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
          final v = r.scroll(ScrollPosition());
          v.write('top');
          final [a, b] = v.splitColumns([5, 0]);
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
      final f = TextField();
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
              's': ('', () => Console.withSpinner('working', () => done.future)),
              'b': ('', () => Console.progressBar(3, label: 'dl')),
            },
          );
        },
        width: 40,
        height: 3,
      );
      await t.pump();
      app.showStatus('hello');
      await t.pump();
      expect(t.row(2), contains('hello'));
      t.bytes(utf8.encode('e'));
      await t.pump();
      expect(t.row(2), contains('✗ boom'));
      expect(t.row(2), isNot(contains('hello')));
      app.showStatus('again');
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

    test('a status-row bar draws label, glyphs, counts and rate like Console.progressBar', () async {
      ProgressBar? bar;
      final t = testSession<int>(
        0,
        (s, app) => Screen((r) {}, keys: {'b': ('', () => bar = Console.progressBar(4, label: '↓ ch')..tick(2))}),
        width: 60,
        height: 3,
      );
      await t.pump();
      t.bytes(utf8.encode('b'));
      await t.pump();
      expect(t.row(2), matches(RegExp(r'^↓ ch ━━━━━───── 2/4  \S+/s')));
      await bar!.close();
      t.close();
    });

    test('table columns are as wide as their widest cell, shrunk to fit', () async {
      final rows = Selection<List<String>>([
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

    test('inline: a suggest popup grows the live area only as far as it reaches', () async {
      final f = TextField();
      final t = testSession<int>(
        0,
        (s, app) => Screen(status: 'mode', (r) {
          r.input(f, suggest: (w) => [for (final c in ['/clear', '/help']) if (c.startsWith(w)) c]);
        }),
        width: 30,
        height: 20,
        fullscreen: false,
      );
      await t.pump();
      t.bytes(utf8.encode('/'));
      await t.pump();
      final screen = [for (var i = 0; i < 20; i++) t.row(i)];
      final popupEnd = screen.lastIndexWhere((l) => l.contains('└'));
      expect(popupEnd, greaterThan(0));
      expect(screen.indexWhere((l) => l.startsWith('mode')), popupEnd + 1);
      t.close();
    });

    test('inline: a tall popup caps the live area at the terminal height minus one', () async {
      final f = TextField();
      final t = testSession<int>(
        0,
        (s, app) => Screen(status: 'mode', (r) {
          r.input(f, suggest: (w) => [for (var i = 0; i < 30; i++) '/c$i']);
        }),
        width: 30,
        height: 8,
        fullscreen: false,
      );
      await t.pump();
      t.bytes(utf8.encode('/'));
      await t.pump();
      // Each inline paint ends by parking below the live area.
      final paints = t.output.split('\n\x1b[J');
      final last = paints[paints.length - 2];
      expect('\x1b[2K'.allMatches(last).length, 7);
      t.close();
    });
  });

  group('App (in-memory)', () {
    test('notify is a no-op while focus is reported, OSC 9/777 after blur', () async {
      late App<int> app;
      final t = testSession<int>(0, (s, a) {
        app = a;
        return Screen((r) {});
      });
      await t.pump();
      t.bytes(utf8.encode('\x1b[I'));
      await t.pump();
      app.notify('done');
      expect(t.output, isNot(contains('\x1b]9;')));
      t.bytes(utf8.encode('\x1b[O')); // blur
      await t.pump();
      app.notify('done');
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
      late App<int> app;
      final t = testSession<int>(0, (s, a) {
        app = a;
        return Screen((r) {});
      });
      await t.pump();
      app.copyToClipboard('hé');
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

  group('pty', () {
    test('keys route to bindings; shift+tab; bound ctrl+c lives', () async {
      final (log, _, _) = await _pty(
        mode: 'keys',
        feeds: const [(1.0, r'aq'), (1.3, r'\x1b[Z'), (1.5, r'\x1b[A'), (1.7, r' '), (1.9, r'\x03'), (2.5, r'\x1b')],
      );
      expect(log.split('\n'), ['a', 'q', 'shift+tab', 'up', 'space', 'ctrl+c', 'escape']);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('modifiers, insert, SS3, alt; focus reports and clicks add no keys', () async {
      final (log, _, _) = await _pty(
        mode: 'keys',
        feeds: const [
          (1.0, r'\x1b[3;5~'),
          (1.2, r'\x1b[I'),
          (1.4, r'\x1bOP'),
          (1.6, r'\x1b[2~'),
          (1.8, r'\x1bOH'),
          (2.0, r'\x1b[1;5A'),
          (2.2, r'\x1bx'),
          (2.6, r'\x1b[M\x00\x05\x06'),
          (3.0, r'\x1b'),
        ],
      );
      expect(log.split('\n'), ['ctrl+delete', 'f1', 'insert', 'home', 'ctrl+up', 'alt+x', 'escape']);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('CJK rows render in place, autowrap off, leave restores', () async {
      final (_, bytes, _) = await _pty(mode: 'cjk', rows: 10, cols: 30);
      final out = utf8.decode(bytes, allowMalformed: true);
      expect(out, contains('\x1b[?7l'));
      final t = _Term(30, 10)..feed(out.substring(0, out.indexOf('\x1b[?1049l')));
      expect(t.row(0), '日 本 語abc${' ' * 19}');
      expect(t.row(1), 'plain row two${' ' * 17}');
      for (final mode in ['?7h', '?1049l', '?1000l', '?1003l', '?1006l', '?1004l', '?2004l', '?25h', '<u']) {
        expect(out, contains('\x1b[$mode'), reason: 'restores $mode');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('tabs expand, controls become U+FFFD, newlines split rows', () async {
      final (_, bytes, _) = await _pty(mode: 'controls');
      final out = utf8.decode(bytes, allowMalformed: true);
      final t = _Term(80, 24)..feed(out.substring(out.indexOf('\x1b[?1049h') + 8, out.indexOf('\x1b[?1049l')));
      expect(t.row(0).trimRight(), 'x       y');
      expect(t.row(1).trimRight(), 'a�b�c');
      expect([t.row(2), t.row(3), t.row(4)].map((r) => r.trimRight()), ['l1', 'l2', 'l3']);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a second run in the same process works', () async {
      final (log, _, _) = await _pty(mode: 'second');
      expect(log, 'second-ok');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('widgets: input, list click and keys, button', () async {
      final (log, _, _) = await _pty(
        mode: 'widgets',
        feeds: const [
          (1.5, r'hi'),
          (1.8, r'\x7f'),
          (2.1, r'\x1b[<0;2;5M'), // click row 4 of the screen = item 3
          (2.4, r'\x1b[B'),
          (2.7, r'\t\r'), // focus the button, press it
          (3.0, r'\x1b'),
        ],
      );
      expect(log.split('\n'), ['escape', 'query=h', 'sel=4', 'go=true']);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('inline: the live area sits below the prompt; print scrolls back', () async {
      final (log, bytes, _) = await _pty(
        mode: 'inline',
        rows: 12,
        cols: 30,
        feeds: const [(1.5, r'hello'), (1.8, r'\r'), (2.4, r'\x1b')],
      );
      expect(log, 'escape');
      final out = utf8.decode(bytes, allowMalformed: true);
      expect(out, isNot(contains('\x1b[?1049h')), reason: 'no alternate screen');
      expect(out, isNot(contains('\x1b[?1000h')), reason: 'the mouse stays with the terminal');
      expect(out, contains('> hello'));
      expect(out, contains('mode line'));
      expect(out.substring(out.indexOf('> hello')), contains('┌'), reason: 'the live area redraws below');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('LANG=C draws ASCII; NO_COLOR drops colours', () async {
      final (_, bytes, _) = await _pty(
        mode: 'ascii',
        // PYTHONCOERCECLOCALE=0: python would set LC_CTYPE=C.UTF-8 for the child.
        env: {'LANG': 'C', 'LC_ALL': '', 'LC_CTYPE': 'C', 'NO_COLOR': '1', 'PYTHONCOERCECLOCALE': '0'},
      );
      final out = utf8.decode(bytes, allowMalformed: true);
      final body = out.substring(out.indexOf('\x1b[?1049h'), out.indexOf('\x1b[?1049l'));
      expect(body, contains('+- t -'));
      expect(body, isNot(matches(RegExp('[─━│┌]'))));
      expect(body, isNot(contains('38;5;')));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('work landing inside the 60 fps gap is still painted', () async {
      final (_, bytes, _) = await _pty(mode: 'late', feeds: const [(1.5, 'a'), (2.5, 'q')]);
      final out = utf8.decode(bytes, allowMalformed: true);
      final t = _Term(80, 24)..feed(out);
      expect(t.row(0).trimRight(), 'two');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('external SIGINT becomes ctrl+c and restores the terminal', () async {
      final (_, bytes, code) = await _pty(mode: 'sigint', feeds: const [], signals: const [(0.5, 'INT')]);
      final out = utf8.decode(bytes, allowMalformed: true);
      final end = out.indexOf('\x1b[?1049l');
      expect(end, isNot(-1));
      final t = _Term(80, 24)..feed(out.substring(0, end));
      expect(t.row(0).trimRight(), 'saw ctrl+c');
      expect(code, 0);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('ctrl+z stops the app with the terminal restored; fg takes it back', () async {
      if (Platform.isWindows) markTestSkipped('needs a POSIX pty');
      await _needPython();
      final root = Directory.current.path;
      final res = await Process.run('python3', [
        '$root/test/tui_pty/suspend_drive.py',
        '--',
        Platform.resolvedExecutable,
        '$root/test/tui_pty/probe.dart',
        '${Directory.systemTemp.path}/tui-suspend.log',
        'keys',
      ], workingDirectory: root);
      expect(
        '${res.stdout}'.trim(),
        'isig_off=True stopped=True left=True isig_back=True reentered=True isig_off_again=True exit=0',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    // Regression: the loop ran inside the redraw zone, so its own timers
    // woke it forever: timers, I/O and signals starved, spinners froze.
    test('while idle, spinners advance, timers paint and SIGTERM restores', () async {
      final (_, bytes, code) = await _pty(mode: 'alive', feeds: const [], signals: const [(1.5, 'TERM')]);
      final out = utf8.decode(bytes, allowMalformed: true);
      expect(code, 143);
      final end = out.indexOf('\x1b[?1049l');
      expect(end, isNot(-1), reason: 'SIGTERM restores the terminal');
      final frames = {for (final m in RegExp('[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]').allMatches(out)) m[0]};
      expect(frames.length, greaterThanOrEqualTo(3));
      final t = _Term(80, 24)..feed(out.substring(0, end));
      expect(t.row(1).trimRight(), 'timer fired');
    }, timeout: const Timeout(Duration(seconds: 60)));

    // Regression: the zone woke the loop before a callback ran, so a state
    // set in a future's continuation painted only on the next event.
    test('a change made in a future continuation paints with no further event', () async {
      final (_, bytes, code) = await _pty(mode: 'idle', feeds: const [], signals: const [(1.5, 'TERM')]);
      final out = utf8.decode(bytes, allowMalformed: true);
      expect(code, 143);
      final t = _Term(80, 24)..feed(out.substring(0, out.indexOf('\x1b[?1049l')));
      expect(t.row(0).trimRight(), 'loaded');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

/// Run the probe helper under a real pty; return (log text, terminal bytes).
/// Skips (not fails) where a pty is unavailable: Windows, or no python3.
Future<(String, List<int>, int?)> _pty({
  required String mode,
  List<(double, String)> feeds = const [(1.0, r'\x1b')],
  List<(double, String)> signals = const [],
  int rows = 24,
  int cols = 80,
  Map<String, String> env = const {},
}) async {
  if (Platform.isWindows) markTestSkipped('needs a POSIX pty');
  // `dart test` compiles the test into a temp dir, so Platform.script is
  // useless for locating helpers; the working directory is the package root.
  final root = Directory.current.path;
  await _needPython();
  final log = File('${Directory.systemTemp.path}/tui-pty-${DateTime.now().microsecondsSinceEpoch}.log');
  final res = await Process.run(
    'python3',
    [
      '$root/test/tui_pty/drive.py',
      '--size',
      '$rows',
      '$cols',
      for (final (delay, bytes) in feeds) ...['--feed', '$delay', bytes],
      for (final (delay, name) in signals) ...['--signal', '$delay', name],
      '--',
      Platform.resolvedExecutable,
      '$root/test/tui_pty/probe.dart',
      log.path,
      mode,
    ],
    workingDirectory: root,
    environment: {'LANG': 'en_US.UTF-8', 'TERM': 'xterm-256color', ...env},
    stdoutEncoding: null,
  );
  if (res.exitCode != 0) fail('pty driver failed: ${res.stderr}');
  // Regression: a stdin listener kept every app alive after Tui.run.
  if ('${res.stderr}'.contains('did not exit')) {
    fail('the probe did not exit after Tui.run returned');
  }
  final code = RegExp(r'exit=(-?\d+)').firstMatch('${res.stderr}')?[1];
  var text = '';
  try {
    text = (await log.readAsString()).trim();
    await log.delete();
  } catch (_) {}
  return (text, res.stdout as List<int>, code == null ? null : int.parse(code));
}

Future<void> _needPython() async {
  try {
    final py = await Process.run('python3', ['--version']);
    if (py.exitCode != 0) markTestSkipped('needs python3 for the pty driver');
  } catch (_) {
    markTestSkipped('needs python3 for the pty driver');
  }
}

/// A tiny VT100 for assertions: CUP, SGR, `?` modes, chars with widths
/// from the same table as the engine unless [wide] says otherwise.
final class _Term {
  _Term(this.w, this.h, {this.wide = const {}}) : _cells = _blank(w, h);

  int w;
  int h;
  final Set<String> wide;
  List<List<(String, Set<String>)>> _cells;
  var _x = 0;
  var _y = 0;
  var _style = <String>{};

  static List<List<(String, Set<String>)>> _blank(int w, int h) =>
      List.generate(h, (_) => List.filled(w, (' ', const <String>{})));

  void resize(int nw, int nh) {
    w = nw;
    h = nh;
    _cells = _blank(w, h);
    _x = _y = 0;
  }

  String row(int y) => _cells[y].map((c) => c.$1).join();
  List<String> cells(int y) => _cells[y].map((c) => c.$1).toList();
  Set<String> styleAt(int x, int y) => _cells[y][x].$2;

  void feed(String s) {
    final runes = s.runes.toList();
    var i = 0;
    while (i < runes.length) {
      final r = runes[i];
      if (r == 0x1b && i + 1 < runes.length && runes[i + 1] == 0x5b) {
        var j = i + 2;
        while (j < runes.length && (runes[j] < 0x40 || runes[j] > 0x7e)) {
          j++;
        }
        final params = String.fromCharCodes(runes.sublist(i + 2, j));
        final fin = String.fromCharCode(runes[j]);
        if (fin == 'H' && !params.startsWith('?')) {
          final p = params.isEmpty ? ['1', '1'] : params.split(';');
          _y = int.parse(p[0]) - 1;
          _x = int.parse(p[1]) - 1;
        } else if (fin == 'm') {
          final codes = params.split(';').map(int.tryParse).toList();
          for (var k = 0; k < codes.length; k++) {
            final code = codes[k];
            if (code == null || code == 0) _style = {};
            if (code == 1) _style = {..._style, 'bold'};
            if (code == 7) _style = {..._style, 'inverse'};
            if (code == 38 && k + 2 < codes.length) {
              _style = {..._style, 'fg${codes[k + 2]}'};
              k += 2;
            }
          }
        } else if (fin == 'J') {
          _cells = _blank(w, h);
        }
        i = j + 1;
        continue;
      }
      i++;
      if (r < 0x20) {
        fail('raw control ${r.toRadixString(16)} reached the terminal');
      }
      final ch = String.fromCharCode(r);
      if (term.isZeroWidth(r)) {
        final px = (_x - 1).clamp(0, w - 1);
        _cells[_y][px] = ('${_cells[_y][px].$1}$ch', _cells[_y][px].$2);
        continue;
      }
      final cw = wide.contains(ch) ? 2 : term.cellWidth(r);
      if (_y < 0 || _y >= h) continue;
      final x = _x.clamp(0, w - 1);
      _cells[_y][x] = (ch, _style);
      if (cw == 2 && x + 1 < w) _cells[_y][x + 1] = ('', _style);
      // Autowrap is off: the cursor sticks at the last column.
      _x = x + cw >= w ? w - 1 : x + cw;
    }
  }
}
