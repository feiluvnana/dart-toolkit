// Archives a folder into backups/ and deletes archives older than --keep.
//
//   dart run projects/backup/backup.dart <dir> [--keep 30d] [--to backups]
//
// Set BACKUP_PASSWORD (env or .env) to get an encrypted .7z instead of a .tgz.
// Safe to run from cron: a second run while one is going just exits.
library;

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';

final dirArg = Arg<String>('dir', 'Folder to back up.', required: true);
final keepOpt = Opt('keep', 'Delete archives older than this.', or: 30.days);
final toOpt = Opt('to', 'Where the archives go.', or: 'backups');
final passwordOpt = Opt<String?>('password', 'Encrypt as 7z.', env: 'BACKUP_PASSWORD');

Future<void> main(List<String> args) => Command(
  'backup',
  'Archive a folder and rotate old archives.',
  params: [dirArg, keepOpt, toOpt, passwordOpt],
  dotenv: '.env',
  handler: backup,
).run(args);

Future<void> backup(Context c) async {
  final source = Fs.dir(c(dirArg));
  if (!await source.exists()) throw UsageException('No folder "${source.path()}".');
  final backups = Fs.dir(c(toOpt));
  final password = c(passwordOpt);

  await backups.file('.lock').lock(() async {
    final stamp = DateTime.now().format('yyyy-MM-dd_HHmmss');
    final name = '${source.name()}-$stamp.${password == null ? 'tgz' : '7z'}';
    final archive = Archive.archive(
      [source.name()],
      dir: source.parent().path(),
      format: password == null ? .tgz : .sevenZip,
      password: password,
    );
    await (archive | Console.bar(null, label: 'archiving ${source.path()}') > backups.file(name));
    Console.log('saved ${backups.file(name).path()}${password == null ? '' : ' (encrypted)'}');

    final rows = <List<Object?>>[];
    for (final old in await backups.list(match: '${source.name()}-*.{tgz,7z}')) {
      final age = DateTime.now().difference(await old.modified());
      if (age > c(keepOpt)) {
        await old.delete();
        rows.add([old.name(), age.human(), 'deleted (older than ${c(keepOpt).human()})']);
      } else {
        rows.add([old.name(), age.human(), 'kept']);
      }
    }
    Console.table(rows, header: ['archive', 'age', 'status']);
  });
}
