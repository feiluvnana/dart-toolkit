part of '../../path.dart';

final _braceSlash = RegExp(r'\{[^}]*/');
final _classEscape = RegExp(r'[\\^\[\]]');

/// What a listing keeps: [PathExtensions.files], [PathExtensions.dirs] or
/// [PathExtensions.entries].
enum _Kind { files, dirs, entries }

/// How many entries are stat'd at once when a filter or an order needs their stats.
const _statBatch = 64;

/// Above this many paths, an order that stats them is sorted in a worker.
const _workerSort = 2000;

/// The listing of [root] the three listings share; see [PathExtensions.files].
Stream<Path> _listing(
  String root,
  _Kind kind,
  String? only,
  Iterable<String>? ignore,
  bool gitignore,
  bool hidden,
  int? minSize,
  Duration? newerThan,
  Order? order,
) {
  if (only != null && (only.isEmpty || p.isAbsolute(only) || only.startsWith('/'))) {
    throw ArgumentError.value(only, 'only', 'Invalid glob: give one relative to $root');
  }
  if (minSize != null && minSize < 0) throw ArgumentError.value(minSize, 'minSize', 'Invalid size: negative');
  if (newerThan != null && newerThan <= Duration.zero) {
    throw ArgumentError.value(newerThan, 'newerThan', 'Invalid age: not positive');
  }
  if (kind == _Kind.dirs && (order == Order.largest || order == Order.smallest)) {
    throw ArgumentError.value(order, 'order', 'Invalid order for folders: they have no size');
  }
  final listing = _List(p.normalize(root), kind, only ?? '*', ignore, gitignore, hidden, minSize, newerThan, order);
  return listing.run();
}

/// One listing: where it starts, how deep it goes, what it keeps.
final class _List {
  final String root;
  final _Kind kind;
  final Iterable<String>? ignore;
  final bool gitignore, hidden;
  final int? minSize;
  final Duration? newerThan;
  final Order? order;

  /// The glob's fixed folders, relative to [root] with `/`; `''` for none.
  late final String prefix;

  /// What is matched against each entry's path relative to `root/prefix`.
  late final RegExp matcher;

  /// How many levels below `root/prefix` the walk goes; `null` for any.
  late final int? depth;

