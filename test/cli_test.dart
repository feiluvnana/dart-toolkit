import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/testing.dart';
import 'package:test/test.dart';

/// Strips SGR, cursor moves and carriage returns: what the eye sees.
String _seen(String s) => s.replaceAll(RegExp('\x1b\\[[0-9;?]*[A-Za-z]|\r'), '');

void main() {
  tearDown(CliFake.reset);

  group('BarGlyphs', () {
    test('presets draw the fraction', () {
      expect(BarGlyphs.blocks.draw(0.5, 4), '██░░');
      expect(BarGlyphs.line.draw(0.5, 4), '━━╸─');
      expect(BarGlyphs.ascii.draw(0.5, 4), '##--');
      expect(BarGlyphs.arrow.draw(0.5, 4), '==>-');
      expect(BarGlyphs.blocks.draw(0.0, 3), '░░░');
      expect(BarGlyphs.blocks.draw(1.0, 3), '███');
    });
  });

  test('CliFake.lines feeds confirm', () async {
    CliFake.lines(['y']);
    expect(await Cli.confirm('Proceed?'), isTrue);
  });

  group('live bar line', () {
    test('paints the accent bar, dim details and human byte units', () async {
      CliFake.capture(live: true);
      final bar = Cli.bar(max: 100000000, label: 'Downloading', unit: 'B', size: 12);
      bar.set(25000000);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      bar.set(50000000);
      final line = CliFake.screen.single;
      expect(line, contains('\x1b[38;2;217;119;87m'));
      expect(line, contains('\x1b[2m'));
      final seen = _seen(line);
      expect(
        seen,
        matches(RegExp(r'^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] Downloading  [━]+╸?[─]*  50%  50\.0/100 MB · [\d.]+ \S+/s · \d+s left$')),
      );
      bar.close();
    });

    test('has no head at zero percent', () {
      CliFake.capture(live: true);
      final bar = Cli.bar(max: 100, label: 'Downloading', unit: 'items', size: 8);
      bar.set(0);
      final seen = _seen(CliFake.screen.single);
      expect(seen, contains('0%'));
      expect(seen, isNot(contains('╸')));
      bar.close();
    });

    test('pads labels to the longest live label', () {
      CliFake.capture(live: true);
      final a = Cli.bar(max: 100, label: 'Downloading', unit: 'items', size: 4);
      final b = Cli.bar(max: 100, label: 'Extracting', unit: 'items', size: 4);
      a.set(10);
      b.set(20);
      final seen = CliFake.screen.map(_seen).toList();
      expect(seen[0], contains('Downloading  '));
      expect(seen[1], contains('Extracting   '));
      a.close();
      b.close();
    });

    test('other units read raw', () {
      CliFake.capture(live: true);
      final bar = Cli.bar(max: 100, label: 'Copying', unit: 'items', size: 4);
      bar.set(50);
      expect(_seen(CliFake.screen.single), contains('50%  50/100 items'));
      bar.close();
    });
  });

  group('finished bar line', () {
    test('a complete byte bar names the total and the time', () {
      final buf = CliFake.capture();
      final bar = Cli.bar(max: 100000000, label: 'Downloading', unit: 'B');
      bar.set(100000000);
      bar.close();
      expect(_seen(buf.toString()), matches(RegExp(r'✓ Downloading  100 MB in \d+\.\d+s\n$')));
    });

    test('a complete count bar names the counts and the time', () {
      final buf = CliFake.capture();
      final bar = Cli.bar(max: 100, label: 'Copying', unit: 'items');
      bar.set(100);
      bar.close();
      expect(_seen(buf.toString()), matches(RegExp(r'✓ Copying  100/100 items in \d+\.\d+s\n$')));
    });

    test('an incomplete bar stops instead of ticking', () {
      final buf = CliFake.capture();
      final bar = Cli.bar(max: 100, label: 'Copying', unit: 'items');
      bar.set(50);
      bar.close();
      expect(_seen(buf.toString()), contains('✗ Copying  stopped at 50/100'));
    });

    test('a bar closes itself on reaching its total, learned from set', () {
      final buf = CliFake.capture();
      final bar = Cli.bar(label: 'Saving', unit: 'items');
      bar.set(0, 4);
      bar.set(2, 4);
      expect(_seen(buf.toString()), isNot(contains('✓')));
      bar.set(4, 4);
      expect(_seen(buf.toString()), matches(RegExp(r'✓ Saving  4/4 items in \d+\.\d+s\n$')));
      bar.set(1);
      expect(bar.value, 4);
    });

    test('an unknown total (0) keeps the total the bar has', () {
      CliFake.capture();
      final bar = Cli.bar(max: 10, unit: 'B');
      bar.set(4, 0);
      expect((bar.value, bar.max), (4, 10));
      bar.close();
    });

    test('an empty job closes its bar at once', () {
      final buf = CliFake.capture();
      Cli.bar(label: 'Nothing').set(0, 0);
      expect(_seen(buf.toString()), contains('✓ Nothing'));
    });

    test('Cli.each ticks per item and closes after the loop', () {
      final buf = CliFake.capture();
      final seen = [
        for (final item in Cli.each(['a', 'b', 'c'], label: 'Each')) item,
      ];
      expect(seen, ['a', 'b', 'c']);
      expect(_seen(buf.toString()), matches(RegExp(r'✓ Each  3/3 in \d+\.\d+s\n$')));
    });

    test('tick advances the value', () {
      CliFake.capture();
      final bar = Cli.bar(max: 3);
      bar.tick();
      expect(bar.value, 1);
      bar.close();
    });
  });

  group('spinner', () {
    test('a success ends with a tick and the seconds', () async {
      final buf = CliFake.capture();
      final value = await Cli.spin('Fetching', () async => 42);
      expect(value, 42);
      expect(_seen(buf.toString()), matches(RegExp(r'✓ Fetching \d+\.\d+s\n$')));
    });

    test('a failure ends with a cross and rethrows', () async {
      final buf = CliFake.capture();
      await expectLater(Cli.spin('Work', () async => throw FormatException('bad')), throwsFormatException);
      expect(_seen(buf.toString()), contains('✗ Work failed: FormatException: bad'));
    });
  });

  group('prompts', () {
    test('confirm shows y/N and takes the default on empty', () async {
      final buf = CliFake.capture(lines: ['']);
      expect(await Cli.confirm('Proceed?'), isFalse);
      expect(_seen(buf.toString()), contains('? Proceed? (y/N) '));
    });

    test('confirm shows Y/n when the default is yes', () async {
      final buf = CliFake.capture(lines: ['']);
      expect(await Cli.confirm('Proceed?', or: true), isTrue);
      expect(_seen(buf.toString()), contains('? Proceed? (Y/n) '));
    });

    test('ask prompts with a question mark', () async {
      final buf = CliFake.capture(lines: ['ada']);
      expect(await Cli.ask('Your name?'), 'ada');
      expect(_seen(buf.toString()), contains('? Your name? '));
    });

    test('choose piped reads a number', () async {
      final buf = CliFake.capture(lines: ['2']);
      expect(await Cli.choose('Pick one', ['alpha', 'beta']), 1);
      final seen = _seen(buf.toString());
      expect(seen, contains('Pick one\n  1) alpha\n  2) beta\nChoice [1] '));
    });

    test('choose piped re-asks once, then takes the default', () async {
      final buf = CliFake.capture(lines: ['bogus', 'worse']);
      expect(await Cli.choose('Pick one', ['alpha', 'beta']), 0);
      expect('Choice [1] '.allMatches(_seen(buf.toString())).length, 2);
    });

    test('choose piped takes the default on empty', () async {
      CliFake.capture(lines: ['']);
      expect(await Cli.choose('Pick one', ['alpha', 'beta'], or: 1), 1);
    });

    test('choose on a terminal marks the current line', () async {
      final buf = CliFake.capture(live: true, lines: ['\x1b[B', '']);
      expect(await Cli.choose('Pick one', ['alpha', 'beta']), 1);
      final seen = _seen(buf.toString());
      expect(seen, contains('? Pick one'));
      expect(seen, contains('❯ beta'));
    });
  });

  group('colour and glyph fallbacks', () {
    test('no colour level prints plain lines', () {
      final buf = CliFake.capture(level: ColorLevel.none);
      final bar = Cli.bar(max: 100000000, label: 'Downloading', unit: 'B');
      bar.set(100000000);
      bar.close();
      expect(buf.toString(), isNot(contains('\x1b')));
      expect(_seen(buf.toString()), matches(RegExp(r'✓ Downloading  100 MB in \d+\.\d+s')));
    });

    test('without unicode, words and ascii stand in', () async {
      final buf = CliFake.capture(live: true, unicode: false);
      final bar = Cli.bar(max: 100, label: 'Copying', unit: 'items', size: 4);
      bar.set(50);
      expect(_seen(CliFake.screen.single), contains('50%  50/100 items'));
      expect(CliFake.screen.single, contains('#'));
      expect(CliFake.screen.single, isNot(contains('━')));
      bar.close();
      await Cli.spin('Fetching', () async => 1);
      final seen = _seen(buf.toString());
      expect(seen, contains('failed Copying  stopped at 50/100'));
      expect(seen, matches(RegExp(r'ok Fetching \d+\.\d+s')));
    });

    test('AnsiText is plain with the colour level off', () {
      CliFake.capture(level: ColorLevel.none);
      expect('oops'.red, 'oops');
      expect('oops'.bold, 'oops');
    });

    test('nested colours restore the outer colour', () {
      CliFake.capture();
      final s = 'a${'b'.red}c'.green;
      expect(_seen(s), 'abc');
      expect(s, contains('\x1b[0m\x1b[32m'));
    });
  });

  group('live region', () {
    test('a log line lands above, and both bars finish clean', () {
      final buf = CliFake.capture(live: true);
      final a = Cli.bar(max: 100, label: 'One', size: 4);
      final b = Cli.bar(max: 100, label: 'Two', size: 4);
      a.set(10);
      Cli.print('log line');
      b.set(20);
      a.set(100);
      b.set(100);
      a.close();
      b.close();
      final screen = CliFake.screen.map(_seen).toList();
      expect(screen.length, 3);
      expect(screen[0], 'log line');
      expect(screen[1], matches(RegExp(r'✓ One  100/100 in \d+\.\d+s')));
      expect(screen[2], matches(RegExp(r'✓ Two  100/100 in \d+\.\d+s')));
      final out = _seen(buf.toString());
      expect(out.indexOf('log line'), lessThan(out.indexOf('✓ One')));
      expect(out, isNot(contains('━')));
      expect(out, isNot(contains('%')));
    });
  });
}
