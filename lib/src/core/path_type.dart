part of '../core.dart';

/// A filesystem path that is also a [String], so a literal needs no wrapping and a `Path` goes
/// wherever a `String` does.
///
/// Its parts (`/`, `name`, `ext`, `parent`, …) and everything that touches the disk come with
/// `path.dart`; here is the type every module can name, and the places to start from.
///
/// {@category Files}
extension type const Path(String _p) implements String {
  /// The user's home folder: `HOME`, else `USERPROFILE`; a [MissingException] when neither is
  /// set, rather than the working directory, where nothing lands unasked.
  static Path get home {
    if (Env.get<String?>('HOME') case final home?) return Path(home);
    if (Env.get<String?>('USERPROFILE') case final profile?) return Path(profile);
    throw const MissingException('home folder', where: 'HOME or USERPROFILE');
  }

  /// The system's temporary folder. For one of your own, see [tempDir].
  static Path get temp => Path(Directory.systemTemp.path);

  /// The working directory.
  static Path get cwd => Path(Directory.current.path);

  /// The running script's file, wherever the process was started from: `bin/tool.dart` under
  /// `dart run`, the executable itself when compiled, the test file under `dart test`. Its
  /// folder is `Path.here.parent`. A [MissingException] when there is no script file.
  static Path get here {
    final script = FileBridge.script();
    if (script.isEmpty) throw const MissingException('script file', where: 'this process');
    return Path(script);
  }

  /// Runs [body] with a new, empty folder under [temp], erased afterwards however [body] ended,
  /// and returns what [body] returned.
  ///
  /// ```dart
  /// final names = await Path.tempDir((dir) async {
  ///   await archive.unarchive(into: dir);
  ///   return [await for (final f in dir.files(only: '**')) f.name];
  /// });
  /// ```
  static Future<R> tempDir<R>(FutureOr<R> Function(Path dir) body) async {
    final dir = await Directory.systemTemp.createTemp('dart_toolkit_');
    try {
      return await body(Path(dir.path));
    } finally {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException catch (_) {} // a failed cleanup must not replace what body returned or threw
    }
  }
}

/// What happens when the destination of a copy, a move, a download, an extraction or a save is
/// already there. A folder is never in conflict: folders merge, and the policy applies to each
/// file inside.
///
/// {@category Files}
enum Conflict {
  /// Leave what is there, and report `Done(fresh: false)`: a rerun neither destroys nor
  /// duplicates. The default.
  skip,

  /// Replace it atomically: the new file is renamed over it, never deleted first.
  overwrite,

  /// Pick a free name beside it, `name (1).ext`, claimed so two items never pick one name.
  rename,

  /// Throw a [PathExistsException].
  fail,

  /// Replace it only when the source is newer.
  newer,
}

/// What happens to the source once an archive, an extraction or a compression has replaced it.
///
/// {@category Files}
enum Original { keep, trash, delete }

/// A value with a file form: a `Doc`, an `Html`, an `Xml`, a `Table`, an `Image`, a `Torrent`.
/// One `save` writes any of them, atomically, and works on any [Task] of one:
/// `await url.get().html.save('page.html')`.
///
/// {@category Files}
abstract interface class Saveable {
  /// Writes this value to [to], in the format its extension names, atomically: the old file
  /// survives a failure. A file already there is replaced (the value in hand is the newer
  /// version); say [conflict] for another policy.
  Task<Path> save(String to, {Conflict conflict = Conflict.overwrite});
}

/// Saving the value a task ends in.
///
/// {@category Files}
extension SaveableTask<S extends Saveable> on Future<S> {
  /// The value this ends in, saved as [Saveable.save] saves it.
  Task<Path> save(String to, {Conflict conflict = Conflict.overwrite}) =>
      TaskInternals.start(to, to, (work) async => (await this).save(to, conflict: conflict));
}
