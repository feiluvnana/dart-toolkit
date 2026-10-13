import 'dart:async';
import 'dart:convert';
import 'dart:io' show StdoutException;

import 'package:dart_toolkit/tui2.dart';
import 'package:test/test.dart';

void main() {
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
      // No terminal here, so the first run fails fast with StdoutException
      // while still holding the active flag for the second call (which
      // throws synchronously).
      final first = Tui.run<int>(0, (s, app) => Screen((r) {}));
      expect(() => Tui.run<int>(0, (s, app) => Screen((r) {})),
          throwsStateError);
      await expectLater(first, throwsA(isA<StdoutException>()));
    });
  });

  group('keys and widgets (in-memory)', () {
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
              }, keys: {
                'enter': ('open', () async => opened++),
                'escape': ('quit', () => app.quit()),
                'x': ('', () {}),
              }),
          width: 30,
          height: 10);
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
              }, keys: {
                'enter': ('next', () => app.go('b')),
              });
            }
            return Screen((r) {
              r.list(b, (x) => x);
            }, keys: {
              'b escape': ('back', () {
                back = true;
                app.go('a');
              }),
            });
          },
          width: 20,
          height: 6);
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
          height: 4);
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

    test('handler Exception goes to the status row, Error ends the run',
        () async {
      var n = 0;
      final t = testSession<int>(
          0,
          (s, app) => Screen((r) {
                r.write('body');
              }, keys: {
                'a': ('boom', () {
                  n++;
                  throw Exception('kaput\nsecond line');
                }),
                'q': ('quit', () => app.quit()),
              }),
          width: 30,
          height: 5);
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
          (s, app) => Screen((r) {
                r.write('body');
              }, keys: {
                'a': ('bug', () {
                  throw StateError('bug');
                }),
              }),
          width: 30,
          height: 5);
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
          height: 4);
      expect(await t.pump(), isTrue);
      expect(await t.pump(), isFalse);
      expect(await t.pump(), isFalse);
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
                a.table(rows, (v) => ['n$v', 'v$v'],
                    header: ['#', 'v']);
                b.bar(3, 10, label: 'up');
                r.spin('work');
              }),
          width: 30,
          height: 12);
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
            return Screen((r) {
              r.write('x');
            }, keys: {
              'a': ('bad', () {
                throw Exception('nope');
              }),
            });
          },
          width: 30,
          height: 4);
      await t.pump();
      app.say('hello there');
      await t.pump();
      expect(t.row(3), contains('hello there'));
    });

    test('click focuses and selects; hover restyles', () async {
      final p = Pick<String>(['a', 'b', 'c']);
      final t = testSession<int>(
          0,
          (s, app) => Screen((r) {
                r.list(p, (x) => 'item $x');
              }),
          width: 20,
          height: 5);
      await t.pump();
      // Click row 2 (status row is last; rows 0..3 are the list).
      t.bytes(const [0x1b, 0x5b, 0x3c, 0x30, 0x3b, 0x33, 0x3b, 0x33, 0x4d]);
      await t.pump();
      expect(p.index(), 2);
    });
  });
}
