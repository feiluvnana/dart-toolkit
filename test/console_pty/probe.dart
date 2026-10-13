// Pty/subprocess helper for test/console_test.dart.
//
// Usage: probe.dart <log> <mode>
// Modes: bar | choose | ask | secret
//   bar:    a 100-item bar with a long label under the pty, then close.
//   choose: interactive choose of [red, green, blue]; writes the pick.
//   ask:    reads one line (piped stdin); writes the answer.
//   secret: reads one secret line; writes the answer.
import 'dart:async';
import 'dart:io';
import 'package:dart_toolkit/console.dart';

Future<void> main(List<String> args) async {
  final log = File(args[0]);
  final mode = args[1];
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
    case 'choose':
      final pick = await Console.choose('Pick', ['red', 'green', 'blue']);
      await log.writeAsString('pick=$pick\n');
    case 'ask':
      final answer = await Console.ask('Name?');
      await log.writeAsString('answer=$answer\n');
    case 'secret':
      final answer = await Console.ask('Password?', secret: true);
      await log.writeAsString('secret=$answer\n');
  }
}
