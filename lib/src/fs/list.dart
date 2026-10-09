part of '../path.dart';

final _braceSlash = RegExp(r'\{[^}]*/');
final _classEscape = RegExp(r'[\\^\[\]]');

/// What a listing keeps: [PathExtensions.files], [PathExtensions.dirs] or
/// [PathExtensions.entries].
enum _Kind { files, dirs, entries }

/// How many entries are stat'd at once when a filter or an order needs their stats.
const _statBatch = 64;

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
  if (only != null && (only.isEmpty || _isAbsolute(only) || only.startsWith('/') || only.split('/').contains('..'))) {
    throw ArgumentError.value(only, 'only', 'Invalid glob: give one relative to $root, inside it');
  }
  if (minSize != null && minSize < 0) throw ArgumentError.value(minSize, 'minSize', 'Invalid size: negative');
  if (newerThan != null && newerThan <= Duration.zero) {
    throw ArgumentError.value(newerThan, 'newerThan', 'Invalid age: not positive');
  }
  if (kind == _Kind.dirs && (order == Order.largest || order == Order.smallest)) {
    throw ArgumentError.value(order, 'order', 'Invalid order for folders: they have no size');
  }
  final listing = _List(_normalize(root), kind, only ?? '*', ignore, gitignore, hidden, minSize, newerThan, order);
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
    final segments = only.split('/')..removeWhere((s) => s.isEmpty || s == '.');
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
      if (await FileSystemEntity.type(root) == FileSystemEntityType.notFound) {
        throw FileBridge.notFound(root, 'Cannot list');
      }
      throw FileSystemException('Cannot list: not a folder', root);
    }
    final start = prefix.isEmpty ? root : _join(root, prefix);
    final matched = _matched(start);
    if (!_needsStat) {
      if (order == null) {
        yield* matched;
      } else {
        yield* Stream.fromIterable((await matched.toList())..sort(compareNatural));
      }
      return;
    }
    // Each path kept with the one number its order needs, never its whole stat.
    final kept = <(Path, int)>[];
    final byTime = order == Order.newest || order == Order.oldest;
    final batch = <Path>[];
    Stream<Path> flush() async* {
      final stats = await Future.wait([for (final f in batch) FileStat.stat(f)]);
      final now = Clock.current.now();
      for (final (i, f) in batch.indexed) {
        final s = stats[i];
        if (minSize != null && (s.type != FileSystemEntityType.file || s.size < minSize!)) continue;
        if (newerThan != null &&
            (s.type == FileSystemEntityType.notFound || now.difference(s.modified) >= newerThan!)) {
          continue;
        }
        if (order == null) {
          yield f;
        } else {
          kept.add((f, byTime ? s.modified.microsecondsSinceEpoch : s.size));
        }
      }
      batch.clear();
    }

    await for (final f in matched) {
      batch.add(f);
      if (batch.length < _statBatch) continue;
      yield* flush();
    }
    yield* flush();
    if (order == null) return;
    final sign = order == Order.newest || order == Order.largest ? -1 : 1;
    kept.sort(
      order == Order.natural
          ? (a, b) => compareNatural(a.$1, b.$1)
          : (a, b) {
              final c = a.$2.compareTo(b.$2) * sign;
              return c != 0 ? c : a.$1.compareTo(b.$1);
            },
    );
    for (final (f, _) in kept) {
      yield f;
    }
  }

  /// What the glob keeps under [start], of the [kind] asked for.
  Stream<Path> _matched(String start) async* {
    if (!await Directory(start).exists()) return; // a folder the glob names that is not there: nothing
    _Walk? walk;
    if (ignore != null || gitignore || !hidden) {
      walk = await _Walk.from(this, start);
      if (walk == null) return; // a folder on the way to it is left out
    }
    final entities = walk != null || depth != null
        ? (walk ?? _Walk(root, const _Rules([]), gitignore: false, hidden: true)).stream(
            start,
            prefix,
            depth,
            walk?.rules,
          )
        : Directory(start).list(recursive: true, followLinks: false).handleError((_) {}, test: _below(start));
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
    (e) => e is FileSystemException && _normalize(e.path ?? start) != _normalize(start);

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
    for (final segment in _split(_relativePath(start, from: list.root))) {
      rules = await walk.read(rel.isEmpty ? list.root : _join(list.root, rel), rel, rules);
      rel = rel.isEmpty ? segment : '$rel/$segment';
      if (rules.ignores(rel, true) || (!walk.hidden && segment.startsWith('.'))) return null;
    }
    return walk..rules = rules;
  }

  /// [rules] with the `.gitignore` in [dir], at [rel], added.
  Future<_Rules> read(String dir, String rel, _Rules rules) async {
    if (!gitignore) return rules;
    try {
      return rules.add((await File(_join(dir, '.gitignore')).readAsString()).split('\n'), rel);
    } on FileSystemException {
      return rules; // none here, or unreadable: nothing to add
    }
  }

  /// Everything kept under [dir], at most [depth] levels down ([rules] `null` for no rules):
  /// each folder streamed as it is read, its subfolders walked after it, so only their names
  /// wait. A folder below that cannot be read is skipped; [dir] itself is not.
  Stream<FileSystemEntity> stream(String dir, String rel, int? depth, _Rules? rules) async* {
    final pending = [(dir, rel, depth, rules)];
    var top = true;
    while (pending.isNotEmpty) {
      final (at, atRel, left, inherited) = pending.removeLast();
      if (left != null && left < 1) continue;
      final here = inherited == null ? null : await read(at, atRel, inherited);
      final cut = at.endsWith('/') || at.endsWith(_separator) ? at.length : at.length + 1;
      final below = <(String, String, int?, _Rules?)>[];
      try {
        await for (final e in Directory(at).list(followLinks: false)) {
          final isDir = e is Directory;
          if (here != null || !hidden) {
            final name = e.path.substring(cut);
            if (gitignore && isDir && name == '.git') continue;
            if (!hidden && name.startsWith('.')) continue;
            if (here != null && here.ignores(atRel.isEmpty ? name : '$atRel/$name', isDir)) continue;
          }
          yield e;
          if (isDir) {
            final name = e.path.substring(cut);
            below.add((e.path, atRel.isEmpty ? name : '$atRel/$name', left == null ? null : left - 1, here));
          }
        }
      } on FileSystemException {
        if (top) rethrow;
        // unreadable: skipped
      }
      top = false;
      pending.addAll(below.reversed);
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
/// `_relativePath` normalizes per call and dominated a large listing.
String _relative(String start, String child) {
  final rel = child.substring(start.endsWith(_separator) || start.endsWith('/') ? start.length : start.length + 1);
  return Platform.isWindows ? rel.replaceAll(r'\', '/') : rel;
}

/// The characters that make a glob segment a pattern rather than a name; `\` escapes one.
final _wildcard = RegExp(r'[*?[{\\]');

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
    if (c == r'\') {
      i++;
      continue;
    }
    if (c == '{') depth++;
    if (c == ',' && depth == 1) choice = true;
    if (c == '}' && --depth == 0) return choice ? i : -1;
  }
  return -1;
}

/// [pattern] as a regular expression, case-insensitive where the platform's paths are.
RegExp _globToRegex(String pattern) =>
    RegExp(_globSource(pattern), caseSensitive: !Platform.isWindows && !Platform.isMacOS);

String _globSource(String g) {
  final buffer = StringBuffer('^');
  // The ends of the braces open around `i`, innermost last: a `,` inside one is `|`.
  final braces = <int>[];
  var i = 0;
  while (i < g.length) {
    final c = g[i];
    // `\x` is `x` itself, as gitignore and the shell read it; a `\` at the end is one.
    if (c == r'\') {
      buffer.write(RegExp.escape(i + 1 < g.length ? g[i + 1] : c));
      i += 2;
      continue;
    }
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
