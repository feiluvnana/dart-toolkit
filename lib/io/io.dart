/// # Filesystem
///
/// One type: [Path]. Every filesystem operation is one of its members, and
/// **every write is atomic** — content is staged through a `.part` file and
/// renamed into place, so a file appears whole or not at all even if the
/// script is killed mid-write.
///
/// ```dart
/// final out = Path.cwd / 'output';
/// await out.makeDir();
/// await (out / 'report.txt').writeText(report);      // atomic
/// await (out / 'data.json').writeJson(rows);         // atomic
///
/// for (final entry in await Path('src').walk(match: '*.dart')) {
///   print('${entry.path} ${entry.size}');
/// }
///
/// await Path('sync.lock').lock(() async => rebuild());
/// ```
///
/// Blocking calls are under one member rather than behind a suffix on every
/// name: `path.sync.readText()`. See [SyncPath].
///
/// Listing gives [FileSystemEntry] values — a snapshot of one stat, with
/// nothing to close.
///
/// Reading a JSON, YAML or TOML *document* goes through the same [Path.read],
/// with the codec as a leading dot: `read(.yaml)`. Downloading is
/// [Http.download], because a socket belongs to `net`.
/// {@category Files}
library;

export 'entry.dart';
export 'path.dart';
export '../src/fs.dart' show Algo;
export '../src/lock.dart' show LockedError;
