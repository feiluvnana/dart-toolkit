import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/src/tui/buffer.dart';
import 'package:dart_toolkit/src/tui/layout.dart';
import 'package:dart_toolkit/src/tui/term.dart';
import 'package:dart_toolkit/src/tui/width.dart';
import 'package:dart_toolkit/testing.dart';
import 'package:dart_toolkit/tui.dart';
import 'package:test/test.dart';

void main() {
  group('app loops', () {
    test('q ends the loop', () async {
      final term = FakeTerminal(width: 30, height: 6);
      term.draw((ui) {
        ui.box(title: 'App');
        ui.text('Press "q" to exit.');
      });
      expect(term.snapshot[0], contains('App'));
      term.send('q');
      final ev = await term.poll();
      expect(ev?.key, 'q');
    });

    test('arrow keys walk a file list', () async {
      final files = List.generate(50, (i) => 'file_$i.txt');
      var sel = 0;
      final term = FakeTerminal(width: 30, height: 8);
      Future<void> frame() async {
        term.draw((ui) {
          ui.box(
            title: 'root',
            build: (box) => box.list(files, selected: sel),
          );
        });
      }

      await frame();
      term.send('down');
      expect(await term.poll(), KeyPress.down);
      sel++;
      await frame();
      expect(term.snapshot.join('\n'), contains('▸ file_1.txt'));
      term.send('up');
      await term.poll();
      sel--;
      await frame();
      expect(term.snapshot.join('\n'), contains('▸ file_0.txt'));
    });

    test('a Chan drained into bars at a bounded pace', () async {
      final updates = Chan<(String, int)>(100);
      final stats = <String, int>{};
      await updates.send(('cpu', 30));
      await updates.send(('cpu', 70));
      final term = FakeTerminal(width: 30, height: 8);
      // The loop body: drain what is buffered, draw, pace with the
      // poll timeout.
      var seen = 0;
      await for (final stat in updates.recv()) {
        stats[stat.$1] = stat.$2;
        if (++seen == 2) break;
      }
      term.draw((ui) {
        ui.box(
          title: 'Live Monitor',
          build: (box) {
            box.bar(stats['cpu'] ?? 0, 100, label: 'CPU');
          },
        );
      });
      expect(term.snapshot.join('\n'), contains('70%'));
      final ev = await term.poll(timeout: const Duration(milliseconds: 100));
      expect(ev, isNull); // the pace-setting timeout, no input
      await updates.close();
    });
  });

  group('events and lifecycle', () {
    test('second ^C within 2 s ends the run', () async {
      final term = FakeTerminal();
      term.interrupt();
      expect(await term.poll(), isA<Interrupt>());
      term.draw((ui) => ui.text('still here'));
      expect(term.snapshot[0], 'still here');
      term.interrupt();
      expect(await term.poll(), isA<Interrupt>());
      expect(await term.poll(), isNull); // quit: nothing more
    });

    test('a lone ^C does not quit', () async {
      final term = FakeTerminal();
      term.interrupt();
      expect(await term.poll(), isA<Interrupt>());
      expect(await term.poll(timeout: const Duration(milliseconds: 10)), isNull);
    });

    test('resize redraws whole at the new size', () async {
      final term = FakeTerminal(width: 20, height: 4);
      term.draw((ui) => ui.text('hi'));
      final first = term.changes.last;
      expect(first, greaterThan(0));
      term.resize(10, 2);
      expect(await term.poll(), const Resize(10, 2));
      expect((term.w, term.h), (10, 2));
      term.draw((ui) => ui.text('hi'));
      expect(term.changes.last, 10 * 2);
      expect(term.snapshot, ['hi', '']);
    });

    test('post/listen/defer/close', () async {
      final term = FakeTerminal();
      var cleaned = 0;
      term.defer(() async => cleaned++);
      term.post('hello');
      expect(await term.poll(), const Post('hello'));
      final controller = StreamController<String>();
      term.listen(controller.stream);
      controller.add('streamed');
      final ev = await term.poll();
      expect(ev, const Post('streamed'));
      await controller.close();
      await term.close();
      expect(await term.poll(), isNull);
      expect(cleaned, 1);
      expect(term.closed, isTrue);
    });

    test('a Pointer press over a button calls onPress', () async {
      final term = FakeTerminal(width: 30, height: 6);
      var pressed = 0;
      term.draw((ui) => ui.button('go', onPress: () => pressed++));
      term.tap(0, 0);
      expect(await term.poll(), isA<Pointer>());
      expect(pressed, 1);
      term.tap(29, 5);
      expect(await term.poll(), isA<Pointer>());
      expect(pressed, 1);
    });

    test('term.post(1) is seen by the next poll as Post(1)', () async {
      final term = FakeTerminal();
      term.post(1);
      expect(await term.poll(), const Post(1));
    });
  });

  group('rendering budgets', () {
    test('10k rows paint the viewport only', () async {
      final term = FakeTerminal(width: 20, height: 6);
      final items = List.generate(10000, (i) => 'row_$i');
      term.draw((ui) => ui.list(items, selected: 9999));
      expect(term.snapshot, hasLength(6));
      expect(term.snapshot.join('\n'), contains('row_9999'));
      expect(term.frames.last.cells.length, 20 * 6);
    });

    test('one-label change writes < 40 cells', () async {
      final term = FakeTerminal(width: 30, height: 8);
      var label = 'alpha';
      void frame() => term.draw((ui) {
        ui.box(title: 'T', build: (box) => box.text(label));
      });
      frame();
      label = 'beta!';
      frame();
      expect(term.changes.last, lessThan(40));
    });

    test('long titles never break the frame', () async {
      final term = FakeTerminal(width: 12, height: 4);
      term.draw((ui) {
        ui.box(title: 'a very long title indeed');
        ui.text('x');
      });
      for (final row in term.snapshot) {
        expect(row.length, lessThanOrEqualTo(12));
      }
    });
  });

  group('widgets', () {
    test('spinner turns with the clock and keeps its label', () async {
      final term = FakeTerminal(width: 30, height: 2);
      term.draw((ui) => ui.spinner('Loading more…', glyphs: SpinGlyphs.ascii));
      final row = term.snapshot[0];
      expect(SpinGlyphs.ascii.frames, contains(row[0]));
      expect(row.substring(2).trimRight(), 'Loading more…');
      final at = DateTime(2026);
      final next = at.add(SpinGlyphs.dots.every);
      expect(SpinGlyphs.dots.frame(next), isNot(SpinGlyphs.dots.frame(at)));
    });

    test('split/box/bar/list compose', () async {
      final term = FakeTerminal(width: 40, height: 10);
      term.draw((ui) {
        ui.split([
          (left) {
            left.box(title: 'Menu', build: (box) => box.list(['Overview', 'Settings', 'Logs'], selected: 1));
          },
          (right) {
            right.box(
              title: 'Details',
              build: (box) {
                box.text('Server: online', fg: TuiColor.green);
                box.bar(64, 100, label: 'Memory');
              },
            );
          },
        ], vert: false);
      });
      final screen = term.snapshot.join('\n');
      expect(screen, contains('Menu'));
      expect(screen, contains('Details'));
      expect(screen, contains('Settings'));
      expect(screen, contains('64%'));
    });

    test('field edits, cursor and paint', () async {
      final term = FakeTerminal(width: 20, height: 4);
      final field = FieldState();
      term.type('abc');
      for (var i = 0; i < 3; i++) {
        expect(await term.poll(), isA<KeyPress>());
      }
      // Feed them through the field the way an update loop would.
      field.handle(const KeyPress('a'));
      field.handle(const KeyPress('b'));
      field.handle(const KeyPress('c'));
      field.handle(KeyPress.backspace);
      field.handle(const KeyPress('d'));
      expect(field.text, 'abd');
      term.draw((ui) => ui.field(field, focused: true));
      expect(term.snapshot[0], contains('abd'));
    });

    test('tabs, table, bar, markdown', () async {
      final term = FakeTerminal(width: 40, height: 20);
      term.draw((ui) {
        ui.tabs(['One', 'Two'], selected: 0);
        ui.table([
          ['a', 'b'],
          ['cc', 'd'],
        ]);
        ui.bar(30, 100, label: 'CPU');
        ui.markdown('# Hi\n- item\n**bold** and `code`');
      });
      final screen = term.snapshot.join('\n');
      expect(screen, contains('One'));
      expect(screen, contains('30%'));
      expect(screen, contains('Hi'));
      expect(screen, contains('• item'));
    });

    test('popup shades content beneath', () async {
      final term = FakeTerminal(width: 30, height: 10);
      term.draw((ui) {
        ui.text('background line here');
        ui.popup(title: 'Hey', width: 16, height: 5, build: (box) => box.text('inner'));
      });
      final screen = term.snapshot.join('\n');
      expect(screen, contains('Hey'));
      expect(screen, contains('inner'));
    });

    test('picture paints half-blocks from images', () async {
      // 4×2 red/green/blue/white checker, opaque.
      Image frame() => Image.fromRgba(
        Uint8List.fromList([
          255,
          0,
          0,
          255,
          0,
          255,
          0,
          255,
          0,
          0,
          255,
          255,
          255,
          255,
          255,
          255,
          255,
          255,
          255,
          255,
          255,
          255,
          255,
          255,
          0,
          0,
          0,
          255,
          255,
          255,
          255,
          255,
        ]),
        4,
        2,
      );
      final term = FakeTerminal(width: 10, height: 4);
      term.draw((ui) => ui.picture([frame()]));
      expect(term.snapshot[0], contains('▀'));
      expect(term.snapshot.length, 4);
    });

    test('bad frames are ArgumentErrors', () async {
      final term = FakeTerminal(width: 10, height: 4);
      expect(() => term.draw((ui) => ui.picture([])), throwsArgumentError);
      expect(
        () => term.draw(
          (ui) => ui.picture([Image.fromRgba(Uint8List(4 * 2 * 4), 4, 2), Image.fromRgba(Uint8List(2 * 2 * 4), 2, 2)]),
        ),
        throwsArgumentError,
      );
    });
  });

  group('units', () {
    test('widths, truncate, wrap', () {
      expect(textWidth('abc'), 3);
      expect(textWidth('日本'), 4);
      expect(textWidth('é'), 1); // e + combining acute
      expect(truncate('hello world', 5), 'hell…');
      expect(truncate('hi', 5), 'hi');
      final wrapped = wrap('aa bb cc dd', 5);
      expect(wrapped, ['aa bb', 'cc dd']);
    });

    test('flexSplit sums and spreads', () {
      expect(flexSplit(10, [1, 1]), [5, 5]);
      expect(flexSplit(10, [1, 1, 1]).fold(0, (a, b) => a + b), 10);
      expect(flexSplit(7, [3, 1]).fold(0, (a, b) => a + b), 7);
      expect(const Rect(0, 0, 10, 5).contains(9, 4), isTrue);
      expect(const Rect(0, 0, 10, 5).contains(10, 4), isFalse);
    });

    test('palette resolves down the ladder', () {
      expect(sgrFor(TuiColor.rgb(255, 0, 0), null, ColorLevel.truecolor, const CellStyle()), '38;2;255;0;0');
      expect(sgrFor(TuiColor.rgb(255, 0, 0), null, ColorLevel.ansi16, const CellStyle()), isNotEmpty);
      expect(sgrFor(TuiColor.green, null, ColorLevel.none, const CellStyle()), isEmpty);
      expect(NativeBackend.detectLevel({'NO_COLOR': '1'}), ColorLevel.none);
      expect(NativeBackend.detectLevel({'TERM': 'xterm-256color'}), ColorLevel.ansi256);
      expect(NativeBackend.detectLevel({'COLORTERM': 'truecolor'}), ColorLevel.truecolor);
      expect(NativeBackend.detectLevel({'TERM': 'xterm'}), ColorLevel.ansi16);
    });
  });

  group('import budget', () {
    test('tui compiles only its seam (no engine-wide imports)', () {
      final dir = Directory('lib/src/tui');
      final packageImport = RegExp(r'''import\s+'package:''');
      final ffiImport = RegExp(r'''import\s+'dart:ffi''');
      for (final entity in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final src = entity.readAsStringSync();
        expect(packageImport.hasMatch(src), isFalse, reason: '${entity.path} imports package: (rule 3)');
        if (entity.uri.pathSegments.last == 'native.dart' || entity.uri.pathSegments.last == 'term.dart') continue;
        expect(ffiImport.hasMatch(src), isFalse, reason: '${entity.path} compiles dart:ffi outside the seam');
      }
    });
  });
}
