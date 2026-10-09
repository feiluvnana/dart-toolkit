// A program with detached jobs, for `jobs_test.dart`. Its pool keeps its jobs in `$POOL_HOME`.
//
// - `add <name>`: a detached job and a foreground one (`<name>-here`), then it ends;
// - `wait <name>…`: shows the jobs until each named one has finished, then prints them as JSON;
// - `remove <name>`: removes that job, once the pool shows it.
//
// A name starting `long` takes three seconds. With `VIA_CLI` set it runs under `Cli(pools:)`
// instead of calling `Pool.serve` itself.
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/cli.dart';

final home = Platform.environment['POOL_HOME']!;

/// Counts a tenth of a second at a time, then writes `<home>/<name>.out`; a run that does not
/// finish writes `<home>/<name>.stopped`.
final class Slow extends Worker<String, String> {
  @override
  Future<String> run(String name, Work work) async {
    work.defer(() async {
      if (work.ended is! Done) await File('$home/$name.stopped').writeAsString('$pid');
    });
    final steps = name.startsWith('long') ? 30 : 10;
    for (var i = 1; i <= steps; i++) {
      await 100.ms.delay();
      work.amount(i, total: steps, unit: Unit.items);
    }
    if (name.startsWith('fail')) throw PathNotFoundException('$home/$name', const OSError('gone', 2), 'Cannot read');
    final out = File('$home/$name.out');
    await out.writeAsString('done $name by $pid');
    return out.path;
  }
}

final pool = Pool(Slow.new, concurrency: 2, store: Store(home));

final _words = Arg.of<String>('words', 'What to do').many();

Future<void> main(List<String> args) async {
  if (Platform.environment['VIA_CLI'] != null) {
    await Cli(
      'A pool with detached jobs.',
      values: [_words],
      pools: [pool],
      handler: (ctx) => _act(ctx(_words)),
    ).run(args);
  }
  await Pool.serve([pool]);
  await _act(args);
}

Future<void> _act(List<String> args) async {
  switch (args) {
    case ['add', final name]:
      pool.add(name, detached: true);
      pool.add('$name-here');
      await 300.ms.delay();
      await pool.close();
      print(pid);
    case ['remove', final name]:
      await _until(() => pool.job(name) != null);
      pool.job(name)!.remove();
      await pool.close();
    case ['wait', ...final names]:
      await _until(() => names.every((name) => pool.job(name)?.status.isFinal ?? false));
      print(
        jsonEncode([
          for (final job in pool.jobs)
            {
              'item': job.item,
              'detached': job.isDetached,
              'status': switch (job.status) {
                Done(:final value) => value,
                Failed(:final error) => '${error.runtimeType}: $error',
                final other => '$other',
              },
            },
        ]),
      );
      await pool.close();
  }
}

/// Waits, as the pool's jobs change, until [done].
Future<void> _until(bool Function() done) async {
  final changes = pool.changes;
  while (!done()) {
    await changes.first.timeout(30.s);
  }
}
