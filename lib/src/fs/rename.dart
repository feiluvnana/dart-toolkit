part of '../path.dart';

/// Renaming what a listing found: plan first, apply second.
///
/// {@category Files}
extension PathListingExtensions on Stream<Path> {
  /// The renames [rename] asks of these files, planned against the whole plan before anything
  /// moves: [rename] answers a new name, a path relative to the file's folder, or `null` to
  /// leave it.
  ///
  /// A target is in conflict when another file of the plan wants it, or when something on disk
  /// that stays has it (a case-only rename is one only where case tells files apart).
  /// [conflict] settles it: [Conflict.skip] leaves the file (the default), `fail` is a
  /// [PathExistsException], `overwrite` replaces what is on disk (never another file of the
  /// plan), `rename` picks free names, claimed so no two files get one. `newer` is an
  /// [ArgumentError]: a rename has nothing to compare.
  ///
  /// ```dart
  /// final plan = await dir.files(only: '*.JPG').plan((f) => f.withExt('jpg').name);
  /// print(plan);                     // what would happen
  /// await plan.apply();
  /// ```
  Future<Renames> plan(String? Function(Path file) rename, {Conflict conflict = Conflict.skip}) async {
    if (conflict == Conflict.newer) {
      throw ArgumentError.value(conflict, 'conflict', 'Invalid conflict for renames: nothing to compare with');
    }
    final wanted = <(Path, Path)>[];
    await for (final file in this) {
      final named = rename(file);
      if (named == null || named.isEmpty || named == file.name || named == file) continue;
      final target = named.contains('/') || named.contains(r'\')
          ? Path(_normalize(_isAbsolute(named) ? named : _join(file.parent, named)))
          : file.parent / named;
      if (file != target) wanted.add((file, target));
    }
    // What is on disk at each target, asked once: a file there that is not this very one.
    final taken = <String>{};
    for (final (file, target) in wanted) {
      if (await FileSystemEntity.type(target, followLinks: false) != FileSystemEntityType.notFound &&
          !await _sameFile(file, target)) {
        taken.add(target);
      }
    }
    // A target is free only if nothing is there or what is there moves away in this plan; a skip
    // keeps a file in place, which can take another's target, so plan until nothing changes.
    var moving = {for (final (from, _) in wanted) from as String};
    while (true) {
      final planned = _planAgainst(wanted, moving, taken, conflict);
      final now = {for (final (from, _) in planned) from as String};
      if (now.length == moving.length) {
        return Renames._(planned, {
          if (conflict == Conflict.overwrite)
            for (final (_, to) in planned)
              if (taken.contains(to)) to,
        });
      }
      moving = now;
    }
  }
}

/// [wanted] settled by [conflict], where only the files in [moving] leave their place and
/// [taken] holds the targets something else is at.
List<(Path, Path)> _planAgainst(List<(Path, Path)> wanted, Set<String> moving, Set<String> taken, Conflict conflict) {
  final planned = <(Path, Path)>[];
  final seen = <String, Path>{};
  final claimed = {for (final (_, to) in wanted) to as String};
  for (final (file, target) in wanted) {
    if (!moving.contains(file)) continue;
    final other = seen[target];
    final onDisk = taken.contains(target) && !moving.contains(target);
    var to = target;
    if (other != null || onDisk) {
      switch (conflict) {
        case Conflict.skip:
          continue;
        case Conflict.fail when other == null:
          throw PathExistsException(target, const OSError(), 'Cannot rename $file: $target exists');
        // Overwrite replaces what is on disk, never another file of the same plan.
        case Conflict.fail || Conflict.overwrite when other != null:
          throw FileSystemException('Cannot rename $file: $other becomes $target too', file);
        case Conflict.overwrite:
          break;
        case Conflict.rename:
          to = Path(FileBridge.free(target, claimed: claimed));
        case Conflict.fail || Conflict.newer:
          throw StateError('unreachable: $conflict');
      }
    }
    seen[to] = file;
    planned.add((file, to));
  }
  return planned;
}

/// The renames a [PathListingExtensions.plan] settled on, each `(from, to)`, in order: a value
/// to print or check, then [apply] and, after, [undo].
///
/// {@category Files}
final class Renames extends Iterable<(Path from, Path to)> {
  final List<(Path from, Path to)> _planned;

