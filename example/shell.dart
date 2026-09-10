// Drive the machine: environment, subprocesses, archives, git, shutdown.
//
//   dart run example/shell.dart
//
// `system` is the OS half — what the shell did, what the user typed, what
// happens on Ctrl-C. `tool` is the small set of outside things worth wrapping:
// `tool.git` and `tool.zip`.

import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final log = system.console.logger;
  final dir = io.join('output', 'shell');

  // ------------------------------------------------------------- environment
  // `.env` fills in what the shell did not set; nothing fails if it is absent.
  // `get` is typed by its fallback, so a bool reads '1', 'yes' and 'true'.
  system.env.load();
  log.info('label   ${system.env.get('RUN_LABEL', 'demo')}');
  log.info('workers ${system.env.get('WORKERS', 4)}');
  log.info('debug   ${system.env.get('DEBUG', false)}');

  // ------------------------------------------------------------ subprocesses
  // `which` answers before you shell out to something that is not installed.
  final dart = system.which('dart');
  log.info('dart    ${dart ?? 'not on PATH'}');

  final res = await system.run('echo', ['hello from a subprocess']);
  log.ok('exit ${res.code}: ${res.out.trim()}');

  // Failures come back as a result rather than an exception, so a script can
  // decide for itself what a non-zero exit means.
  final bad = await system.run('ls', ['/definitely/not/here']);
  if (!bad.ok) log.warn('ls exited ${bad.code}: ${util.text.clean(bad.err)}');

  // ---------------------------------------------------------------- archives
  io.write(io.join(dir, 'notes.txt'), 'built ${util.time.iso()}');
  io.dump(io.join(dir, 'data.json'), {'ok': true});

  // The format comes from the destination's extension: .zip, .tar.gz, .tgz,
  // .tar.bz2. `unpack` skips entries that would escape the destination.
  final archive = io.join('output', 'shell-${util.time.stamp()}.tar.gz');
  await tool.zip.pack(dir, archive);
  final entries = await tool.zip.list(archive);
  log.ok(
    'Packed ${entries.length} entries, '
    '${util.size.format(io.stat(archive).size)}.',
  );

  // A single entry, read without unpacking the rest. Entry names are relative
  // to what was packed, which `list` is the way to check.
  log.info('Entries: ${[for (final e in entries) e.name]}');
  final notes = await tool.zip.read(archive, 'notes.txt');
  log.info(
    'notes.txt is ${notes?.length ?? 0} bytes, unpacked from the archive',
  );

  // -------------------------------------------------------------------- git
  final branch = await tool.git.branch();
  if (branch.isEmpty) {
    log.debug('Not a git repository.');
  } else if (await tool.git.dirty()) {
    log.warn('On $branch with uncommitted changes.');
  } else {
    log.ok('On $branch, clean at ${await tool.git.hash()}.');
  }

  // ---------------------------------------------------------------- shutdown
  // Registering an exit hook starts the SIGINT watcher, so a Ctrl-C runs the
  // same cleanup a normal finish does. The watcher holds the process open,
  // which is why a script that registers one ends with `system.shutdown()`.
  system.on.exit(() async {
    await io.async.delete(dir, recursive: true);
    log.debug('Removed $dir/.');
  });

  await system.shutdown();
}
