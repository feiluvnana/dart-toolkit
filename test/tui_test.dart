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
        ui.box(title: 'App', build: (box) => box.text('Press "q" to exit.'));
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
      expect(term.snapshot.join('\n'), contains('❯ file_1.txt'));
      term.send('up');
      await term.poll();
      sel--;
      await frame();
      expect(term.snapshot.join('\n'), contains('❯ file_0.txt'));
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
      // Closed: the next draw or poll throws _Closed (which Tui.run swallows)
      // instead of spinning on nulls.
      final sw = Stopwatch()..start();
      await expectLater(term.poll(), throwsA(predicate((e) => e.runtimeType.toString() == '_Closed')));
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 100)));
      await expectLater(
        () => term.draw((ui) => ui.text('x')),
        throwsA(predicate((e) => e.runtimeType.toString() == '_Closed')),
      );
      await term.close();
      expect(term.closed, isTrue);
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
      await expectLater(term.poll(), throwsA(predicate((e) => e.runtimeType.toString() == '_Closed')));
      expect(cleaned, 1);
      expect(term.closed, isTrue);
    });

    test('a failing defer still restores the terminal, then rethrows first', () async {
      final term = FakeTerminal();
      var second = 0;
      term.defer(() async => throw StateError('first'));
      term.defer(() async => second++);
      await expectLater(term.close(), throwsStateError);
      expect(second, 1);
      expect(term.closed, isTrue);
    });

    test('a listen stream error arrives from the next poll', () async {
      final term = FakeTerminal();
      final controller = StreamController<String>();
      term.listen(controller.stream);
      controller.add('ok');
      expect(await term.poll(), const Post('ok'));
      controller.addError(StateError('stream boom'));
      await expectLater(term.poll(), throwsStateError);
      await controller.close();
      await term.close();
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

    test('^Z suspends the process and fg resumes it', () async {
      if (Platform.isWindows) {
        markTestSkipped('no SIGTSTP on Windows');
        return;
      }
      final term = FakeTerminal();
      // CONT spam for 5 s: a wakeup can never be missed, whenever the dance
      // stops (a CONT to a running process is a no-op).
      final helper = await Process.start('sh', [
        '-c',
        'for i in \$(seq 1 50); do kill -CONT \$1; sleep 0.1; done',
        '_',
        '$pid',
      ]);
      try {
        term.send('z', ctrl: true);
        expect(await term.poll(), isA<Suspend>());
        expect(await term.poll(), isA<Resume>());
      } finally {
        helper.kill();
        await helper.exitCode;
        await term.close();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a post wakes a waiting poll within 50 ms on a real terminal', () async {
      // Real backend only: under `script(1)` so stdout is a terminal. Skipped
      // when no pty is available.
      Future<bool> has(String bin) async {
        try {
          final r = await Process.run(Platform.isWindows ? 'where' : 'which', [bin]);
          return r.exitCode == 0;
        } catch (_) {
          return false;
        }
      }

      if (!await has('script')) {
        markTestSkipped('no script(1) for a pty');
        return;
      }
      final tmp = await Directory.systemTemp.createTemp('tk_tui_pty_');
      try {
        File('${tmp.path}/probe.dart').writeAsStringSync('''
import 'package:dart_toolkit/tui.dart';
Future<void> main() async {
  await Tui.run((term) async {
    await term.poll(); // Start
    term.post(1);
    final sw = Stopwatch()..start();
    final ev = await term.poll();
    sw.stop();
    if (ev != const Post(1)) {
      print('WRONG \$ev');
      throw StateError('expected Post(1), got \$ev');
    }
    print('POST_LATENCY_MS=\${sw.elapsedMilliseconds}');
  });
}
''');
        final dartArgs = [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          '${tmp.path}/probe.dart',
        ];
        late final List<String> cmd;
        if (Platform.isMacOS) {
          cmd = ['script', '-q', '/dev/null', Platform.executable, ...dartArgs];
        } else if (!Platform.isWindows) {
          cmd = ['script', '-qec', '${Platform.executable} ${dartArgs.join(' ')}', '/dev/null'];
        } else {
          markTestSkipped('no pty runner on Windows');
          return;
        }
        ProcessResult res;
        try {
          res = await Process.run(cmd.first, cmd.sublist(1)).timeout(const Duration(seconds: 50));
        } on TimeoutException {
          fail('probe under script(1) hung');
        }
        final out = '${res.stdout}${res.stderr}';
        if (out.contains('WRONG')) fail('probe saw the wrong event: $out');
        final match = RegExp(r'POST_LATENCY_MS=(\d+)').firstMatch(out);
        if (match == null) {
          markTestSkipped('no pty available under script(1): exit ${res.exitCode}: $out');
          return;
        }
        final ms = int.parse(match[1]!);
        expect(ms, lessThan(50), reason: 'post-to-poll latency was $ms ms');
      } finally {
        await tmp.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
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
        ui.box(title: 'a very long title indeed', build: (box) => box.text('x'));
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

    test('ui.bar lays out label, bar, pct, details like Cli.bar', () async {
      final term = FakeTerminal(width: 40, height: 4);
      term.draw((ui) => ui.bar(50000000, 100000000, label: 'Downloading', unit: 'B'));
      final row = term.snapshot[0];
      // Label first, then the bar, then pct and byte details.
      expect(row.indexOf('Downloading'), 0);
      final barAt = row.indexOf('━');
      final pctAt = row.indexOf('50%');
      final detAt = row.indexOf('50.0/100 MB');
      expect(barAt, greaterThan('Downloading'.length));
      expect(pctAt, greaterThan(barAt));
      expect(detAt, greaterThan(pctAt));
      // No head glyph at 0%.
      final empty = FakeTerminal(width: 40, height: 4);
      empty.draw((ui) => ui.bar(0, 100, label: 'Downloading', unit: 'B'));
      expect(empty.snapshot[0], isNot(contains('╸')));
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

    test('markdown runs share one row and wrap as one line', () async {
      final term = FakeTerminal(width: 40, height: 6);
      term.draw((ui) => ui.markdown('Hello **world** and `code`'));
      expect(term.snapshot[0], 'Hello world and code');
      final narrow = FakeTerminal(width: 10, height: 6);
      narrow.draw((ui) => ui.markdown('Hello **world** and `code`'));
      expect(narrow.snapshot.sublist(0, 3), ['Hello', 'world and', 'code']);
    });

    test('box sides continue from the top rule to the bottom one', () async {
      final term = FakeTerminal(width: 12, height: 5);
      term.draw((ui) {
        ui.box(title: 'T', build: (box) => box.text('hi'));
      });
      final rows = term.snapshot;
      expect(rows[0][0], '┌');
      expect(rows[0][11], '┐');
      expect(rows[1][0], '│');
      expect(rows[1][11], '│');
      expect(rows[1], contains('hi'));
      expect(rows[3][0], '│');
      expect(rows[3][11], '│');
      expect(rows[4][0], '└');
      expect(rows[4][11], '┘');
    });

    test('selection markers wear the console accent', () async {
      const accent = TuiColor.rgb(217, 119, 87);
      final term = FakeTerminal(width: 20, height: 6);
      term.draw((ui) {
        ui.list(['a', 'b'], selected: 1);
        ui.spinner('x');
        ui.tabs(['One', 'Two']);
        ui.button('go', focused: true, onPress: () {});
      });
      final grid = term.frames.last;
      expect(grid.at(0, 1).fg, accent); // ❯ marker
      expect(grid.at(0, 2).fg, accent); // spinner frame
      expect(grid.at(0, 3).fg, accent); // selected tab
      expect(grid.at(0, 4).fg, accent); // focused button
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

    test('a tap on an empty popup row fires nothing behind it', () async {
      final term = FakeTerminal(width: 30, height: 10);
      var behind = 0;
      var inside = 0;
      term.draw((ui) {
        ui.button('behind', onPress: () => behind++);
        ui.popup(
          title: 'Hey',
          width: 16,
          height: 5,
          build: (box) => box.button('in', onPress: () => inside++),
        );
      });
      term.tap(10, 4); // an empty popup row: swallowed
      expect(await term.poll(), isA<Pointer>());
      expect(behind, 0);
      expect(inside, 0);
      term.tap(9, 3); // the popup's own button: fires
      expect(await term.poll(), isA<Pointer>());
      expect(inside, 1);
      expect(behind, 0);
      term.tap(1, 0); // outside the popup: behind fires
      expect(await term.poll(), isA<Pointer>());
      expect(behind, 1);
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

    test('emoji and CJK take terminal columns', () {
      expect(textWidth('✓'), 1);
      expect(textWidth('🇯🇵'), 2);
      expect(textWidth('👨‍👩‍👧'), 2);
      expect(textWidth('👍🏽'), 2);
      expect(textWidth('日本'), 4);
      // The grid agrees: one cluster, its columns.
      final grid = Grid(10, 1);
      expect(grid.write(0, 0, '✓ok'), 3);
      expect(grid.write(0, 0, '🇯🇵x'), 3);
      expect(grid.write(0, 0, '👨‍👩‍👧x'), 3);
      expect(grid.write(0, 0, '👍🏽x'), 3);
      expect(grid.write(0, 0, '日本x'), 5);
    });

    test('field edits by grapheme and scrolls to the cursor', () async {
      final field = FieldState();
      field.handle(const KeyPress('a'));
      field.handle(KeyPress('👨‍👩‍👧'));
      expect(field.text, 'a👨‍👩‍👧');
      expect(field.cursor, 2);
      field.handle(KeyPress.backspace);
      expect(field.text, 'a');
      expect(field.cursor, 1);
      // Typed through keys the way a loop feeds them, surrogate pairs whole.
      final term = FakeTerminal(width: 20, height: 4);
      term.type('👍🏽');
      expect(await term.poll(), KeyPress('👍🏽'));
      // Narrower than the text: the cursor stays in view.
      final long = FieldState('hello world');
      final narrow = FakeTerminal(width: 6, height: 2);
      narrow.draw((ui) => ui.field(long, focused: true));
      expect(narrow.snapshot[0].replaceAll(' ', ''), contains('world'));
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