  /// The targets planned with `overwrite` over something on disk.
  final Set<String> _replace;

  /// The renames [apply] made, once it has run.
  List<(Path, Path)>? _applied;

  Renames._(this._planned, this._replace);

  @override
  Iterator<(Path from, Path to)> get iterator => _planned.iterator;

  @override
  int get length => _planned.length;

  /// Makes the renames, one item each: every file is moved to a temporary name beside it first,
  /// then to its target, so a cycle (a→b, b→a) and a case-only rename work. A file that has
  /// gone since the plan fails its item; one whose target something took since is left and is
  /// `Failed` with a [PathExistsException]. Applying twice is a [StateError].
  Batch<(Path, Path), Path> apply() {
    if (_applied != null) throw StateError('Cannot apply renames twice');
    final applied = _applied = [];
    return _run(_planned, _replace, applied);
  }

  /// Puts back what [apply] moved, newest first, the same two steps at a time. Before [apply]
  /// it is a [StateError]: nothing was moved.
  Batch<(Path, Path), Path> undo() {
    final applied = _applied ?? (throw StateError('Cannot undo renames that were not applied'));
    return _run([for (final (from, to) in applied.reversed) (to, from)], const {}, null);
  }

  @override
  String toString() => isEmpty ? 'No renames.' : map((r) => '${r.$1.name} -> ${r.$2.name}').join('\n');
}

/// [moves] made as a batch: all staged under temporary names, then each landed; one that
/// lands is added to [landed]. A target something is at is a [PathExistsException], unless it is
/// in [replace]: what the plan meant to overwrite. A cancel puts back what items that never ran
/// had staged.
Batch<(Path, Path), Path> _run(List<(Path, Path)> moves, Set<String> replace, List<(Path, Path)>? landed) {
  Future<Map<(Path, Path), Object>>? staging;
  final settled = <(Path, Path)>{};
  // Every source to a temporary name beside it, once, before any lands: what a cycle needs.
  Future<Map<(Path, Path), Object>> stage() => staging ??= () async {
    final staged = <(Path, Path), Object>{};
    for (final move in moves) {
      final from = move.$1;
      try {
        final temp = FileBridge.temp(from);
        final entity = await FileSystemEntity.isLink(from) ? Link(from) : File(from) as FileSystemEntity;
        await FileBridge.rename(entity, temp);
        staged[move] = entity is Link ? Link(temp) : File(temp);
      } on FileSystemException catch (e) {
        staged[move] = e;
      }
    }
    return staged;
  }();
  // What a cancel leaves staged, the items that will never run it, goes back where it was:
  // the running items put it back before they end, so the batch ends with it done.
  Future<void> unstage() async {
    for (final MapEntry(key: move, value: staged) in (await staging ?? const {}).entries) {
      if (staged is! FileSystemEntity || !settled.add(move)) continue;
      try {
        await FileBridge.rename(staged, move.$1);
      } on FileSystemException catch (_) {} // best-effort: it stays at its temporary name
    }
  }

  return moves.parallelize<Path>(
    (move) => TaskInternals.start(move, '${move.$1.name} -> ${move.$2.name}', (work) async {
      work.defer(() async {
        if (work.isStopped) await unstage();
      });
      final (from, to) = move;
      final staged = (await stage())[move]!;
      if (staged is! FileSystemEntity) throw staged;
      settled.add(move);
      try {
        if (!replace.contains(to) &&
            await FileSystemEntity.type(to, followLinks: false) != FileSystemEntityType.notFound) {
          throw PathExistsException(to, const OSError(), 'Cannot rename $from: $to exists');
        }
        await Directory(_dirname(to)).create(recursive: true);
        await FileBridge.rename(staged, to);
      } catch (_) {
        try {
          await FileBridge.rename(staged, from);
        } on FileSystemException catch (_) {} // best-effort: it stays at its temporary name
        rethrow;
      }
      landed?.add(move);
      return to;
    }),
  );
}
