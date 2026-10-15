// backup: archive a folder into backups/ and delete archives older than --keep. One run at a
// time (a second cron run exits with one line); safe to Ctrl-C (writes are atomic).
//
//   dart run projects/backup.dart <dir> [--keep 30d] [--to backups]
//
// With BACKUP_PASSWORD set (in the environment or .env) the archive is an encrypted .7z,
// otherwise a .tgz. Names carry the time: notes-2026-10-15_143000.tgz.
library;

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';

final _dir = Arg<String>('dir', 'Folder to back up.', required: true);
final _keep = Opt('keep', 'Delete archives older than this.', or: 30.days);
final _to = Opt('to', 'Where the archives go.', or: 'backups');
final _password = Opt<String?>('password', 'Encrypt as 7z.', env: 'BACKUP_PASSWORD');

Future<void> main(List<String> args) => Command(
  'backup',
  'Archive a folder and rotate old archives.',
  params: [_dir, _keep, _to, _password],
  dotenv: '.env',
  handler: _run,
).run(args);

Future<void> _run(Context c) async {
  final source = Fs.dir(c(_dir));
  if (!await source.exists()) throw UsageException('No folder "${source.path()}".');
  final to = Fs.dir(c(_to));
  await to.file('.lock').lock(() async {
    final password = c(_password);
    final name = '${source.name()}-${DateTime.now().format('yyyy-MM-dd_HHmmss')}.${password == null ? 'tgz' : '7z'}';
    final archive = Archive.archive(
      [source.name()],
      dir: source.parent().path(),
      format: password == null ? .tgz : .sevenZip,
      password: password,
    );
    await Console.spin('archiving ${source.path()}', archive > to.file(name));
    final rows = <List<Object?>>[];
    for (final old in await to.list(match: '${source.name()}-*.{tgz,7z}')) {
      final age = DateTime.now().difference(await old.modified());
      final expired = age > c(_keep);
      if (expired) await old.delete();
      rows.add([old.name(), age.human(), if (expired) 'deleted' else 'kept']);
    }
    Console.table(rows, header: ['archive', 'age', '']);
  });
}
