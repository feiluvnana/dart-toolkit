/// cli: typed options and arguments, subcommands, usage and exit codes. Runs a demo argv when given none.
///
/// `dart run examples/cli.dart greet --shout Ada`
library;

import 'dart:io' show exitCode;

import 'package:dart_toolkit/cli.dart';

Future<void> main(List<String> args) async {
  final shout = Flag('shout', 'Upper-case it.', short: 's');
  final times = Opt<int>('times', 'Repeat.', short: 'n', or: 1);
  final name = Arg<String>('name', 'Who to greet.', required: true);
  exitCode = await Command(
    'demo',
    'A tiny CLI.',
    commands: [
      Command(
        'greet',
        'Say hello.',
        params: [shout, times, name],
        handler: (c) {
          final line = 'hello ${c(name)}';
          for (var i = 0; i < c(times); i++) {
            print(c(shout) ? line.toUpperCase() : line);
          }
        },
      ),
    ],
  ).run(args.isEmpty ? ['greet', '-s', '-n', '2', 'Ada'] : args);
}