  _List(
    this.root,
    this.kind,
    String only,
    this.ignore,
    this.gitignore,
    this.hidden,
    this.minSize,
    this.newerThan,
    this.order,
  ) {
    final segments = only.replaceAll(r'\', '/').split('/')..removeWhere((s) => s.isEmpty || s == '.');
    var fixed = 0;
    // The last segment is always part of the match, never of the prefix.
    while (fixed < segments.length - 1 && !segments[fixed].contains(_wildcard)) {
      fixed++;
    }
    prefix = segments.take(fixed).join('/');
    final rest = segments.skip(fixed).join('/');
    // A `/` inside braces — `{a,b/c}` — makes the depth one of several, so it is not bounded.
    final unbounded = rest.contains('**') || _braceSlash.hasMatch(rest);
    depth = unbounded ? null : segments.length - fixed;
    matcher = _globToRegex(rest);
  }

  bool get _needsStat => minSize != null || newerThan != null || (order != null && order != Order.natural);

  Stream<Path> run() async* {
    if (!await Directory(root).exists()) {
      if (await FileSystemEntity.type(root) == FileSystemEntityType.notFound) throw _notFound(root, 'Cannot list');
      throw FileSystemException('Cannot list: not a folder', root);
    }
    final start = prefix.isEmpty ? root : p.join(root, prefix);
    final matched = _matched(start);
    if (!_needsStat) {
      if (order == null) {
        yield* matched;
      } else {
        yield* Stream.fromIterable((await matched.toList())..sort(compareNatural));
      }
      return;
    }
    final kept = <(Path, FileStat)>[];
    final batch = <Path>[];
    Stream<(Path, FileStat)> flush() async* {
      final stats = await Future.wait([for (final f in batch) FileStat.stat(f)]);
      final now = Clock.current.now();
      for (final (i, f) in batch.indexed) {
        final s = stats[i];
        if (minSize != null && (s.type != FileSystemEntityType.file || s.size < minSize!)) continue;
        if (newerThan != null &&
            (s.type == FileSystemEntityType.notFound || now.difference(s.modified) >= newerThan!)) {
          continue;
        }
        yield (f, s);
      }
      batch.clear();
    }

    await for (final f in matched) {
      batch.add(f);
      if (batch.length < _statBatch) continue;
      await for (final e in flush()) {
        if (order == null) {
          yield e.$1;
        } else {
          kept.add(e);
        }
      }
    }
    await for (final e in flush()) {
      if (order == null) {
        yield e.$1;
      } else {
        kept.add(e);
      }
    }
    if (order == null) return;
    yield* Stream.fromIterable(
      kept.length > _workerSort ? await Isolate.run(() => _sorted(kept, order!)) : _sorted(kept, order!),
    );
  }

  /// What the glob keeps under [start], of the [kind] asked for.
  Stream<Path> _matched(String start) async* {
    if (!await Directory(start).exists()) return; // a folder the glob names that is not there: nothing
    _Walk? walk;
    if (ignore != null || gitignore || !hidden) {
      walk = await _Walk.from(this, start);
      if (walk == null) return; // a folder on the way to it is left out
    }
    final entities = walk != null
        ? walk.stream(start, prefix, depth, walk.rules)
        : depth == null
        ? Directory(start).list(recursive: true, followLinks: false).handleError((_) {}, test: _below(start))
        : _walk(Directory(start), depth!);
    await for (final entity in entities) {
      final isDir = entity is Directory;
      if (kind == _Kind.files && isDir || kind == _Kind.dirs && !isDir) continue;
      if (matcher.hasMatch(_relative(start, entity.path))) yield Path(entity.path);
    }
  }
}

/// Whether an error from a recursive listing of [start] is about a folder below it, which is
/// skipped, rather than [start] itself.
bool Function(Object?) _below(String start) =>
    (e) => e is FileSystemException && p.normalize(e.path ?? start) != p.normalize(start);

/// Everything under [dir], at most [depth] levels down, skipping what cannot be read below it.
Stream<FileSystemEntity> _walk(Directory dir, int depth, [bool top = true]) async* {
  if (depth < 1) return;
  final List<FileSystemEntity> entries;
  try {
    entries = await dir.list(followLinks: false).toList();
  } on FileSystemException {
    if (top) rethrow;
    return; // unreadable: skipped
  }
  for (final entity in entries) {
    yield entity;
    if (entity is Directory) yield* _walk(entity, depth - 1, false);
  }
}

/// [entries] in [order]: their stats are in hand, ties by path.
List<Path> _sorted(List<(Path, FileStat)> entries, Order order) {
  if (order == Order.natural) return [for (final (f, _) in entries) f]..sort(compareNatural);
  final byTime = order == Order.newest || order == Order.oldest;
  final sign = order == Order.newest || order == Order.largest ? -1 : 1;
  int key(FileStat s) => byTime ? s.modified.microsecondsSinceEpoch : s.size;
  final sorted = [...entries]
    ..sort((a, b) {
      final c = key(a.$2).compareTo(key(b.$2)) * sign;
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
  return [for (final (f, _) in sorted) f];
}

/// A walk that leaves out what [rules] ignore and never enters an ignored folder; with
/// [gitignore], each folder's `.gitignore` joins the rules for what is below it, and `.git` is
/// skipped. Unless [hidden], a name starting with `.` is left out and never entered.
final class _Walk {
  final String root;
  _Rules rules;
  final bool gitignore;
  final bool hidden;

  _Walk(this.root, this.rules, {required this.gitignore, required this.hidden});

  /// The walk [list] makes from [start]: rules rooted at its root, with the `.gitignore` files
  /// on the way down to [start] read; `null` when a folder on that way is itself left out.
  static Future<_Walk?> from(_List list, String start) async {
    final walk = _Walk(list.root, _Rules.of(list.ignore ?? const []), gitignore: list.gitignore, hidden: list.hidden);
    if (start == list.root) return walk;
    var rules = walk.rules;
    var rel = '';
    for (final segment in p.split(p.relative(start, from: list.root))) {
      rules = await walk.read(rel.isEmpty ? list.root : p.join(list.root, rel), rel, rules, null);
      rel = rel.isEmpty ? segment : '$rel/$segment';
      if (rules.ignores(rel, true) || (!walk.hidden && segment.startsWith('.'))) return null;
    }
    return walk..rules = rules;
  }

  /// [rules] with the `.gitignore` in [dir], at [rel], added; [entries], when listed, say
  /// whether there is one, so a folder without costs nothing.
  Future<_Rules> read(String dir, String rel, _Rules rules, List<FileSystemEntity>? entries) async {
    if (!gitignore) return rules;
    if (entries != null && !entries.any((e) => e is File && _isGitignore(e.path))) return rules;
    try {
      return rules.add((await File(p.join(dir, '.gitignore')).readAsString()).split('\n'), rel);
    } on FileSystemException {
      return rules; // none here, or unreadable: nothing to add
    }
  }

  static bool _isGitignore(String path) =>
      path.endsWith('/.gitignore') || (Platform.isWindows && path.endsWith(r'\.gitignore'));

  /// What [entries] of [dir], at [rel], leave in, each with its own `rel`.
  Iterable<(FileSystemEntity, String)> _kept(
    String dir,
    String rel,
    List<FileSystemEntity> entries,
    _Rules here,
  ) sync* {
    final cut = dir.endsWith('/') || dir.endsWith(p.separator) ? dir.length : dir.length + 1;
    for (final e in entries) {
      final name = e.path.substring(cut);
      final isDir = e is Directory;
      if (gitignore && isDir && name == '.git') continue;
      if (!hidden && name.startsWith('.')) continue;
      final at = rel.isEmpty ? name : '$rel/$name';
      if (!here.ignores(at, isDir)) yield (e, at);
    }
  }

  /// Everything kept under [dir], at most [depth] levels down; a folder below that cannot be
  /// read is skipped, [dir] itself is not.
  Stream<FileSystemEntity> stream(String dir, String rel, int? depth, _Rules rules, [bool top = true]) async* {
    if (depth != null && depth < 1) return;
    final List<FileSystemEntity> entries;
    try {
      entries = await Directory(dir).list(followLinks: false).toList();
    } on FileSystemException {
      if (top) rethrow;
      return; // unreadable: skipped
    }
    final here = await read(dir, rel, rules, entries);
    for (final (e, at) in _kept(dir, rel, entries, here)) {
      yield e;
      if (e is Directory) yield* stream(e.path, at, depth == null ? null : depth - 1, here, false);
    }
  }
}

/// `.gitignore` rules, each scoped to the folder its file is in; the last that matches decides.
final class _Rules {
  final List<_Rule> _all;

  const _Rules(this._all);

  static _Rules of(Iterable<String> patterns) => const _Rules([]).add(patterns, '');

  _Rules add(Iterable<String> lines, String base) {
    final more = [for (final line in lines) ?_Rule.parse(line, base)];
    return more.isEmpty ? this : _Rules([..._all, ...more]);
  }

  /// Whether [rel], a folder when [isDir], is ignored.
  bool ignores(String rel, bool isDir) {
    for (var i = _all.length - 1; i >= 0; i--) {
      final rule = _all[i];
      if (rule.matches(rel, isDir)) return !rule.negated;
    }
    return false;
  }
}

final _trailingBlank = RegExp(r'(?<!\\)[ \t]+$');

/// One `.gitignore` line: a glob, anchored to its folder when it holds a `/` (`/out`, `a/b`),
/// else matched against the last segment at any depth; `!` re-includes, a trailing `/` matches
/// folders only.
final class _Rule {
  /// The folder of the `.gitignore` this came from, relative to the walk's root; `''` for it.
  final String base;
  final RegExp pattern;
  final bool negated, dirOnly, anchored;

  _Rule(this.base, this.pattern, {required this.negated, required this.dirOnly, required this.anchored});

  static _Rule? parse(String line, String base) {
    var l = line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
    l = l.replaceFirst(_trailingBlank, '');
    if (l.isEmpty || l.startsWith('#')) return null;
    final negated = l.startsWith('!');
    if (negated || l.startsWith(r'\!') || l.startsWith(r'\#')) l = l.substring(1);
    final dirOnly = l.endsWith('/');
    if (dirOnly) l = l.substring(0, l.length - 1);
    final anchored = l.contains('/');
    if (l.startsWith('/')) l = l.substring(1);
    if (l.isEmpty) return null;
    return _Rule(base, _globToRegex(l), negated: negated, dirOnly: dirOnly, anchored: anchored);
  }

  bool matches(String rel, bool isDir) {
    if (dirOnly && !isDir) return false;
    var sub = rel;
    if (base.isNotEmpty) {
      if (rel.length <= base.length || !rel.startsWith(base) || rel.codeUnitAt(base.length) != 0x2f) return false;
      sub = rel.substring(base.length + 1);
    }
    if (!anchored) sub = sub.substring(sub.lastIndexOf('/') + 1);
    return pattern.hasMatch(sub);
  }
}

/// [child], under [start], relative to it with forward slashes; a substring, because
/// `p.relative` normalizes per call and dominated a large listing.
String _relative(String start, String child) {
  final rel = child.substring(start.endsWith(p.separator) || start.endsWith('/') ? start.length : start.length + 1);
  return Platform.isWindows ? rel.replaceAll(r'\', '/') : rel;
}

/// The characters that make a glob segment a pattern rather than a name.
final _wildcard = RegExp(r'[*?[{]');

/// Where the `]` closing the class opened at [open] is, or -1 when it is only a `[`.
int _classEnd(String pattern, int open) {
  var i = open + 1;
  if (i < pattern.length && (pattern[i] == '!' || pattern[i] == '^')) i++;
  // A `]` straight after the opening is one of the set, not its end.
  if (i < pattern.length && pattern[i] == ']') i++;
  final end = pattern.indexOf(']', i);
  return end < 0 || pattern.substring(open, end).contains('/') ? -1 : end;
}

/// Where the `}` closing the brace opened at [open] is, nested braces skipped, or -1 when
/// there is none or only one alternative inside: `b{1}.txt` names itself.
int _braceEnd(String pattern, int open) {
  var depth = 0, choice = false;
  for (var i = open; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == '{') depth++;
    if (c == ',' && depth == 1) choice = true;
    if (c == '}' && --depth == 0) return choice ? i : -1;
  }
  return -1;
}

/// [pattern] as a regular expression, case-insensitive where the platform's paths are.
RegExp _globToRegex(String pattern) =>
    RegExp(_globSource(pattern), caseSensitive: !Platform.isWindows && !Platform.isMacOS);

String _globSource(String pattern) {
  final g = pattern.replaceAll(r'\', '/');
  final buffer = StringBuffer('^');
  // The ends of the braces open around `i`, innermost last: a `,` inside one is `|`.
  final braces = <int>[];
  var i = 0;
  while (i < g.length) {
    final c = g[i];
    final classEnd = c == '[' ? _classEnd(g, i) : -1;
    final braceEnd = c == '{' ? _braceEnd(g, i) : -1;
    if (classEnd > 0) {
      var body = g.substring(i + 1, classEnd);
      final negated = body.startsWith('!') || body.startsWith('^');
      if (negated) body = body.substring(1);
      // Inside a class only `\`, `^` and `[` mean something to RegExp that they do not to a glob.
      body = body.replaceAllMapped(_classEscape, (m) => '\\${m[0]}');
      buffer.write(negated ? '[^/$body]' : '[$body]');
      i = classEnd + 1;
      continue;
    }
    if (g.startsWith('**/', i)) {
      buffer.write('(?:.+/)?');
      i += 3;
      continue;
    }
    if (g.startsWith('**', i)) {
      buffer.write('.*');
      i += 2;
      continue;
    }
    if (braceEnd > 0) {
      braces.add(braceEnd);
      buffer.write('(?:');
    } else if (braces.isNotEmpty && i == braces.last) {
      braces.removeLast();
      buffer.write(')');
    } else {
      buffer.write(switch (c) {
        ',' when braces.isNotEmpty => '|',
        '*' => '[^/]*',
        '?' => '[^/]',
        _ when r'.+()^$[]{}|'.contains(c) => '\\$c',
        _ => c,
      });
    }
    i++;
  }
  return (buffer..write(r'$')).toString();
}
