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
import 'dart:async';
import 'dart:io';
import 'package:dart_toolkit/console.dart';

Future<void> main(List<String> args) async {
  final log = File(args[0]);
  final mode = args[1];
  switch (mode) {
    case 'bar':
      final bar = Console.progressBar(
        100,
        label: 'a very long label that must be cut somewhere along the way',
      );
      for (var i = 0; i < 5; i++) {
        bar.tick(20);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      await bar.close();
    case 'leak':
      Console.progressBar(10).tick(3);
      stdout.writeln('ready-leak');
    case 'over':
      final bar = Console.progressBar(3);
      bar.tick(5).tick(-2);
      await bar.close();
    case 'evil':
      await Console.choose('Pick', ['a\x1b[31mb\nc'], label: (s) => s);
    case 'choose':
      final pick = await Console.choose('Pick', ['red', 'green', 'blue'],
          label: (s) => s);
      await log.writeAsString('pick=$pick\n');
    case 'ask':
      final answer = await Console.ask('Name?');
      await log.writeAsString('answer=$answer\n');
    case 'ask2':
      final a = await Console.ask('A?');
      final b = await Console.ask('B?');
      await log.writeAsString('answer=$a|$b\n');
    case 'secret':
      final answer = await Console.ask('Password?', secret: true);
      await log.writeAsString('secret=$answer\n');
  }
}
