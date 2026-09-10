// Drive the machine: environment, subprocesses, archives, shutdown.
//
//   dart run example/shell.dart
//
// `system` is the OS half — what the shell did, what the user typed, what
// happens on Ctrl-C. `tool` is file formats, and only formats: an executable
// is `system.run` plus arguments, which is what the git section below uses.

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
  await format.zip.pack(dir, archive);
  final entries = await format.zip.list(archive);
  log.ok(
    'Packed ${entries.count()} entries, '
    '${util.size.format(io.stat(archive).size)}.',
  );

  // A single entry, read without unpacking the rest. Entry names are relative
  // to what was packed, which `list` is the way to check.
  log.info('Entries: ${[for (final e in entries.list) e.name]}');
  final notes = await format.zip.read(archive, 'notes.txt');
  log.info(
    'notes.txt is ${notes?.length ?? 0} bytes, unpacked from the archive',
  );

  // ------------------------------------------------------------ executables
  // `tool` holds formats, never binaries: a wrapper only ever has the five
  // subcommands somebody thought to add, where `system.run` has all of git.
  final head = await system.run('git', ['rev-parse', '--abbrev-ref', 'HEAD']);
  if (!head.ok) {
    log.debug('Not a git repository.');
  } else {
    final branch = head.out.trim();
    final dirty = (await system.run('git', ['status', '--porcelain'])).out;
    if (dirty.trim().isNotEmpty) {
      log.warn('On $branch with uncommitted changes.');
    } else {
      final hash = await system.run('git', ['rev-parse', '--short', 'HEAD']);
      log.ok('On $branch, clean at ${hash.out.trim()}.');
    }
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
