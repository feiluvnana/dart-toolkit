import 'dart:async';

import 'package:dart_toolkit/core.dart';
import 'package:dart_toolkit/tui.dart';
import 'package:test/test.dart';

/// Lets input reach the app and the frame it causes reach the terminal.
Future<void> pump([int turns = 3]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

String plain(Widget w, int width, {int? height}) => w.render(width, height: height, color: false);

/// Runs an app that records every event it is sent, on [term].
Future<List<Object>> events(FakeTerminal term, Future<void> Function() drive) async {
  Tui.terminal = term;
  final seen = <Object>[];
  final run = Tui.run<int>(
    0,
    view: (_) => Label('x'),
    update: (s, e) => e == const Key('q', ctrl: true) ? Tui.quit() : (seen..add(e)).length,
  );
  await pump();
  await drive();
  await pump();
  term.press(const Key('q', ctrl: true));
  await run;
  return seen;
}

void main() {
  tearDown(() async {
    // A failed test can leave its app running; ^C ends it so the next one can start.
    (Tui.terminal as FakeTerminal?)?.type('\x03');
    await pump();
    Tui.terminal = null;
  });

  group('input decoding', () {
    Future<List<Object>> decode(List<Object> chunks, {int waitMs = 0}) {
      final term = FakeTerminal();
      return events(term, () async {
        for (final c in chunks) {
          c is String ? term.type(c) : term.send(c as List<int>);
          await pump();
        }
        if (waitMs > 0) await Future<void>.delayed(Duration(milliseconds: waitMs));
      });
    }

    final table = <String, Object>{
      'a': const Char('a'),
      '世': const Char('世'),
      '\r': Key.enter,
      '\n': Key.enter,
      '\t': Key.tab,
      '\x1b[Z': Key.backTab,
      '\x7f': Key.backspace,
      '\x1b[3~': Key.delete,
      '\x1b[2~': Key.insert,
      '\x1b[A': Key.up,
      '\x1b[B': Key.down,
      '\x1b[C': Key.right,
      '\x1b[D': Key.left,
      '\x1bOA': Key.up,
      '\x1b[H': Key.home,
      '\x1b[F': Key.end,
      '\x1b[1~': Key.home,
      '\x1b[4~': Key.end,
      '\x1b[5~': Key.pageUp,
      '\x1b[6~': Key.pageDown,
      '\x1bOP': Key.f(1),
      '\x1b[15~': Key.f(5),
      '\x1b[24~': Key.f(12),
      '\x01': const Key('a', ctrl: true),
      '\x1b[1;5C': const Key('right', ctrl: true),
      '\x1b[1;2A': const Key('up', shift: true),
      '\x1b[3;3~': const Key('delete', alt: true),
      '\x1bx': const Char('x', alt: true),
      '\x1b\x7f': const Key('backspace', alt: true),
    };
    for (final MapEntry(:key, :value) in table.entries) {
      test('${key.replaceAll('\x1b', 'ESC')} is $value', () async {
        expect(await decode([key]), [value]);
      });
    }

    test('a UTF-8 character split across reads is one character', () async {
      expect(
        await decode([
          [0xe4, 0xb8],
          [0x96, 0x61],
        ]),
        [const Char('世'), const Char('a')],
      );
    });

    test('a combining mark joins the character before it', () async {
      expect(await decode(['é']), [const Char('é')]);
    });

    test('a lone ESC is Esc once the timeout passes', () async {
      expect(await decode(['\x1b'], waitMs: 60), [Key.esc]);
    });

    test('an escape sequence split across reads is still one key', () async {
      expect(await decode(['\x1b', '[A']), [Key.up]);
    });

    test('bracketed paste is one Paste with newlines', () async {
      final got = await decode(['\x1b[200~one\r\ntwo\x1b[201~']);
      expect(got.single, isA<Paste>().having((p) => p.text, 'text', 'one\ntwo'));
    });

    test('SGR mouse reports press, release and wheel at 0-based cells', () async {
      final got = await decode(['\x1b[<0;5;3M', '\x1b[<0;5;3m', '\x1b[<65;1;1M']);
      expect(
        [for (final m in got.cast<Mouse>()) '${m.kind.name} ${m.x},${m.y}'],
        ['press 4,2', 'release 4,2', 'wheelDown 0,0'],
      );
    });

    test('FakeTerminal.press encodes what the decoder reads back', () async {
      const keys = [Key.up, Key.pageDown, Key.backTab, Key.enter, Key('k', ctrl: true), Key('left', ctrl: true)];
      final term = FakeTerminal();
      expect(
        await events(term, () async {
          for (final k in keys) {
            term.press(k);
          }
        }),
        keys,
      );
    });
  });

  group('widths', () {
    test('wide, emoji, combining and joined characters', () {
      expect(Label('世界').width, 4);
      expect(Label('👍').width, 2);
      expect(Label('é').width, 1);
      expect(Label('👨‍👩‍👧').width, 2);
    });

    test('a wide character that does not fit is not split', () {
      expect(plain(Label('ab世', wrap: false), 3), 'ab…');
      expect(plain(Paint((c) => c.text(0, 0, 'ab世')), 3), 'ab');
    });
  });

  group('layout', () {
    test('fixed, flex and percent split a row, gaps between', () {
      final row = HStack([
        Label('a', style: const Style(reverse: true)).fixed(4),
        Label('b').flex(),
        Label('c').percent(25),
      ], gap: 1);
      expect(plain(row, 21), 'a    b           c');
    });

    test('flex weights divide what is left', () {
      final row = HStack([Label('a').flex(), Label('b').flex(2), Label('c').flex()]);
      expect(plain(row, 12), 'a  b     c');
    });

    test('a column stacks natural heights and gives flex the rest', () {
      final col = VStack([Label('top'), Label('mid').flex(), Label('end')]);
      expect(plain(col, 5, height: 5), 'top\nmid\n\n\nend');
      expect(col.heightAt(5), 3);
    });

    test('children past the end get nothing', () {
      expect(plain(VStack([Label('a'), Label('b'), Label('c')]), 3, height: 2), 'a\nb');
    });
  });

  group('widgets', () {
    test('Label wraps at words and aligns', () {
      expect(plain(Label('the quick brown fox'), 10), 'the quick\nbrown fox');
      expect(plain(Label('hi', align: Align.right), 5), '   hi');
      expect(plain(Label('hi', align: Align.center), 6), '  hi');
      expect(plain(Label('a\nb'), 5), 'a\nb');
    });

    test('Label.spans keeps each span its style', () {
      final out = Label.spans([const Span('a', Style(bold: true)), const Span('b')]).render(4, color: true);
      expect(out, contains('\x1b[0;1ma\x1b[0mb'));
    });

    test('Box draws borders, title and padding', () {
      expect(plain(Box(Label('hi'), title: 'T'), 10), '╭─ T ────╮\n│ hi     │\n╰────────╯');
      expect(plain(Box(Label('hi'), border: Border.double, padding: (0, 0)), 6), '╔════╗\n║hi  ║\n╚════╝');
      expect(plain(Box(Label('hi'), border: Border.ascii), 6), '+----+\n| hi |\n+----+');
      expect(plain(Box(Label('hi'), border: Border.none, title: 'T'), 6), 'T\n hi');
    });

    test('Menu shows the cursor, checks and a scrollbar', () {
      final pick = Choice(index: 3, multi: true, checked: [0]);
      expect(plain(Menu(['a', 'b', 'c', 'd', 'e'], pick), 8, height: 3), '  ○ b  │\n  ○ c  ┃\n› ○ d  ┃');
    });

    test('a running app leaves a restore for an exit that skips finally', () async {
      final term = Tui.terminal = FakeTerminal(width: 20, height: 5);
      final run = Tui.run<int>(0, view: (_) => Label('x'), update: (s, e) => s);
      await pump();
      expect(term.isAltScreen, isTrue);
      expect(IoBridge.restores, hasLength(1));
      IoBridge.restores.first(); // what `Lifecycle.exit` does before `exit`
      expect(term.isAltScreen, isFalse);
      expect(term.isCursorVisible, isTrue);
      expect(term.isOpen, isFalse);
      expect(IoBridge.restores, isEmpty);
      run.ignore();
    });

    test('Menu filters as typed and highlights the match', () async {
      final term = Tui.terminal = FakeTerminal(width: 20, height: 5);
      final pick = Choice(filter: true);
      final run = Tui.run<String?>(
        null,
        view: (_) => Menu(['apple', 'banana', 'cherry'], pick),
        update: (s, e) => e == Key.enter ? Tui.quit(['apple', 'banana', 'cherry'][pick.index]) : s,
      );
      await pump();
      term.type('an');
      await pump();
      expect(term.screen, '› banana');
      term.press(Key.enter);
      expect(await run, 'banana');
    });

    test('typed-ahead keys in one read filter before Enter picks', () async {
      final term = Tui.terminal = FakeTerminal(width: 20, height: 5);
      final pick = Choice(filter: true);
      const items = ['apple', 'banana', 'cherry'];
      final run = Tui.run<String?>(
        null,
        view: (_) => Menu(items, pick),
        update: (s, e) => e == Key.enter ? Tui.quit(items[pick.index]) : s,
      );
      await pump();
      term.type('chy\r');
      expect(await run, 'cherry');
    });

    test('Menu builders get the item context', () {
      final menu = Menu(
        Mode.values,
        Choice(index: 1),
        item: (c) => Label('${c.index}:${c.label}${c.selected ? '*' : ''}'),
      );
      expect(plain(menu, 10), '0:debug\n1:release*');
    });

    test('Grid fits columns, truncates, and selects', () {
      final grid = Grid(
        [
          ['readme.md', 120],
          ['a-very-long-name.dart', 4500],
        ],
        columns: ['Name', 'Size'],
        choice: Choice(index: 1),
      );
      expect(plain(grid, 22), '  Name            Size\n  readme.md       120\n› a-very-long-n…  4500');
    });

    test('Grid cell builder', () {
      final grid = Grid([
        [1, 2],
      ], cell: (c) => Label('<${c.value}>'));
      expect(plain(grid, 10), '<1>  <2>');
    });

    test('Field shows placeholder, mask, and scrolls to the cursor', () {
      expect(plain(Field(prompt: '> ', placeholder: 'name'), 10), '> name');
      expect(plain(Field(text: 'secret', mask: '*'), 10), '******');
      expect(plain(Field(text: 'abcdefghij'), 5), 'ghij');
      expect(plain(Field(text: 'x', validate: (v) => v.length < 3 ? 'too short' : null), 12), 'x\ntoo short');
    });

    test('Gauge, Progress.bar and the bar builder', () {
      expect(plain(Gauge(0.5), 15), '█████░░░░░  50%');
      const p = Progress(bytes: 50, bytesTotal: 200, elapsed: Duration(seconds: 2));
      expect(p.bar(8, fill: '=', head: '>', empty: '.'), '==>.....');
      expect(p.speed, 25);
      expect(p.eta, const Duration(seconds: 6));
      expect(plain(Gauge.of(p, bar: (p, w) => Label('${p.percent}% of $w')), 10), '25% of 10');
    });

    test('Spin shows a frame and asks to animate', () {
      expect(plain(Spin('Loading'), 12), '⠋ Loading');
      expect(plain(Spin('x', frames: ['-', '+']), 4), '- x');
    });

    test('Tabs marks the chosen tab', () {
      expect(plain(Tabs(['One', 'Two'], Choice(index: 1)), 12), ' One │ Two');
    });

    test('themed overrides only what it names', () {
      final w = Box(Label('x')).themed(const TuiTheme(border: Border.ascii));
      expect(plain(w, 5), '+---+\n| x |\n+---+');
      final menu = Menu(['a'], Choice()).themed(const TuiTheme(pointer: '>'));
      expect(plain(menu, 5), '> a');
    });
  });

  group('rendering', () {
    test('a frame after the first writes only the changed cells', () async {
      final term = Tui.terminal = FakeTerminal(width: 20, height: 4);
      final run = Tui.run<String>(
        'hello',
        view: (s) => VStack([Label(s), Label('static line')]),
        update: (s, e) => switch (e) {
          Char(:final char) => 'hell$char',
          _ => Tui.quit(),
        },
      );
      await pump();
      expect(term.screen, 'hello\nstatic line');
      term.type('O');
      await pump();
      expect(term.screen, 'hellO\nstatic line');
      expect(Io.stripAnsi(term.writes.last), 'O');
      expect(term.writes.last, contains('\x1b[1;5H'));
      term.press(Key.esc);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await run;
    });

    test('colour falls back to what the terminal shows', () async {
      Future<String> frame(int colors) async {
        final term = Tui.terminal = FakeTerminal(width: 4, height: 1, colors: colors);
        final run = Tui.run(
          0,
          view: (_) => Label('x', style: const Style(fg: Color.rgb(255, 0, 0))),
          update: (s, e) => Tui.quit(),
        );
        await pump();
        term.type('q');
        await run;
        return term.writes.join();
      }

      expect(await frame(1 << 24), contains('38;2;255;0;0'));
      expect(await frame(256), contains('38;5;196'));
      expect(await frame(16), contains('\x1b[0;91m'));
      expect(await frame(0), isNot(contains('91')));
    });

    test('a resize redraws the whole screen at the new size', () async {
      final term = Tui.terminal = FakeTerminal(width: 10, height: 3);
      final sizes = <String>[];
      final run = Tui.run(
        0,
        view: (_) => Label('x', align: Align.right),
        update: (s, e) {
          if (e is Resize) sizes.add('${e.width}x${e.height}');
          return e is Char ? Tui.quit() : s;
        },
      );
      await pump();
      term.resize(6, 2);
      await pump();
      expect(term.screen, '     x');
      term.type('q');
      await run;
      expect(sizes, ['6x2']);
    });
  });

  group('app', () {
    test('keys update state, the terminal is restored, run returns the state', () async {
      final term = Tui.terminal = FakeTerminal(width: 20, height: 3);
      final run = Tui.run(
        0,
        view: (n) => Box(Label('n=$n'), title: 'Count'),
        update: (n, e) => switch (e) {
          Key.up => n + 1,
          Key.down => n - 1,
          Char(char: 'q') => Tui.quit(),
          _ => n,
        },
      );
      await pump();
      expect(term.isOpen && term.isAltScreen && !term.isCursorVisible && term.isPaste, isTrue);
      term
        ..press(Key.up)
        ..press(Key.up)
        ..press(Key.down)
        ..press(Key.up);
      await pump();
      expect(term.screen, '╭─ Count ──────────╮\n│ n=2              │\n╰──────────────────╯');
      term.type('q');
      expect(await run, 2);
      expect(term.isOpen || term.isAltScreen || !term.isCursorVisible || term.isPaste, isFalse);
    });

    test('quit with a state returns it', () async {
      final term = Tui.terminal = FakeTerminal();
      final run = Tui.run('a', view: (s) => Label(s), update: (s, e) => Tui.quit('done'));
      await pump();
      term.type('x');
      expect(await run, 'done');
    });

    test('an exception in update ends the app with it and restores the terminal', () async {
      final term = Tui.terminal = FakeTerminal();
      final run = Tui.run(0, view: (_) => Label('x'), update: (_, e) => throw StateError('boom'));
      await pump();
      term.type('x');
      await expectLater(run, throwsA(isA<StateError>()));
      expect(term.isOpen || term.isAltScreen || !term.isCursorVisible, isFalse);
    });

    test('an exception in view ends the app too', () async {
      Tui.terminal = FakeTerminal();
      await expectLater(Tui.run(0, view: (_) => throw StateError('view'), update: (s, _) => s), throwsStateError);
    });

    test('^C throws CancelledException and restores the terminal', () async {
      final term = Tui.terminal = FakeTerminal();
      final run = Tui.run(0, view: (_) => Label('x'), update: (s, _) => s);
      await pump();
      term.type('\x03');
      await expectLater(run, throwsA(isA<CancelledException>()));
      expect(term.isOpen || term.isAltScreen, isFalse);
    });

    test('a cancelled Cancel.scope ends the app and restores the terminal', () async {
      final term = Tui.terminal = FakeTerminal();
      final token = CancelToken();
      final run = Cancel.scope(
        () => Tui.run(0, view: (_) => Label('x'), update: (s, _) => s),
        token: token,
      );
      await pump();
      token.cancel('stop');
      await expectLater(run, throwsA(isA<CancelledException>().having((e) => e.message, 'message', 'stop')));
      expect(term.isOpen || term.isAltScreen, isFalse);
    });

    test('one app at a time', () async {
      final term = Tui.terminal = FakeTerminal();
      final run = Tui.run(0, view: (_) => Label('x'), update: (s, e) => Tui.quit());
      await pump();
      await expectLater(Tui.run(0, view: (_) => Label('y'), update: (s, _) => s), throwsStateError);
      term.type('q');
      await run;
    });

    test('send delivers a future and a stream to update', () async {
      final term = Tui.terminal = FakeTerminal();
      final ticks = StreamController<Object>();
      final run = Tui.run<List<Object>>(
        [],
        init: () {
          Tui.send(Future.value('loaded'));
          Tui.send(ticks.stream);
          Tui.send('plain');
        },
        view: (s) => Label(s.join(',')),
        update: (s, e) => e is Char ? Tui.quit() : [...s, e],
      );
      await pump();
      ticks
        ..add(1)
        ..add(2);
      await pump();
      expect(term.screen, 'loaded,plain,1,2');
      term.type('q');
      expect(await run, ['loaded', 'plain', 1, 2]);
    });

    test('a failed job ends the app with its error', () async {
      Tui.terminal = FakeTerminal();
      final run = Tui.run(
        0,
        init: () => Tui.send(Future<Object>.error(const FormatException('bad'))),
        view: (_) => Label('x'),
        update: (s, _) => s,
      );
      await expectLater(run, throwsFormatException);
    });

    test('Tab moves the focus; keys reach the focused field first', () async {
      final term = Tui.terminal = FakeTerminal(width: 20, height: 4);
      final a = Field(prompt: 'a: '), b = Field(prompt: 'b: ');
      final seen = <Object>[];
      final run = Tui.run(
        0,
        view: (_) => VStack([a, b]),
        update: (s, e) {
          seen.add(e);
          return e == Key.enter ? Tui.quit() : s;
        },
      );
      await pump();
      term.type('hi');
      await pump();
      term
        ..press(Key.tab)
        ..type('yo');
      await pump();
      term.press(Key.enter);
      await run;
      expect((a.text, b.text), ('hi', 'yo'));
      expect(seen, [Key.enter]);
    });

    test('a click focuses the list under it and selects the row', () async {
      final term = Tui.terminal = FakeTerminal(width: 20, height: 6);
      final left = Choice(), right = Choice();
      final run = Tui.run(
        0,
        mouse: true,
        view: (_) => HStack([
          Menu(['a', 'b', 'c'], left).flex(),
          Menu(['x', 'y', 'z'], right).flex(),
        ]),
        update: (s, e) => e is Char ? Tui.quit() : s,
      );
      await pump();
      expect(term.isMouse, isTrue);
      term.mouse(12, 2);
      await pump();
      expect(right.index, 2);
      term.press(Key.up);
      await pump();
      expect((left.index, right.index), (0, 1));
      term.mouse(1, 0, MouseKind.wheelDown);
      await pump();
      expect(left.index, 1);
      term.type('q');
      await run;
      expect(term.isMouse, isFalse);
    });

    test('Field editing: words, cuts and history', () async {
      final term = Tui.terminal = FakeTerminal();
      final f = Field(text: 'one two three', history: ['old']);
      final run = Tui.run(0, view: (_) => f, update: (s, e) => e == Key.enter ? Tui.quit() : s);
      await pump();
      Future<void> keys(List<Key> ks) async {
        ks.forEach(term.press);
        await pump();
      }

      await keys([const Key('w', ctrl: true)]);
      expect(f.text, 'one two ');
      await keys([const Key('left', ctrl: true), const Key('left', ctrl: true)]);
      expect(f.cursor, 0);
      term.type('X');
      await pump();
      expect(f.text, 'Xone two ');
      await keys([const Key('k', ctrl: true)]);
      expect(f.text, 'X');
      await keys([Key.up]);
      expect(f.text, 'old');
      await keys([Key.down]);
      expect(f.text, '');
      term.type('\x1b[200~pa\nste\x1b[201~');
      await pump();
      expect(f.text, 'pa ste');
      await keys([const Key('u', ctrl: true)]);
      expect(f.text, '');
      term.press(Key.enter);
      await run;
    });

    test('a spinner animates without events', () async {
      final term = Tui.terminal = FakeTerminal(width: 10, height: 1);
      final run = Tui.run(
        0,
        view: (_) => Spin('x', frames: ['a', 'b'], interval: const Duration(milliseconds: 10)),
        update: (s, e) => Tui.quit(),
      );
      await pump();
      final first = term.writes.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(term.writes.length, greaterThan(first));
      term.type('q');
      await run;
    });

    test('the class form runs on the same engine', () async {
      final term = Tui.terminal = FakeTerminal();
      final app = _Counter();
      final run = app.run();
      await pump();
      term
        ..press(Key.up)
        ..press(Key.up);
      await pump();
      expect(term.screen, '2');
      term.press(Key.enter);
      expect(await run, 2);
      expect(app.state, 2);
    });
  });

  group('inline', () {
    test('draws under the cursor, grows and shrinks, and erases itself', () async {
      final term = Tui.terminal = FakeTerminal(width: 20, height: 6);
      term.write('before\r\n');
      final run = Tui.inline(
        2,
        view: (n) => VStack([for (var i = 0; i < n; i++) Label('row $i')]),
        update: (n, e) => switch (e) {
          Key.up => n + 1,
          Key.down => n - 1,
          _ => Tui.quit(),
        },
      );
      await pump();
      expect(term.isAltScreen, isFalse);
      expect(term.screen, 'before\nrow 0\nrow 1');
      term.press(Key.up);
      await pump();
      expect(term.screen, 'before\nrow 0\nrow 1\nrow 2');
      term
        ..press(Key.down)
        ..press(Key.down);
      await pump();
      expect(term.screen, 'before\nrow 0');
      term.type('q');
      expect(await run, 1);
      expect(term.screen, 'before');
      expect(term.isCursorVisible && !term.isOpen, isTrue);
    });

    test('^C erases the region and restores the terminal', () async {
      final term = Tui.terminal = FakeTerminal(width: 20, height: 6);
      final run = Tui.inline(0, view: (_) => VStack([Label('a'), Label('b')]), update: (s, _) => s);
      await pump();
      term.type('\x03');
      await expectLater(run, throwsA(isA<CancelledException>()));
      expect(term.screen, '');
      expect(term.isCursorVisible && !term.isOpen, isTrue);
    });

    test('a picker: filter, check, and return the checked', () async {
      final term = Tui.terminal = FakeTerminal(width: 30, height: 10);
      const fruits = ['apple', 'banana', 'cherry', 'date'];
      final pick = Choice(filter: true, multi: true);
      final run = Tui.inline<List<String>>(
        const [],
        view: (_) => VStack([Label('Pick: ${pick.query}'), Menu(fruits, pick)]),
        update: (s, e) => e == Key.enter ? Tui.quit([for (final i in pick.checked) fruits[i]]) : s,
      );
      await pump();
      term
        ..type(' ')
        ..press(Key.down)
        ..press(Key.down)
        ..type(' ');
      await pump();
      term.type('e');
      await pump();
      expect(term.screen, 'Pick: e\n  ◉ apple\n› ◉ cherry\n  ○ date');
      term.press(Key.enter);
      expect(await run, ['apple', 'cherry']);
    });
  });

  group('round 3 bugs', () {
    test('a click after the filter matches nothing keeps the app running', () async {
      final term = Tui.terminal = FakeTerminal(width: 20, height: 5);
      final pick = Choice(filter: true);
      final run = Tui.run<int>(
        0,
        mouse: true,
        view: (_) => Menu(['apple', 'banana'], pick),
        update: (s, e) => e == Key.enter ? Tui.quit(pick.index) : s,
      );
      await pump();
      term.type('zz');
      await pump();
      term.mouse(2, 0);
      await pump();
      term.press(Key.enter);
      expect(await run, -1);
    });

    test('Grid with a 0 width fits a terminal narrower than its gaps', () {
      expect(
        () => plain(
          Grid(
            [
              ['a', 'b', 'c', 'd'],
            ],
            widths: [3, 0, 3, 0],
          ),
          5,
        ),
        returnsNormally,
      );
    });

    test('Gauge of 0 / 0 is empty, not full', () {
      expect(plain(Gauge(0 / 0), 15), plain(Gauge(0), 15));
    });
  });
}

enum Mode { debug, release }

final class _Counter extends TuiApp<int> {
  _Counter() : super(0);

  @override
  Widget view(int n) => Label('$n');

  @override
  int update(int n, Object e) => switch (e) {
    Key.up => n + 1,
    Key.enter => Tui.quit(),
    _ => n,
  };
}
