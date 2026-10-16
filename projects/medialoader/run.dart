// A run: log in, confirm --reset, then every user at once under the
// dashboard; and `update`'s list of what was downloaded before.
library;

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';

import 'dashboard.dart';
import 'job.dart';
import 'platform.dart';
import 'platforms.dart';

// Downloads each target's kinds into [root]/<code>/<user>/, all at once:
// every user's explorers feed one queue. Logs in and asks before the
// dashboard opens.
Future<void> run(Map<Target, Set<Kind>> wants, Dir root, Options o) async {
  final apis = <Platform, Client>{};
  for (final p in {for (final t in wants.keys) t.platform}) {
    apis[p] =
        await p.login() ??
        (throw UsageException(
          '${p.name} downloads need a login: export ${p.site} cookies (and a "user-agent: …" line) '
          'into .${p.code}.session next to medialoader.dart.',
        ));
  }
  if (o.reset && !o.dry) {
    final what = [
      for (final MapEntry(key: t, value: k) in wants.entries) '@${t.user} (${k.map((k) => k.name).join(', ')})',
    ];
    final question =
        'Delete ${what.join(', ')} and download again? Removed posts and expired stories cannot be downloaded back.';
    if (!await Console.confirm(question)) throw UsageException('--reset cancelled, nothing deleted.');
  }
  board.apis.addAll(apis.values);
  await watch(() async {
    final added = await Future.wait([
      for (final MapEntry(key: t, value: kinds) in wants.entries)
        Job(t, kinds, apis[t.platform]!, root.dir(t.platform.code), o).run(),
    ]);
    Console.notify('medialoader: ${o.dry ? 'dry run' : 'done'}, ${added.fold(0, (a, b) => a + b)} new files');
  });
}

// Every user downloaded into [root] before (it has a .<code>.json), with
// the kinds it has folders for.
Future<Map<Target, Set<Kind>>> discover(Dir root) async {
  final out = <Target, Set<Kind>>{};
  for (final p in platforms) {
    if (!await root.dir(p.code).exists()) continue;
    for (final d in await root.dir(p.code).list()) {
      if (d is! Dir || !await d.file('.${p.code}.json').exists()) continue;
      out[Target(p, d.name())] = {
        for (final k in p.kinds)
          if (await d.dir(k.name).exists()) k,
      };
    }
  }
  return out;
}
