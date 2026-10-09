import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/src/core.dart' show IoBridge;
import 'package:dart_toolkit/src/keys.dart' show KeysBridge;
import 'package:dart_toolkit/cli.dart' show Console;
import 'package:dart_toolkit/tui.dart';
import 'package:dart_toolkit/testing.dart';
import 'package:test/test.dart' hide Retry;

/// Lets input reach the app and the frame it causes reach the terminal.
Future<void> pump([int turns = 3]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

// The theme is given, so the goldens hold on a host whose terminal cannot draw Unicode.
String plain(Widget w, int width, {int? height}) =>
    w.render(width, height: height, theme: const TuiTheme(), color: false);

/// The terminal of the test running, which a failed test leaves an app on.
FakeTerminal? _term;

FakeTerminal fake({int width = 80, int height = 24, int colors = 256, bool unicode = true, bool kitty = false}) =>
    _term = FakeTerminal(width: width, height: height, colors: colors, unicode: unicode, kitty: kitty);

/// [body] on [term]: what it starts draws there.
Future<T> on<T>(FakeTerminal term, Future<T> Function() body) => Io.scope(body, terminal: term);

/// Runs an app that records every event it is sent, on [term].
Future<List<Object>> events(FakeTerminal term, Future<void> Function() drive) async {
  final seen = <Object>[];
  final run = on(
    term,
    () => Tui.run<int, Never>(
      0,
      draw: (_) => Label('x'),
      update: (s, e) => switch (e) {
        Start() => s,
        _ when e == const KeyPress('q', ctrl: true) => Tui.quit(s),
        _ => (seen..add(e)).length,
      },
    ),
  );
  await pump();
  await drive();
  await pump();
  term.press(const KeyPress('q', ctrl: true));
  await run;
  return seen;
}

void main() {
  tearDown(() async {
    // A failed test can leave its app running; ^C twice ends it so the next one can start.
    _term?.type('\x03\x03');
    await pump();
    _term = null;
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
      'a': const KeyPress('a'),
      '世': const KeyPress('世'),
      '\r': KeyPress.enter,
      '\n': KeyPress.enter,
      '\t': KeyPress.tab,
      '\x1b[Z': KeyPress.backTab,
      '\x7f': KeyPress.backspace,
      '\x1b[3~': KeyPress.delete,
      '\x1b[2~': KeyPress.insert,
      '\x1b[A': KeyPress.up,
      '\x1b[B': KeyPress.down,
      '\x1b[C': KeyPress.right,
      '\x1b[D': KeyPress.left,
      '\x1bOA': KeyPress.up,
      '\x1b[H': KeyPress.home,
      '\x1b[F': KeyPress.end,
      '\x1b[1~': KeyPress.home,
      '\x1b[4~': KeyPress.end,
      '\x1b[5~': KeyPress.pageUp,
      '\x1b[6~': KeyPress.pageDown,
      '\x1bOP': const KeyPress('f1'),
      '\x1b[15~': const KeyPress('f5'),
      '\x1b[24~': const KeyPress('f12'),
      '\x01': const KeyPress('a', ctrl: true),
      '\x1b[1;5C': const KeyPress('right', ctrl: true),
      '\x1b[1;2A': const KeyPress('up', shift: true),
      '\x1b[3;3~': const KeyPress('delete', alt: true),
      '\x1bx': const KeyPress('x', alt: true),
      '\x1b\x7f': const KeyPress('backspace', alt: true),
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
        [const KeyPress('世'), const KeyPress('a')],
      );
    });

    test('a combining mark joins the character before it', () async {
      expect(await decode(['é']), [const KeyPress('é')]);
    });

    test('a key decodes the same with and without the kitty protocol', () async {
      final legacy = await decode(['\x01', '\x08', '\t', '\r', '\x1bb', '\x1bB', 'A', '\x1c', '\x1b\x01', '\x00']);
      final kitty = await decode([
        '\x1b[97;6u', '\x1b[104;5u', '\x1b[105;5u', '\x1b[109;5u', '\x1b[98;3u', //
        '\x1b[98;4u', '\x1b[97;2u', '\x1b[92;5u', '\x1b[97;7u', '\x1b[32;5u',
      ]);
      expect(kitty, legacy);
      expect(legacy, [
        const KeyPress('a', ctrl: true),
        KeyPress.backspace,
        KeyPress.tab,
        KeyPress.enter,
        const KeyPress('b', alt: true),
        const KeyPress('B', alt: true, shift: true),
        const KeyPress('A', shift: true),
        const KeyPress('\\', ctrl: true),
        const KeyPress('a', ctrl: true, alt: true),
        const KeyPress(' ', ctrl: true),
      ]);
    });

    test('keypad keys are their digits, operators and Enter; unknown and past-Unicode codes drop', () async {
      expect(await decode(['\x1b[57400u', '\x1b[57412u', '\x1b[57414u', '\x1bOq', '\x1bOM', '\x1b[57417u']), [
        const KeyPress('1'),
        const KeyPress('-'),
        KeyPress.enter,
        const KeyPress('1'),
        KeyPress.enter,
        KeyPress.left,
      ]);
      expect(await decode(['\x1b[57376u', '\x1b[1114112u', '\x1b[55296u', 'x']), [const KeyPress('x')]);
    });

    test('a field under kitty types the keypad\'s digits', () async {
      final term = fake(kitty: true);
      final field = Field();
      final run = on(
        term,
        () => Tui.run<int, Never>(0, draw: (_) => field, update: (s, e) => e == KeyPress.esc ? Tui.quit(s) : s),
      );
      await pump();
      term.type('1\x1b[57400u\x1b[57401u');
      await pump();
      expect(field.text, '112');
      term.press(KeyPress.esc);
      await run;
    });

    test('focus reports are Focus and Blur', () async {
      final term = FakeTerminal();
      var reporting = false;
      final got = await events(term, () async {
        reporting = term.isFocusReport;
        term
          ..focus()
          ..blur();
      });
      expect(reporting, isTrue);
      expect(got, [const Focus(), const Blur()]);
      expect(term.isFocusReport, isFalse);
    });

    test('a lone ESC is Esc once the timeout passes', () async {
      expect(await decode(['\x1b'], waitMs: 60), [KeyPress.esc]);
    });

    test('an escape sequence split across reads is still one key', () async {
      expect(await decode(['\x1b', '[A']), [KeyPress.up]);
    });

    test('a UTF-8 character cut by a slow read waits past the ESC timeout', () async {
      final term = FakeTerminal();
      final got = await events(term, () async {
        term.send([0xe3]);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        term.send([0x81, 0x82]);
      });
      expect(got, [const KeyPress('あ')]);
    });

    test('a byte that does not continue a character ends it, and is read on its own', () async {
      expect(
        await decode([
          [0xe3, 0x61],
        ]),
        [const KeyPress('\ufffd'), const KeyPress('a')],
      );
    });

    test('a paste whose end marker is cut by a slow read still ends', () async {
      final term = FakeTerminal();
      final got = await events(term, () async {
        term.type('\x1b[200~hello\x1b');
        await Future<void>.delayed(const Duration(milliseconds: 60));
        term.type('[201~x');
      });
      expect(got, [isA<Paste>().having((p) => p.text, 'text', 'hello'), const KeyPress('x')]);
    });

    test('bracketed paste is one Paste with newlines', () async {
      final got = await decode(['\x1b[200~one\r\ntwo\x1b[201~']);
      expect(got.single, isA<Paste>().having((p) => p.text, 'text', 'one\ntwo'));
    });

    test('SGR mouse reports press, release and wheel at 0-based cells', () async {
      final got = await decode(['\x1b[<0;5;3M', '\x1b[<0;5;3m', '\x1b[<65;1;1M']);
      expect(
        [for (final m in got.cast<Pointer>()) '${m.kind.name} ${m.x},${m.y}'],
        ['press 4,2', 'release 4,2', 'wheelDown 0,0'],
      );
    });

    test('FakeTerminal.press encodes what the decoder reads back', () async {
      const keys = [
        KeyPress.up,
        KeyPress.pageDown,
        KeyPress.backTab,
        KeyPress.enter,
        KeyPress('k', ctrl: true),
        KeyPress('left', ctrl: true),
      ];
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

    test('emoji presentation is two columns, every mark and jamo none (Unicode data)', () {
      expect([
        for (final c in ['✨', '⭐', '⏳', '⌛', '❓', '🀄', '🈁']) Style.width(c),
      ], everyElement(2));
      expect(Style.width('\u304b\u3099'), 2, reason: 'NFD が, as macOS names a file');
      expect(Style.width('\u1112\u1161\u11ab'), 2, reason: 'NFD 한');
      expect(Style.width('\u05e9\u05bc'), 1, reason: 'Hebrew with dagesh');
      expect(Style.width('\u0e01\u0e48'), 1, reason: 'Thai with a tone mark');
      expect(Style.width('a\u200bb'), 2);
    });

    test('a cut keeps a combining mark with its letter', () {
      expect(Style.truncate('\u304b\u3099\u304b\u3099\u304b\u3099', 5), '\u304b\u3099\u304b\u3099…');
    });

    test('plain text drops every escape, and they take no width', () {
      const raw = '\x1b(B\x1b[mok\x1b7\x1b8 \x1b]8;;https://x\x07link\x1b]8;;\x07';
      expect(Style.plain(raw), 'ok link');
      expect(Style.width(raw), 7);
    });

    test('wrapping keeps a paragraph\'s indent on each of its lines', () {
      expect(Style.wrap('Run:\n  app build --out site', 14), ['Run:', '  app build', '  --out site']);
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

    test('a newline in a Label breaks the line, inside a box too', () {
      expect(Label('a\nb').heightAt(5), 2, reason: 'a newline breaks the line, never joins what is before it');
      expect(plain(Box(Label('a\nb')), 7), '╭─────╮\n│ a   │\n│ b   │\n╰─────╯');
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
      final pick = Choice(['a', 'b', 'c', 'd', 'e'], index: 3, multi: true, checked: [0]);
      expect(plain(Menu(pick), 8, height: 3), '  ○ b  │\n  ○ c  ┃\n› ○ d  ┃');
    });

    test('a running app leaves a restore for an exit that skips finally', () async {
      final term = fake(width: 20, height: 5);
      final run = on(term, () => Tui.run<int, Never>(0, draw: (_) => Label('x'), update: (s, e) => s));
      await pump();
      expect(term.isAltScreen, isTrue);
      expect(IoBridge.restores, hasLength(1));
      IoBridge.restores.first(); // what `Console.exit` does before `exit`
      expect(term.isAltScreen, isFalse);
      expect(term.isCursorVisible, isTrue);
      expect(term.isOpen, isFalse);
      expect(IoBridge.restores, isEmpty);
      run.ignore();
    });

    test('Menu filters as typed and highlights the match', () async {
      final term = fake(width: 20, height: 5);
      final pick = Choice(['apple', 'banana', 'cherry'], filter: true);
      final run = on(
        term,
        () => Tui.run<String?, Never>(
          null,
          draw: (_) => Menu(pick),
          update: (s, e) => e == KeyPress.enter ? Tui.quit(pick.value) : s,
        ),
      );
      await pump();
      term.type('an');
      await pump();
      expect(term.screen, '› banana');
      term.press(KeyPress.enter);
      expect(await run, 'banana');
    });

    test('typed-ahead keys in one read filter before Enter picks', () async {
      final term = fake(width: 20, height: 5);
      final pick = Choice(['apple', 'banana', 'cherry'], filter: true);
      final run = on(
        term,
        () => Tui.run<String?, Never>(
          null,
          draw: (_) => Menu(pick),
          update: (s, e) => e == KeyPress.enter ? Tui.quit(pick.value) : s,
        ),
      );
      await pump();
      term.type('chy\r');
      expect(await run, 'cherry');
    });

    test('Menu builders get the item context', () {
      final menu = Menu(
        Choice(Mode.values, index: 1),
        item: (c) => Label('${c.index}:${c.label}${c.isSelected ? '*' : ''}'),
      );
      expect(plain(menu, 10), '0:debug\n1:release*');
    });

    test('Grid fits columns, truncates, and selects', () {
      final rows = [
        {'Name': 'readme.md', 'Size': 120},
        {'Name': 'a-very-long-name.dart', 'Size': 4500},
      ];
      final grid = Grid(['Name', 'Size'], rows, choice: Choice(rows, index: 1));
      expect(plain(grid, 22), '  Name            Size\n  readme.md        120\n› a-very-long-n…  4500');
    });

    test('Grid draws a table\'s rows by name: numbers right unless align: says', () {
      final rows = [
        {'name': 'a', 'n': 5},
        {'name': 'bb', 'n': 120},
      ];
      expect(plain(Grid(['name', 'n'], rows), 12), 'name    n\na       5\nbb    120');
      expect(plain(Grid(['n'], rows, align: {'n': Align.left}), 12), 'n\n5\n120');
    });

    test('Grid takes a Choice of its own rows, never overwriting another (TUI-4)', () {
      final rows = [
        {'k': 'a'},
      ];
      expect(() => Grid(['k'], rows, choice: Choice([...rows])), throwsArgumentError);
    });

    test('a Grid filters on the text its cells show', () {
      final rows = [
        {'k': 'a', 'v': null},
        {'k': 'b', 'v': 'x'},
      ];
      final choice = Choice(rows, filter: true)..query = 'null';
      plain(Grid(['k', 'v'], rows, choice: choice), 10);
      expect(choice.index, -1, reason: 'a null cell is blank, so nothing says null');
    });

    test('Grid cell builder draws the header too, and can wrap the default', () {
      final grid = Grid(
        ['a', 'b'],
        [
          {'a': 1, 'b': 2},
        ],
        cell: (c) => c.isHeader ? const TuiTheme().cell(c) : Label('<${c.value}>'),
      );
      expect(plain(grid, 10), '  a    b\n<1>  <2>', reason: 'a column of numbers sits right');
    });

    test('Field shows placeholder, mask, and scrolls to the cursor', () {
      expect(plain(Field(prompt: '> ', placeholder: 'name'), 10), '> name');
      expect(plain(Field(text: 'secret', mask: '*'), 10), '******');
      expect(plain(Field(text: 'abcdefghij'), 5), 'ghij');
      expect(plain(Field(text: 'x', validate: (v) => v.length < 3 ? 'too short' : null), 12), 'x\ntoo short');
    });

    test('Gauge draws a bar and its percent in the palette\'s glyphs', () {
      expect(plain(Gauge(0.5), 15), '█████░░░░░  50%');
      expect(
        plain(Gauge(0.5).themed(const TuiTheme(palette: Palette(bar: BarGlyphs('=', '.')))), 15),
        '=====.....  50%',
      );
    });

    test('a filtered menu is as tall as what it shows', () {
      final pick = Choice(['apple', 'banana', 'cherry'], filter: true)..query = 'an';
      expect(Menu(pick).heightAt(20), 1, reason: 'inline pick kept blank rows');
      expect(Menu(Choice(['apple'], filter: true)..query = 'zz').heightAt(20), 1, reason: 'the "No matches" row');
    });

    test('a filter reads the list it is given and a new query', () {
      final pick = Choice(['apple', 'banana'], filter: true)..query = 'an';
      expect(plain(Menu(pick), 10), '› banana');
      expect(pick.value, 'banana');
      pick.items = ['apple', 'banana', 'mango'];
      expect(plain(Menu(pick), 10), '› banana\n  mango');
      pick.items = ['orange'];
      expect(plain(Menu(pick), 10), '› orange');
      pick
        ..items = ['orange', 'pear']
        ..query = 'or';
      expect(plain(Menu(pick), 10), '› orange');
    });

    test('a grid measures its cells in the theme it draws them in', () {
      final grid = Grid(
        ['k'],
        [
          {'k': 'a'},
        ],
        cell: (c) => Label('${c.palette.pointer}${c.value}'),
      ).themed(const TuiTheme(palette: Palette(pointer: '>>')));
      expect(plain(grid, 10), '>>k\n>>a');
    });

    test('Spin shows a frame and asks to animate', () {
      expect(plain(Spin('Loading'), 12), '⠋ Loading');
      expect(plain(Spin('x').themed(const TuiTheme(palette: Palette(frames: ['-', '+']))), 4), '- x');
    });

    test('Tabs marks the chosen tab', () {
      expect(plain(Tabs(Choice(['One', 'Two'], index: 1)), 12), ' One │ Two');
    });

    test('the theme holds every builder; a widget\'s own beats it', () {
      final theme = TuiTheme(
        item: (i) => Label('item ${i.label}${i.isChecked == null ? '' : '?'}'),
        tab: (t) => Label('[${t.label}]'),
        field: (f) => Label('field ${f.shown}'),
        cell: (c) => Label(c.isHeader ? 'H' : 'c'),
        button: (b) => Label('button ${b.label}'),
      );
      String drawn(Widget w) => w.render(20, theme: theme, color: false);
      expect(drawn(Menu(Choice(['x']))), 'item x');
      expect(drawn(Menu(Choice(['x']), item: (i) => Label('own'))), 'own');
      expect(drawn(Menu(Choice(['x'], multi: true))), 'item x?');
      expect(drawn(Tabs(Choice(['A', 'B']))), '[A]│[B]');
      expect(drawn(Field(text: 'hi')), 'field hi');
      expect(drawn(Button('Go', message: 1)), 'button Go');
      expect(
        drawn(
          Grid(
            ['k'],
            [
              {'k': 1},
            ],
          ),
        ),
        'H\nc',
      );
    });

    test('a board draws a tally with the theme\'s builders: the same views the console draws (CLI-1, CLI-14)', () {
      final tally = Tally(count: 2)..add(const Running('a', received: 1, total: 2));
      final theme = TuiTheme(
        batch: (b) => Label('${b.title} ${b.ended}/${b.count} ${b.failed}'),
        task: (t) => Label('row ${t.label} ${t.percent}'),
      );
      expect(Board(tally, title: 'up').render(20, theme: theme, color: false), 'up 0/2 0\nrow a 50');
    });

    test('a board of a task is one line; past its rows the rest are +N more', () {
      final tally = Tally();
      for (var i = 0; i < 4; i++) {
        tally.add(Running('item$i', received: 1, total: 4));
      }
      final drawn = plain(Board(tally, title: 'Files', rows: 2), 40).split('\n');
      expect(drawn, hasLength(4));
      expect(drawn[1], startsWith('  item0'));
      expect(drawn.last, '  +2 more');
      tally.add(Failed('item0', const FormatException('lost'), StackTrace.empty));
      expect(plain(Board(tally, title: 'Files', rows: 2), 40), contains('✖ item0: FormatException: lost'));
      expect(() => Board(tally, rows: 0), throwsArgumentError);
    });

    test('a styled string draws in its styles: Label, Log, a box title', () async {
      const bold = Style(bold: true, fg: Color.red);
      await Io.scope(() {
        String drawn(Widget w) => w.render(6, color: true);
        final want = drawn(Label.spans([const Span('a'), const Span('b', bold)]));
        expect(want, contains('\x1b['));
        expect(drawn(Label('a${bold('b')}')), want);
        expect(drawn(Log(['a${bold('b')}'], scrollbar: false)), want);
        expect(plain(Label('a${bold('b')}'), 6), 'ab');
        expect(Box(null, title: bold('t')).render(8, color: true), contains('31mt'), reason: 'the title keeps its red');
      }, color: true);
    });

    test('themed overrides only what it names', () {
      final w = Box(Label('x')).themed(const TuiTheme(palette: Palette(border: Border.ascii)));
      expect(plain(w, 5), '+---+\n| x |\n+---+');
      final menu = Menu(Choice(['a'])).themed(const TuiTheme(palette: Palette(pointer: '>')));
      expect(plain(menu, 5), '> a');
    });

    test('Grid with a 0 width fits a terminal narrower than its gaps', () {
      expect(
        () => plain(
          Grid(
            ['a', 'b', 'c', 'd'],
            [
              {'a': 'a', 'b': 'b', 'c': 'c', 'd': 'd'},
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

  group('rendering', () {
    test('a frame after the first writes only the changed cells', () async {
      final term = fake(width: 20, height: 4);
      final run = on(
        term,
        () => Tui.run<String, Never>(
          'hello',
          draw: (s) => VStack([Label(s), Label('static line')]),
          update: (s, e) => switch (e) {
            KeyPress(:final text?) => 'hell$text',
            Start() => s,
            _ => Tui.quit(s),
          },
        ),
      );
      await pump();
      expect(term.screen, 'hello\nstatic line');
      term.type('O');
      await pump();
      expect(term.screen, 'hellO\nstatic line');
      expect(Style.plain(term.writes.last), 'O');
      expect(term.writes.last, contains('\x1b[1;5H'));
      term.press(KeyPress.esc);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await run;
    });

    test(
      'the terminal reader dies with its process, even after kill -9',
      () async {
        final dir = Directory('.dart_tool/tk_ttykill')..createSync(recursive: true);
        addTearDown(() => dir.deleteSync(recursive: true));
        File('${dir.path}/main.dart').writeAsStringSync('''
import 'dart:io';
import 'package:dart_toolkit/cli.dart' show Console;
import 'package:dart_toolkit/tui.dart';
void main() async {
  stderr.writeln('pid=\$pid');
  await Tui.run(0, draw: (_) => Label('x'), update: (s, e) => s, inline: true);
}
''');
        // The app's own readers, found by parentage: a reader of another suite running at the
        // same time is not this one's.
        Map<int, (int, String)> table() => {
          for (final line
              in '${Process.runSync('ps', ['-A', '-o', 'pid=', '-o', 'ppid=', '-o', 'command=']).stdout}'.split('\n'))
            if (RegExp(r'^\s*(\d+)\s+(\d+)\s(.*)$').firstMatch(line) case final m?)
              int.parse(m[1]!): (int.parse(m[2]!), m[3]!),
        };
        List<int> readersOf(int app) {
          final all = table();
          bool under(int pid) {
            for (var p = pid, hops = 0; p > 1 && hops < 8; hops++) {
              if ((p = all[p]?.$1 ?? 0) == app) return true;
            }
            return false;
          }

          return [
            for (final MapEntry(key: pid, value: (_, command)) in all.entries)
              if (command.contains('cat /dev/tty') && under(pid)) pid,
          ];
        }

        final main = '${dir.path}/main.dart';
        final child = await Process.start('script', [
          if (Platform.isMacOS) ...['-q', '/dev/null', Platform.resolvedExecutable, main],
          if (!Platform.isMacOS) ...['-qc', '${Platform.resolvedExecutable} $main', '/dev/null'],
        ]);
        addTearDown(() => child.kill(ProcessSignal.sigkill));
        final seen = Completer<int>();
        child.stdout.transform(utf8.decoder).listen((s) {
          if (RegExp(r'pid=(\d+)').firstMatch(s) case final m? when !seen.isCompleted) seen.complete(int.parse(m[1]!));
        });
        final app = await seen.future.timeout(const Duration(seconds: 30));
        var readers = <int>[];
        for (var i = 0; i < 100 && readers.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          readers = readersOf(app);
        }
        expect(readers, hasLength(2), reason: 'the reader (its sh and its cat) is running');
        Process.killPid(app, ProcessSignal.sigkill);
        var left = readers;
        for (var i = 0; i < 100 && left.isNotEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          final now = table();
          left = [
            for (final pid in readers)
              if (now[pid]?.$2.contains('cat /dev/tty') ?? false) pid,
          ];
        }
        expect(left, isEmpty, reason: 'an orphan reader would eat the shell\'s input');
      },
      testOn: 'mac-os || linux',
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'a script exits once its app ends, without waiting for Enter',
      () async {
        final dir = Directory('.dart_tool/tk_ttyexit')..createSync(recursive: true);
        addTearDown(() => dir.deleteSync(recursive: true));
        File('${dir.path}/main.dart').writeAsStringSync('''
import 'package:dart_toolkit/cli.dart' show Console;
import 'package:dart_toolkit/tui.dart';
void main() => Tui.run(0, draw: (_) => Label('x'), update: (s, e) => e is Start ? s : Tui.quit(0), inline: true);
''');
        final main = '${dir.path}/main.dart';
        final child = await Process.start('script', [
          if (Platform.isMacOS) ...['-q', '/dev/null', Platform.resolvedExecutable, main],
          if (!Platform.isMacOS) ...['-qc', '${Platform.resolvedExecutable} $main', '/dev/null'],
        ]);
        child.stdout.drain<void>().ignore();
        // One key ends the app; the process must end without another.
        final key = Timer.periodic(const Duration(milliseconds: 500), (_) => child.stdin.write('q'));
        final code = await child.exitCode.timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            child.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
        key.cancel();
        expect(code, 0, reason: 'the tty reader kept the process alive');
      },
      testOn: 'mac-os || linux',
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'each run closes the /dev/tty it reads and writes',
      () async {
        final dir = Directory('.dart_tool/tk_ttyfd')..createSync(recursive: true);
        addTearDown(() => dir.deleteSync(recursive: true));
        File('${dir.path}/main.dart').writeAsStringSync('''
import 'dart:io';
import 'package:dart_toolkit/cli.dart' show Console;
import 'package:dart_toolkit/tui.dart';
int fds() => '\${Process.runSync('lsof', ['-p', '\$pid']).stdout}'.split('\\n').where((l) => l.endsWith('/dev/tty')).length;
void main() async {
  final counts = <int>[];
  for (var i = 0; i < 4; i++) {
    await Tui.run(0, draw: (_) => Label('x'), update: (s, e) => e is Start ? s : Tui.quit(0), inline: true);
    await Future<void>.delayed(const Duration(milliseconds: 300)); // the reader's last read
    counts.add(fds());
  }
  stdout.writeln('fds=\$counts');
}
''');
        final main = '${dir.path}/main.dart';
        final child = await Process.start('script', [
          if (Platform.isMacOS) ...['-q', '/dev/null', Platform.resolvedExecutable, main],
          if (!Platform.isMacOS) ...['-qc', '${Platform.resolvedExecutable} $main', '/dev/null'],
        ]);
        final out = StringBuffer();
        final printed = Completer<String>();
        child.stdout.transform(utf8.decoder).listen((s) {
          out.write(s);
          if (RegExp(r'fds=\[[\d, ]+\]').firstMatch('$out') case final m? when !printed.isCompleted) {
            printed.complete(m[0]);
          }
        });
        final keys = Timer.periodic(const Duration(milliseconds: 500), (_) => child.stdin.write('q'));
        addTearDown(() {
          keys.cancel();
          child.kill(ProcessSignal.sigkill);
        });
        expect(
          await printed.future.timeout(const Duration(seconds: 60)),
          'fds=[0, 0, 0, 0]',
          reason: 'a descriptor per run',
        );
      },
      testOn: 'mac-os || linux',
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test('colour falls back to what the terminal shows', () async {
      Future<String> frame(int colors) async {
        final term = fake(width: 4, height: 1, colors: colors);
        final run = on(
          term,
          () => Tui.run(
            0,
            draw: (_) => Label('x', style: const Style(fg: Color.rgb(255, 0, 0))),
            update: (s, e) => e is Start ? s : Tui.quit(s),
          ),
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
      final term = fake(width: 10, height: 3);
      final sizes = <String>[];
      final run = on(
        term,
        () => Tui.run(
          0,
          draw: (_) => Label('x', align: Align.right),
          update: (s, e) {
            if (e is Resize) sizes.add('${e.width}x${e.height}');
            return e is KeyPress ? Tui.quit(s) : s;
          },
        ),
      );
      await pump();
      term.resize(6, 2);
      await pump();
      expect(term.screen, '     x');
      term.type('q');
      await run;
      expect(sizes, ['6x2']);
    });

    test('FakeTerminal draws a hyperlink as its text', () {
      final term = FakeTerminal(width: 10, height: 1)..write('\x1b]8;;https://dart.dev\x1b\\ab\x1b]8;;\x07c');
      expect(term.screen, 'abc');
    });
  });

  group('app', () {
    test('keys update state, the terminal is restored, run returns the state', () async {
      final term = fake(width: 20, height: 3);
      final run = on(
        term,
        () => Tui.run(
          0,
          draw: (n) => Box(Label('n=$n'), title: 'Count'),
          update: (n, e) => switch (e) {
            KeyPress.up => n + 1,
            KeyPress.down => n - 1,
            KeyPress(name: 'q') => Tui.quit(n),
            _ => n,
          },
        ),
      );
      await pump();
      expect(term.isOpen && term.isAltScreen && !term.isCursorVisible && term.isPaste, isTrue);
      term
        ..press(KeyPress.up)
        ..press(KeyPress.up)
        ..press(KeyPress.down)
        ..press(KeyPress.up);
      await pump();
      expect(term.screen, '╭─ Count ──────────╮\n│ n=2              │\n╰──────────────────╯');
      term.type('q');
      expect(await run, 2);
      expect(term.isOpen || term.isAltScreen || !term.isCursorVisible || term.isPaste, isFalse);
    });

    test('a terminal that cannot draw Unicode gets the ASCII glyphs, whatever the host', () async {
      final term = fake(width: 12, height: 3, unicode: false);
      final run = on(
        term,
        () => Tui.run(
          0,
          draw: (n) => Box(Label('n=$n'), title: 'C'),
          update: (n, e) => e is Start ? n : Tui.quit(n),
        ),
      );
      await pump();
      expect(term.screen, '+- C ------+\n| n=0      |\n+----------+');
      term.type('q');
      await run;
    });

    test('quit with a state returns it', () async {
      final term = fake();
      final run = on(
        term,
        () => Tui.run('a', draw: (s) => Label(s), update: (s, e) => e is Start ? s : Tui.quit('done')),
      );
      await pump();
      term.type('x');
      expect(await run, 'done');
    });

    test('an exception in update ends the app with it and restores the terminal', () async {
      final term = fake();
      final run = on(
        term,
        () => Tui.run(0, draw: (_) => Label('x'), update: (s, e) => e is Start ? s : throw StateError('boom')),
      );
      await pump();
      term.type('x');
      await expectLater(run, throwsA(isA<StateError>()));
      expect(term.isOpen || term.isAltScreen || !term.isCursorVisible, isFalse);
    });

    test('an exception in view ends the app too', () async {
      final term = fake();
      await expectLater(
        on(term, () => Tui.run(0, draw: (_) => throw StateError('view'), update: (s, _) => s)),
        throwsStateError,
      );
    });

    test('^C throws CancelledException and restores the terminal', () async {
      final term = fake();
      final run = on(term, () => Tui.run(0, draw: (_) => Label('x'), update: (s, _) => s));
      await pump();
      term.type('\x03');
      await expectLater(run, throwsA(isA<CancelledException>()));
      expect(term.isOpen || term.isAltScreen, isFalse);
    });

    test('a cancelled Cancel.scope ends the app and restores the terminal', () async {
      final term = fake();
      final token = CancelToken();
      final run = Cancel.scope(
        () => on(term, () => Tui.run(0, draw: (_) => Label('x'), update: (s, _) => s)),
        token: token,
      );
      await pump();
      token.cancel('stop');
      await expectLater(run, throwsA(isA<CancelledException>().having((e) => e.reason, 'reason', 'stop')));
      expect(term.isOpen || term.isAltScreen, isFalse);
    });

    test('one app at a time', () async {
      final term = fake();
      final run = on(term, () => Tui.run(0, draw: (_) => Label('x'), update: (s, e) => e is Start ? s : Tui.quit(s)));
      await pump();
      await expectLater(on(term, () => Tui.run(0, draw: (_) => Label('y'), update: (s, _) => s)), throwsStateError);
      term.type('q');
      await run;
    });

    test('post delivers a value and a future, listen a stream, each as a Post', () async {
      final term = fake();
      final ticks = StreamController<Object>();
      final run = on(
        term,
        () => Tui.run<List<Object>, Object>(
          [],
          draw: (s) => Label(s.join(',')),
          update: (s, e) {
            switch (e) {
              case Start():
                Tui.post<Object>(Future.value('loaded'));
                Tui.listen(ticks.stream);
                Tui.post<Object>('plain');
              case KeyPress():
                Tui.quit(s);
              case Post(:final message):
                return [...s, message];
              case _:
            }
            return s;
          },
        ),
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
      final term = fake();
      final run = on(
        term,
        () => Tui.run(
          0,
          draw: (_) => Label('x'),
          update: (s, e) {
            if (e is Start) Tui.post(Future<Object>.error(const FormatException('bad')));
            return s;
          },
        ),
      );
      await expectLater(run, throwsFormatException);
    });

    test('Tab moves the focus; keys reach the focused field first', () async {
      final term = fake(width: 20, height: 4);
      final a = Field(prompt: 'a: '), b = Field(prompt: 'b: ');
      final seen = <Object>[];
      final run = on(
        term,
        () => Tui.run(
          0,
          draw: (_) => VStack([a, b]),
          update: (s, e) {
            if (e is! Start) seen.add(e);
            return e == KeyPress.enter ? Tui.quit(s) : s;
          },
        ),
      );
      await pump();
      term.type('hi');
      await pump();
      term
        ..press(KeyPress.tab)
        ..type('yo');
      await pump();
      term.press(KeyPress.enter);
      await run;
      expect((a.text, b.text), ('hi', 'yo'));
      expect(seen, [KeyPress.enter]);
    });

    test('a click focuses the list under it and selects the row', () async {
      final term = fake(width: 20, height: 6);
      final left = Choice(['a', 'b', 'c']), right = Choice(['x', 'y', 'z']);
      final run = on(
        term,
        () => Tui.run(
          0,
          pointer: true,
          draw: (_) => HStack([Menu(left).flex(), Menu(right).flex()]),
          update: (s, e) => e is KeyPress ? Tui.quit(s) : s,
        ),
      );
      await pump();
      expect(term.isPointer, isTrue);
      term.pointer(12, 2);
      await pump();
      expect(right.index, 2);
      term.press(KeyPress.up);
      await pump();
      expect((left.index, right.index), (0, 1));
      term.pointer(1, 0, PointerKind.wheelDown);
      await pump();
      expect(left.index, 1);
      term.type('q');
      await run;
      expect(term.isPointer, isFalse);
    });

    test('Field editing: words, cuts and history', () async {
      final term = fake();
      final f = Field(text: 'one two three', history: ['old']);
      final run = on(term, () => Tui.run(0, draw: (_) => f, update: (s, e) => e == KeyPress.enter ? Tui.quit(s) : s));
      await pump();
      Future<void> keys(List<KeyPress> ks) async {
        ks.forEach(term.press);
        await pump();
      }

      await keys([const KeyPress('w', ctrl: true)]);
      expect(f.text, 'one two ');
      await keys([const KeyPress('left', ctrl: true), const KeyPress('left', ctrl: true)]);
      expect(f.cursor, 0);
      term.type('X');
      await pump();
      expect(f.text, 'Xone two ');
      await keys([const KeyPress('k', ctrl: true)]);
      expect(f.text, 'X');
      await keys([KeyPress.up]);
      expect(f.text, 'old');
      await keys([KeyPress.down]);
      expect(f.text, '');
      term.type('\x1b[200~pa\nste\x1b[201~');
      await pump();
      expect(f.text, 'pa ste');
      await keys([const KeyPress('u', ctrl: true)]);
      expect(f.text, '');
      term.press(KeyPress.enter);
      await run;
    });

    test('Field: ^D deletes under the cursor, and on an empty input reaches update', () async {
      final term = fake();
      final f = Field(text: 'ab');
      final run = on(
        term,
        () => Tui.run(0, draw: (_) => f, update: (s, e) => e == const KeyPress('d', ctrl: true) ? Tui.quit(s + 1) : s),
      );
      await pump();
      f.cursor = 0;
      term.press(const KeyPress('d', ctrl: true));
      await pump();
      expect(f.text, 'b');
      term.press(KeyPress.delete);
      await pump();
      expect(f.text, '');
      term.press(const KeyPress('d', ctrl: true));
      expect(await run, 1);
    });

    test('a spinner animates without events', () async {
      final term = fake(width: 10, height: 1);
      final run = on(
        term,
        () => Tui.run(
          0,
          theme: const TuiTheme(
            palette: Palette(frames: ['a', 'b'], interval: Duration(milliseconds: 10)),
          ),
          draw: (_) => Spin('x'),
          update: (s, e) => e is Start ? s : Tui.quit(s),
        ),
      );
      await pump();
      final first = term.writes.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(term.writes.length, greaterThan(first));
      term.type('q');
      await run;
    });

    test('the class form runs on the same engine', () async {
      final term = fake();
      final app = _Counter();
      final run = on(term, app.run);
      await pump();
      term
        ..press(KeyPress.up)
        ..press(KeyPress.up);
      await pump();
      expect(term.screen, '2');
      Tui.post(40);
      await pump();
      expect(term.screen, '42', reason: "a TuiApp's typed message arrives as a Post");
      await Future<void>.delayed(const Duration(milliseconds: 20));
      Tui.listen(Stream.value(2));
      await pump();
      expect(term.screen, '44', reason: 'listen delivers each one as a Post');
      term.type('q');
      expect(await run, 44);
    });

    test('a click after the filter matches nothing keeps the app running', () async {
      final term = fake(width: 20, height: 5);
      final pick = Choice(['apple', 'banana'], filter: true);
      final run = on(
        term,
        () => Tui.run<int, Never>(
          0,
          pointer: true,
          draw: (_) => Menu(pick),
          update: (s, e) => e == KeyPress.enter ? Tui.quit(pick.index) : s,
        ),
      );
      await pump();
      term.type('zz');
      await pump();
      term.pointer(2, 0);
      await pump();
      term.press(KeyPress.enter);
      expect(await run, -1);
    });

    test('Tui.focus gives a control the focus from code', () async {
      final term = fake(width: 20, height: 4);
      final (a, b) = (Field(prompt: 'a:'), Field(prompt: 'b:'));
      final pick = Choice(const ['x', 'y']);
      final run = on(
        term,
        () => Tui.run<int, Never>(
          0,
          draw: (_) => VStack([a, b, Menu(pick)]),
          update: (n, e) {
            if (e is Start) Tui.focus(b);
            if (e == const KeyPress('f1')) Tui.focus(a);
            if (e == const KeyPress('f2')) Tui.focus(pick);
            return e == KeyPress.esc ? Tui.quit(n) : n;
          },
        ),
      );
      await pump();
      term.type('x');
      await pump();
      expect((a.text, b.text), ('', 'x'));
      term
        ..press(const KeyPress('f1'))
        ..type('y')
        ..press(const KeyPress('f2'))
        ..press(KeyPress.down);
      await pump();
      expect((a.text, pick.index), ('y', 1));
      term.press(KeyPress.esc);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await run;
      expect(() => Tui.focus(a), throwsStateError);
    });

    test('a terminal that cannot draw Unicode draws an app in TuiTheme.ascii, under its own theme', () async {
      final dir = Directory('.dart_tool/tk_tui_ascii')..createSync(recursive: true);
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/main.dart').writeAsStringSync('''
import 'package:dart_toolkit/cli.dart' show Console;
import 'package:dart_toolkit/tui.dart';
void main() {
  print(Box(Label('x'), title: 't').render(10, color: false));
  print(Menu(Choice(['a'], multi: true)).themed(TuiTheme(palette: Palette(accent: Style(bold: true)))).render(10, color: false));
}
''');
      Future<String> run(String locale) async =>
          '${(await Process.run(Platform.resolvedExecutable, ['--packages=${File('.dart_tool/package_config.json').absolute.path}', '${dir.path}/main.dart'], environment: {'LC_ALL': locale, 'TERM': 'xterm'})).stdout}';
      expect(await run('C'), '+- t ----+\n| x      |\n+--------+\n> o a\n');
      expect(await run('en_US.UTF-8'), startsWith('╭─ t ────╮'));
    }, testOn: 'mac-os || linux');
  });

  group('events and the side effects on Tui', () {
    test('Start comes once, first, before the first frame', () async {
      final term = fake();
      final seen = <Object>[];
      final run = on(
        term,
        () => Tui.run<int, Never>(
          0,
          draw: (n) => Label('seen ${seen.length}'),
          update: (n, e) => e == KeyPress.esc ? Tui.quit(n) : (seen..add(e)).length,
        ),
      );
      await pump();
      expect(seen, [const Start()]);
      expect(term.screen, 'seen 1');
      term.press(KeyPress.esc);
      await run;
    });

    test('an Interrupt answered with another state keeps the app open; a second ^C ends it', () async {
      final term = fake();
      final seen = <Object>[];
      final run = on(
        term,
        () => Tui.run<int, Never>(
          0,
          draw: (n) => Label('$n'),
          update: (n, e) => switch (e) {
            Interrupt() => (seen..add(e)).length,
            _ => n,
          },
        ),
      );
      final outcome = run.then((_) => 'quit', onError: (Object e) => '$e');
      await pump();
      term.type('\x03');
      await pump();
      expect(term.screen, '1', reason: 'update answered another state');
      term.type('\x03');
      expect(await outcome, contains('Interrupted'));
      expect(seen, [const Interrupt()], reason: 'a second ^C within two seconds never reaches update');
    });

    test('an Interrupt answered with the same state ends the app as a SIGINT', () async {
      final term = fake();
      final seen = <Object>[];
      final run = on(
        term,
        () => Tui.run<int, Never>(0, draw: (n) => Label('$n'), update: (n, e) => (seen..add(e), n).$2),
      );
      await pump();
      term.type('\x03');
      await expectLater(run, throwsA(isA<CancelledException>()));
      expect(seen, [const Start(), const Interrupt()]);
      expect(term.isOpen, isFalse);
    });

    test('a SIGINT from outside ends the app without an Interrupt', () async {
      final term = fake();
      final seen = <Object>[];
      final run = on(
        term,
        () => Tui.run<int, Never>(0, draw: (n) => Label('$n'), update: (n, e) => (seen..add(e)).length),
      );
      await pump();
      KeysBridge.interrupted!();
      await expectLater(run, throwsA(isA<CancelledException>()));
      expect(seen, [const Start()]);
    });

    test('defer runs after the terminal is put back, last first, on quit, error and cancel', () async {
      for (final ending in ['quit', 'error', 'cancel']) {
        final term = fake();
        final log = <String>[];
        late Task<int> task;
        final run = on(term, () {
          task = Tui.run<int, Never>(
            0,
            draw: (_) => Label('x'),
            update: (n, e) {
              if (e is Start) {
                Tui.defer(() => log.add('first, open: ${term.isOpen}'));
                Tui.defer(() => log.add('second'));
              }
              if (e == const KeyPress('q')) Tui.quit(n);
              if (e == const KeyPress('e')) throw StateError('boom');
              return n;
            },
          );
          return task;
        });
        final outcome = run.then((_) => 'quit', onError: (Object e) => '${e.runtimeType}');
        await pump();
        switch (ending) {
          case 'quit':
            term.type('q');
          case 'error':
            term.type('e');
          default:
            task.cancel('enough');
        }
        expect(
          await outcome,
          ['quit', 'StateError', 'CancelledException'][['quit', 'error', 'cancel'].indexOf(ending)],
        );
        expect(log, ['second', 'first, open: false'], reason: ending);
      }
    });

    test('post with onError turns a failure into a message', () async {
      final term = fake();
      final run = on(
        term,
        () => Tui.run<String, String>(
          '',
          draw: (s) => Label(s),
          update: (s, e) => switch (e) {
            Start() => _post(s, () {
              Tui.post<String>(
                Future.error(const FormatException('down')),
                onError: (e) => 'failed: ${(e as FormatException).message}',
              );
            }),
            Post(:final message) => Tui.quit(message),
            _ => s,
          },
        ),
      );
      expect(await run, 'failed: down');
    });

    test('the statics are a StateError while no app runs', () {
      expect(() => Tui.post(1), throwsStateError);
      expect(() => Tui.listen(const Stream<int>.empty()), throwsStateError);
      expect(() => Tui.defer(() {}), throwsStateError);
    });

    test('^Z is a Suspend, the terminal put back and the process stopped; SIGCONT a Resume and a redraw', () async {
      final term = fake(width: 20, height: 3);
      final seen = <Object>[];
      final run = on(
        term,
        () => Tui.run<int, Never>(
          0,
          draw: (n) => Label('n=$n'),
          update: (n, e) {
            if (e is Suspend || e is Resume) seen.add(e);
            return e == KeyPress.esc ? Tui.quit(n) : (e is Resume ? n + 1 : n);
          },
        ),
      );
      await pump();
      expect(term.isAltScreen, isTrue);
      term.press(const KeyPress('z', ctrl: true));
      await pump();
      expect(seen, [const Suspend()]);
      expect((term.isSuspended, term.isAltScreen, term.isOpen, term.isCursorVisible), (true, false, false, true));
      term.resume();
      await pump();
      expect(seen, [const Suspend(), const Resume()]);
      expect((term.isAltScreen, term.isOpen, term.isCursorVisible), (true, true, false));
      expect(term.screen, 'n=1', reason: 'drawn whole again');
      term.press(KeyPress.esc);
      expect(await run, 1);
    });
  });

  group('inline', () {
    test('draws under the cursor, grows and shrinks, and erases itself', () async {
      final term = fake(width: 20, height: 6);
      term.write('before\r\n');
      final run = on(
        term,
        () => Tui.run(
          2,
          inline: true,
          draw: (n) => VStack([for (var i = 0; i < n; i++) Label('row $i')]),
          update: (n, e) => switch (e) {
            KeyPress.up => n + 1,
            KeyPress.down => n - 1,
            Start() => n,
            _ => Tui.quit(n),
          },
        ),
      );
      await pump();
      expect(term.isAltScreen, isFalse);
      expect(term.screen, 'before\nrow 0\nrow 1');
      term.press(KeyPress.up);
      await pump();
      expect(term.screen, 'before\nrow 0\nrow 1\nrow 2');
      term
        ..press(KeyPress.down)
        ..press(KeyPress.down);
      await pump();
      expect(term.screen, 'before\nrow 0');
      term.type('q');
      expect(await run, 1);
      expect(term.screen, 'before');
      expect(term.isCursorVisible && !term.isOpen, isTrue);
    });

    test('a print or a Console line lands above the inline region; full-screen, after it closes', () async {
      final term = fake(width: 30, height: 6);
      final out = StringBuffer();
      final run = Io.scope(
        () => on(
          term,
          () => Tui.run<int, Never>(
            0,
            inline: true,
            draw: (n) => Label('region $n'),
            update: (s, e) {
              if (e == const KeyPress('p')) print('printed');
              if (e == const KeyPress('i')) Console.info('noted');
              return e == const KeyPress('q') ? Tui.quit(s) : (e is Start ? s : s + 1);
            },
          ),
        ),
        stdout: out,
      );
      await pump();
      term.type('p');
      await pump();
      term.type('i');
      await pump();
      final lines = term.screen.split('\n');
      expect(lines, hasLength(3));
      expect([lines[0], lines[1].trim(), lines[2]], ['printed', 'ℹ noted', 'region 2']);
      expect('$out', isEmpty, reason: 'drawn through the terminal, in order with the frame');
      term.type('q');
      await run;

      final alt = fake(width: 30, height: 6);
      final full = Io.scope(
        () => on(
          alt,
          () => Tui.run<int, Never>(
            0,
            draw: (_) => Label('full'),
            update: (s, e) {
              print('later');
              return Tui.quit(s);
            },
          ),
        ),
        stdout: out,
      );
      await pump();
      alt.type('x');
      await full;
      expect(alt.screen.trim(), 'later', reason: 'held until the alternate screen closes, then on the terminal');
    });

    test('Board draws a tally as show() does, and redraws as the tally changes (CLI-5)', () async {
      final term = fake(width: 40, height: 8);
      final tally = Tally(count: 3);
      final run = on(
        term,
        () => Tui.run<int, Never>(
          0,
          inline: true,
          draw: (_) => Board(tally, title: 'Fetch'),
          update: (s, e) => e is Start ? s : Tui.quit(s),
        ),
      );
      await pump();
      tally
        ..add(const Running('a.bin', received: 5, total: 10))
        ..add(const Done('b.bin', 2));
      await pump();
      var lines = term.screen.split('\n');
      expect(lines.first, allOf(contains('Fetch'), contains('1/3')));
      expect(lines[1], allOf(startsWith('  a.bin'), contains('50%')));
      tally
        ..add(Failed('a.bin', StateError('x'), StackTrace.empty))
        ..add(const Done('c.bin', 3))
        ..close();
      await pump();
      lines = term.screen.split('\n');
      expect(lines.first, allOf(contains('3/3'), contains('1 failed')));
      expect(lines.last, '✖ a.bin: Bad state: x');
      term.type('q');
      await run;
    });

    test('^C erases the region and restores the terminal', () async {
      final term = fake(width: 20, height: 6);
      final run = on(
        term,
        () => Tui.run(0, inline: true, draw: (_) => VStack([Label('a'), Label('b')]), update: (s, _) => s),
      );
      await pump();
      term.type('\x03');
      await expectLater(run, throwsA(isA<CancelledException>()));
      expect(term.screen, '');
      expect(term.isCursorVisible && !term.isOpen, isTrue);
    });

    test('a picker: filter, check, and return the checked', () async {
      final term = fake(width: 30, height: 10);
      const fruits = ['apple', 'banana', 'cherry', 'date'];
      final pick = Choice(fruits, filter: true, multi: true);
      final run = on(
        term,
        () => Tui.run<List<String>, Never>(
          const [],
          inline: true,
          draw: (_) => VStack([Label('Pick: ${pick.query}'), Menu(pick)]),
          update: (s, e) => e == KeyPress.enter ? Tui.quit(pick.picked) : s,
        ),
      );
      await pump();
      term
        ..type(' ')
        ..press(KeyPress.down)
        ..press(KeyPress.down)
        ..type(' ');
      await pump();
      term.type('e');
      await pump();
      expect(term.screen, 'Pick: e\n  ◉ apple\n› ◉ cherry\n  ○ date');
      term.press(KeyPress.enter);
      expect(await run, ['apple', 'cherry']);
    });
  });

  group('scrolling: Scroll and Log', () {
    /// The first word of each row on screen.
    List<String> rows(FakeTerminal term) => [for (final l in term.screen.split('\n')) l.split(' ').first];

    test('a Log is as wide as its widest line, as lines are added or the list replaced', () {
      final log = Log(['ab'], scrollbar: false);
      expect(log.width, 2);
      log.lines.add('abcd');
      expect(log.width, 4);
      log.lines = ['a'];
      expect(log.width, 1);
    });

    test('a Scroll in a box draws only its rows, and a child taller than the screen in pieces', () {
      final view = Box(Scroll(Label([for (var i = 1; i <= 50; i++) 'r$i'].join('\n')), scrollbar: false));
      expect(plain(VStack([Label('top'), view.fixed(4), Label('end')]), 6), 'top\n╭────╮\n│ r1 │\n│ r2 │\n╰────╯\nend');
    });

    test('Scroll: keys and the wheel move what is shown, a scrollbar says where', () async {
      final term = fake(width: 10, height: 4);
      final view = Scroll(Label([for (var i = 1; i <= 10; i++) 'r$i'].join('\n')));
      final run = on(
        term,
        () =>
            Tui.run(0, draw: (_) => view, update: (n, e) => e == const KeyPress('q') ? Tui.quit(n) : n, pointer: true),
      );
      await pump();
      expect(rows(term), ['r1', 'r2', 'r3', 'r4']);
      expect(term.screen.split('\n').first, endsWith(const Palette().scrollThumb));
      term.press(KeyPress.down);
      await pump();
      expect(rows(term), ['r2', 'r3', 'r4', 'r5']);
      term.press(KeyPress.end);
      await pump();
      expect(rows(term), ['r7', 'r8', 'r9', 'r10']);
      term.pointer(0, 0, PointerKind.wheelUp);
      await pump();
      expect(rows(term), ['r4', 'r5', 'r6', 'r7']);
      term.press(KeyPress.pageDown);
      term.press(KeyPress.pageDown);
      await pump();
      expect(rows(term), ['r7', 'r8', 'r9', 'r10'], reason: 'never past the end');
      term.type('q');
      await run;
      expect(plain(Scroll(Label('a\nb\nc'), scrollbar: false), 5, height: 2), 'a\nb', reason: 'a render shows the top');
    });

    test('Log follows the newest line until scrolled up; End follows again', () async {
      final term = fake(width: 10, height: 3);
      final log = Log(['a', 'b', 'c', 'd']);
      final run = on(
        term,
        () => Tui.run(
          0,
          draw: (_) => log,
          update: (n, e) => switch (e) {
            KeyPress(name: 'n') => (log..lines.add('n${log.lines.length}')).lines.length,
            KeyPress(name: 'q') => Tui.quit(n),
            _ => n,
          },
        ),
      );
      await pump();
      expect(rows(term), ['b', 'c', 'd']);
      term.type('n');
      await pump();
      expect(rows(term), ['c', 'd', 'n4']);
      term.press(KeyPress.up);
      await pump();
      expect(rows(term), ['b', 'c', 'd']);
      term.type('n');
      await pump();
      expect(rows(term), ['b', 'c', 'd'], reason: 'scrolled up: it stays');
      term.press(KeyPress.end);
      term.type('n');
      await pump();
      expect(rows(term), ['n4', 'n5', 'n6']);
      term.type('q');
      await run;
      expect(plain(Log(['x' * 20]), 6), 'xxxxx…');
    });
  });
  group('the pointer, buttons and popups', () {
    test('a moving pointer is hover: builders get it, and a button looks it (?1003h)', () async {
      final term = fake(width: 20, height: 3);
      final run = on(
        term,
        () => Tui.run<int, Object>(
          0,
          pointer: true,
          draw: (_) => VStack([Button('Go', message: 1), Clickable(Label('link'), message: 2)]),
          update: (s, e) => e == KeyPress.esc ? Tui.quit(s) : s,
        ),
      );
      await pump();
      expect(term.isMotion, isTrue);
      final before = term.writes.length;
      term.pointer(1, 1, PointerKind.move);
      await pump();
      expect(term.writes.skip(before).join(), contains('\x1b[0;4m'), reason: 'the hovered link is underlined');
      term.press(KeyPress.esc);
      await run;
      expect(term.isMotion, isFalse);
    });

    test('a button sends its message on a click, on Enter and on Space; a disabled one does nothing', () async {
      final term = fake(width: 30, height: 3);
      final got = <String>[];
      final run = on(
        term,
        () => Tui.run<int, String>(
          0,
          pointer: true,
          draw: (n) => HStack([Button('Save', message: 'save'), Button('Off', message: 'off', enabled: false)], gap: 1),
          update: (s, e) {
            if (e case Post(:final message)) got.add(message);
            return e == KeyPress.esc ? Tui.quit(s) : s + 1;
          },
        ),
      );
      await pump();
      expect(term.screen, '[ Save ] [ Off ]');
      term
        ..pointer(2, 0)
        ..pointer(2, 0, PointerKind.release);
      await pump();
      term.press(KeyPress.enter);
      await pump();
      term.type(' ');
      await pump();
      term
        ..pointer(11, 0)
        ..pointer(11, 0, PointerKind.release);
      await pump();
      expect(got, ['save', 'save', 'save'], reason: 'the focus stays on a button built anew each frame');
      term.press(KeyPress.esc);
      await run;
    });

    test('a press that ends off the button is no click', () async {
      final term = fake(width: 30, height: 3);
      var clicks = 0;
      final run = on(
        term,
        () => Tui.run<int, int>(
          0,
          pointer: true,
          draw: (_) => Button('Go', message: 1),
          update: (s, e) {
            if (e is Post) clicks++;
            return e == KeyPress.esc ? Tui.quit(s) : s;
          },
        ),
      );
      await pump();
      term
        ..pointer(2, 0)
        ..pointer(20, 2, PointerKind.release);
      await pump();
      expect(clicks, 0);
      term.press(KeyPress.esc);
      await run;
    });

    test('a popup draws above the rest under its anchor; a click outside sends its dismiss', () async {
      final term = fake(width: 20, height: 6);
      final run = on(
        term,
        () => Tui.run<bool, String>(
          true,
          pointer: true,
          draw: (open) => VStack([
            if (open) Popup(Label('File'), content: Box(Label('Open')), dismiss: 'close') else Label('File'),
            Label('body'),
          ]),
          update: (open, e) => switch (e) {
            Post(message: 'close') => false,
            KeyPress.esc => Tui.quit(open),
            _ => open,
          },
        ),
      );
      await pump();
      expect(term.screen.split('\n').take(4), ['File', '╭──────╮', '│ Open │', '╰──────╯']);
      term
        ..pointer(1, 2)
        ..pointer(1, 2, PointerKind.release);
      await pump();
      expect(term.screen, contains('Open'), reason: 'a click inside keeps it');
      term.pointer(15, 5);
      await pump();
      expect(term.screen, 'File\nbody');
      term.press(KeyPress.esc);
      expect(await run, isFalse);
    });

    test('a modal popup alone takes the keys and the pointer', () async {
      final term = fake(width: 30, height: 7);
      final behind = Field(prompt: '> ');
      final inside = Field(prompt: '? ');
      final run = on(
        term,
        () => Tui.run<int, String>(
          0,
          draw: (_) => VStack([behind, Popup.modal(Box(inside), dismiss: 'x')]),
          update: (s, e) => e == KeyPress.esc ? Tui.quit(s) : s,
        ),
      );
      await pump();
      term.type('hi');
      await pump();
      expect((behind.text, inside.text), ('', 'hi'));
      term.press(KeyPress.esc);
      await run;
    });

    test('a tooltip shows while the pointer is over its child', () async {
      final term = fake(width: 20, height: 4);
      final run = on(
        term,
        () => Tui.run<int, Never>(
          0,
          pointer: true,
          draw: (_) => Tooltip(Label('hover me'), 'a tip'),
          update: (s, e) => e == KeyPress.esc ? Tui.quit(s) : s,
        ),
      );
      await pump();
      expect(term.screen, 'hover me');
      term.pointer(2, 0, PointerKind.move);
      await pump();
      expect(term.screen, 'hover me\n a tip');
      term.pointer(15, 3, PointerKind.move);
      await pump();
      expect(term.screen, 'hover me');
      term.press(KeyPress.esc);
      await run;
    });

    test('inline, the mouse works: the region is found by a cursor position report (overrides TUI-1)', () async {
      final term = fake(width: 20, height: 8);
      term.write('one\r\ntwo\r\nthree\r\n');
      var clicked = 0;
      final run = on(
        term,
        () => Tui.run<int, int>(
          0,
          inline: true,
          pointer: true,
          draw: (_) => VStack([Label('title'), Button('Go', message: 1)]),
          update: (s, e) {
            if (e is Post) clicked++;
            return e == KeyPress.esc ? Tui.quit(s) : s;
          },
        ),
      );
      await pump(6);
      expect(term.writes.join(), contains('\x1b[6n'));
      // The region starts at screen row 3: the button is on row 4.
      term
        ..pointer(2, 4)
        ..pointer(2, 4, PointerKind.release);
      await pump();
      expect(clicked, 1);
      term
        ..pointer(2, 1)
        ..pointer(2, 1, PointerKind.release);
      await pump();
      expect(clicked, 1, reason: 'a click above the region is not the app\'s');
      term.press(KeyPress.esc);
      await run;
    });

    test('Tui.quit with a state of another type is an ArgumentError; listen answers its stop', () async {
      final term = fake();
      final ticks = StreamController<int>.broadcast();
      late void Function() stop;
      final run = on(
        term,
        () => Tui.run<int, int>(
          0,
          draw: (n) => Label('$n'),
          update: (n, e) => switch (e) {
            Start() => (stop = Tui.listen(ticks.stream), n).$2,
            Post(:final message) => n + message,
            KeyPress(name: 'q') => Tui.quit('not an int'),
            _ => n,
          },
        ),
      );
      await pump();
      ticks.add(2);
      await pump();
      stop();
      ticks.add(5);
      await pump();
      expect(term.screen, '2');
      term.type('q');
      await expectLater(run, throwsArgumentError);
    });
  });

  group('Field: lines and suggestions', () {
    test('Shift+Enter (kitty) or Alt+Enter starts a line; Enter still submits', () async {
      final term = fake(width: 20, height: 6, kitty: true);
      final input = Field(prompt: '> ', lines: 3);
      final run = on(
        term,
        () => Tui.run<String, Never>(
          '',
          draw: (_) => input,
          update: (s, e) => e == KeyPress.enter ? Tui.quit(input.text) : s,
        ),
      );
      await pump();
      expect(term.isKitty, isTrue, reason: 'a terminal that answers ?u is switched to the protocol');
      term
        ..type('one')
        ..press(const KeyPress('enter', shift: true))
        ..type('two')
        ..type('\x1b\r')
        ..type('three');
      await pump();
      expect(term.screen, '> one\n  two\n  three');
      term.press(KeyPress.enter);
      expect(await run, 'one\ntwo\nthree');
      expect(term.isKitty, isFalse, reason: 'put back on the way out');
    });

    test('a long line wraps and the field grows to its lines', () {
      final f = Field(text: 'abcdefghij', lines: 3);
      expect(f.heightAt(5), 3);
      expect(plain(f, 5), 'abcd\nefgh\nij');
      expect(() => Field(lines: 0), throwsArgumentError);
      expect(() => Field(lines: 2, mask: '*'), throwsArgumentError);
    });

    test('suggest offers completions in a popup: Down chooses, Tab takes one', () async {
      final term = fake(width: 30, height: 8);
      const commands = ['/help', '/history', '/quit'];
      final input = Field(
        prompt: '> ',
        suggest: (t) => [
          for (final c in commands)
            if (t.isNotEmpty && c.startsWith(t)) c,
        ],
      );
      final run = on(
        term,
        () => Tui.run<String, Never>(
          '',
          draw: (_) => VStack([input, Label('below')]),
          update: (s, e) => e == KeyPress.enter ? Tui.quit(input.text) : s,
        ),
      );
      await pump();
      term.type('/h');
      await pump();
      expect(term.screen, contains('/help'));
      expect(term.screen, contains('/history'));
      term
        ..press(KeyPress.down)
        ..press(KeyPress.tab);
      await pump();
      expect(input.text, '/history');
      expect(term.screen, '> /history\nbelow');
      term.press(KeyPress.enter);
      expect(await run, '/history');
    });
  });

  group('Picture and Markdown', () {
    Uint8List pixels(List<int> rgba) => Uint8List.fromList(rgba);

    test('a picture is half-block cells, the upper pixel the glyph, the lower its background', () async {
      final red = [255, 0, 0, 255], blue = [0, 0, 255, 255], clear = [0, 0, 0, 0];
      final picture = Picture(
        [
          pixels([...red, ...clear, ...blue, ...blue]),
        ],
        width: 2,
        height: 2,
      );
      expect(picture.width, 2);
      expect(picture.heightAt(2), 1);
      final drawn = picture.render(2, theme: const TuiTheme(), color: true);
      expect(Style.plain(drawn), '▀▄');
      expect(drawn, allOf(contains('255;0;0'), contains('0;0;255')));
      expect(() => Picture([pixels(red)], width: 2, height: 2), throwsArgumentError);
    });

    test('a picture of several frames animates', () async {
      final term = fake(width: 4, height: 2);
      final a = pixels([255, 0, 0, 255]), b = pixels([0, 255, 0, 255]);
      final run = on(
        term,
        () => Tui.run<int, Never>(
          0,
          draw: (_) => Picture([a, b], width: 1, height: 1, every: const Duration(milliseconds: 20)),
          update: (s, e) => e is Start ? s : Tui.quit(s),
        ),
      );
      await pump();
      final first = term.writes.length;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(term.writes.length, greaterThan(first));
      term.type('q');
      await run;
    });

    test('markdown draws headings, emphasis, code, lists, quotes and links', () {
      const text = """# Title

Some **bold** and *italic* with `code` and a [link](https://dart.dev).

- one
- two

> quoted

```
let x = 1;
```""";
      final drawn = plain(const Markdown(text), 40);
      expect(drawn.split('\n'), [
        'Title',
        '',
        'Some bold and italic with code and a',
        'link.',
        '',
        '• one',
        '• two',
        '',
        '│ quoted',
        '',
        '  let x = 1;',
      ]);
      final styled = const Markdown(
        'a [link](https://dart.dev) **b**',
      ).render(30, theme: const TuiTheme(), color: true);
      expect(styled, contains('\x1b]8;;https://dart.dev\x1b\\'), reason: 'a link is OSC 8');
      expect(styled, contains('\x1b[0;1mb'));
    });
  });
}

enum Mode { debug, release }

/// [state], once [effect] has run: a side effect inside a `switch` expression.
S _post<S>(S state, void Function() effect) {
  effect();
  return state;
}

final class _Counter extends TuiApp<int, int> {
  _Counter() : super(0);

  @override
  Widget draw(int n) => Label('$n');

  @override
  int update(int n, TuiEvent<int> e) => switch (e) {
    KeyPress.up => n + 1,
    Post(:final message) => n + message,
    KeyPress.enter || KeyPress(name: 'q') => Tui.quit(n),
    _ => n,
  };
}
