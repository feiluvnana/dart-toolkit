// Pty/subprocess helper for test/console_test.dart.
//
// Usage: probe.dart <log> <mode>
// Modes: bar | choose | ask | secret
//   bar:    a 100-item bar with a long label under the pty, then close.
//   choose: interactive choose of [red, green, blue]; writes the pick.
//   leak:   ticks a bar and returns without closing it; must still exit.
//   over:   ticks past the total and by a negative count; close prints the count.
//   evil:   choose over a label with ESC and a newline (piped).
//   ask:    reads one line (piped stdin); writes the answer.
//   ask2:   reads two lines; writes both.
//   secret: reads one secret line; writes the answer.
//   eof:    every prompt on an empty stdin; writes what each gave back.
//   empty:  prompts answered by empty lines (stdin is \n per prompt).
import 'dart:async';
import 'dart:io';
import 'package:dart_toolkit/console.dart';

Future<void> main(List<String> args) async {
  final log = File(args[0]);
  final mode = args[1];
  if (Platform.environment['PROBE_ACCENT'] != null) Console.accent = Color.orange;
  switch (mode) {
    case 'bar':
      final bar = Console.bar(
        100,
        label: 'a very long label that must be cut somewhere along the way',
      );
      for (var i = 0; i < 5; i++) {
        bar.tick(20);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      await bar.close();
    case 'spin':
      await Console.spin('working', Future<void>.delayed(const Duration(milliseconds: 400)));
      stdout.writeln('spun');
    case 'leak':
      Console.bar(10).tick(3);
      stdout.writeln('ready-leak');
    case 'total':
      final bar = Console.bar(null, label: 'T');
      bar.tick(2).setTotal(4);
      Console.log('logged above');
      await bar.close();
    case 'over':
      final bar = Console.bar(3);
      bar.tick(5).tick(-2);
      await bar.close();
    case 'evil':
      await Console.choose('Pick', ['a\x1b[31mb\nc']);
    case 'choose':
      final pick = await Console.choose('Pick', ['red', 'green', 'blue'], or: 'red');
      await log.writeAsString('pick=$pick\n');
    case 'ask':
      final answer = await Console.ask('Name?');
      await log.writeAsString('answer=$answer\n');
    case 'ask2':
      final a = await Console.ask('A?');
      final b = await Console.ask('B?');
      await log.writeAsString('answer=$a|$b\n');
    case 'eof':
      final a = await Console.ask('A?');
      final b = await Console.ask('B?', or: 'dflt');
      final c = await Console.confirm('C?', or: true);
      final d = await Console.confirm('D?');
      final e = await Console.choose('E', ['x', 'y']);
      final f = await Console.choose('F', ['x', 'y'], or: 'y');
      await log.writeAsString('eof=$a|$b|$c|$d|$e|$f\n');
    case 'empty':
      final a = await Console.ask('A?', or: 'dflt');
      final b = await Console.ask('B?');
      final c = await Console.confirm('C?', or: true);
      await log.writeAsString('empty=$a|$b|$c\n');
    case 'secret':
      final answer = await Console.ask('Password?', secret: true);
      await log.writeAsString('secret=$answer\n');
  }
}
