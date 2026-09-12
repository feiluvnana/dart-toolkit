// Say what the script is doing.
//
//   dart run example/console.dart
//   dart run example/console.dart | cat        # the same run, no escape codes
//
// `system.console` splits four ways: `logger` for status lines, `writer` for
// structured output, `reader` for prompts, and `terminal`/`cursor` for the
// screen itself. Everything that only makes sense on a screen — colour, a
// repainting bar, a spinner — is skipped when output is redirected, so a
// piped run carries text and nothing else.

import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final log = system.console.logger;
  final out = system.console.writer;

  // ------------------------------------------------------------------ status
  log.level = .debug; // The default is `info`, which hides `debug`.
  out.rule('console');

  log.step(1, 3, 'Resolving');
  log.info('Six targets to build.');
  log.debug('Cache at .cache, 12 entries.');
  log.warn('One target has no tests.');
  log.error('One target failed to link.');
  log.ok('Everything else is fine.');

  // `task` wraps a future in a start/finish pair and reports what it threw.
  await log.task('Warming up', () => util.time.wait(80.ms));

  // For a machine on the other end, one JSON object per line instead.
  log.format = .json;
  log.info('Structured for a log collector.');
  log.format = .plain;

  // ------------------------------------------------------------------ moving
  log.step(2, 3, 'Working');

  // A spinner for work with no measurable total.
  final spinner = system.console.spinner()..start('Resolving dependencies');
  await util.time.wait(300.ms);
  spinner.ok('Dependencies resolved.');

  // A bar for work that has one. Off a terminal it draws nothing at all, so
  // anything the run must report either way belongs in a log line.
  final bar = Progress(total: 20, message: 'Building');
  for (var i = 0; i < 20; i++) {
    await util.time.wait(15.ms);
    bar.tick();
  }
  bar.done();
  log.ok('Built 20 targets.');

  // ----------------------------------------------------------------- results
  log.step(3, 3, 'Summary');

  out.write(
    (Table(
      headers: ['Target', 'Size', 'Result'],
      alignments: [.left, .right, .left],
      style: .unicode,
    )..addAll([
        ['app', util.size.format(1481012), 'ok'],
        ['worker', util.size.format(233472), 'ok'],
        ['cli', util.size.format(98304), 'failed'],
      ])).render(),
  );

  out.box(
    [
      'Targets   3',
      'Failed    1',
      'Elapsed   ${util.time.format(1.m + 12.s)}',
    ].join('\n'),
    title: 'Result',
  );

  // Colour is an extension on String, so it composes with anything that takes
  // one. Off a terminal these return the string unchanged.
  out.writeln(
    '${'passed'.brightGreen()} · ${'failed'.brightRed()} · ${'skipped'.dim()}',
  );

  // Prompts live on the reader, and are left out here so the example stays
  // non-interactive:
  //
  //   final name = await system.console.reader.ask('Name?', fallback: 'anon');
  //   final go   = await system.console.reader.confirm('Continue?');
  //   final pick = await system.console.reader.pick('Which?', ['a', 'b']);
  //   await system.console.reader.close();
}
