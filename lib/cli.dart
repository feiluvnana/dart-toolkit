/// Command-line parsing: declare schema plus handlers, then parse.
///
/// ```dart
/// final top = Opt<int>('top', 'How many.', short: 'n', or: 10);
/// final cli = Command('fetch', 'Fetch pages.',
///     values: [top],
///     handler: (ctx) async => print(ctx(top)));
/// exitCode = await cli.parse(argv);
/// ```
///
/// Public surface is exactly: [Def], [Flag], [Opt], [Multi], [Arg],
/// [Command], [Ctx], [UsageException].
/// - [Flag]/[Opt]/[Multi]/[Arg] seal [Def]: schema definitions read back
///   with `ctx(def)`, typed by the definition.
/// - [Command] supports `parse` (declare schema + handler, then parse).
/// - [Ctx] supports `call` `rest` `usage`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:math';

/// A schema definition, read back with `ctx(def)` as a `T`. Sealed: the
/// only inhabitants are [Flag], [Opt], [Multi] and [Arg], so the type
/// comes from the definition, not the call site.
sealed class Def<T> {
  const Def._();

  String get _name;
  String get _help;
  String? get _short;
  bool get _isArg;
  bool get _isMulti;
  bool get _isRequired;

  /// The value type behind the definition (unwrapping Multi's List).
  Type get _valueType;

  /// The value when the definition is absent (its `or`, or null).
  Object? _absent();

  /// Read one raw value (valued definitions only).
  Object? _parseOne(String raw, String what);

  /// Read repeated raw values (multi definitions only).
  Object? _parseMany(List<String> raws, String what);

  /// Merge parent occurrences with the child's (multi definitions only).
  Object? _mergeMany(List<String> parentRaws, Object? childValue);
}

/// A yes-or-no schema definition: `false` unless given, or [or] by default.
///
/// `or: true` also enables `--no-name` and renders `--[no-]name` in usage.
final class Flag extends Def<bool> {
  Flag(String name, String help, {String? short, bool or = false})
      : _name = name,
        _help = help,
        _short = short,
        // ignore: prefer_initializing_formals – the public argument stays `or`.
        _or = or,
        super._() {
    _checkName(name);
    _checkShort(short);
    _checkHelp(name);
  }

  @override
  final String _name;
  @override
  final String _help;
  @override
  final String? _short;
  final bool _or;

  static void _checkHelp(String name) {
    if (name == 'help') {
      throw ArgumentError.value(
          name, 'name', 'Invalid name: --help is reserved');
    }
  }

  @override
  bool get _isArg => false;

  @override
  bool get _isMulti => false;

  @override
  bool get _isRequired => false;

  @override
  Type get _valueType => bool;

  @override
  Object? _absent() => _or;

  @override
  Object? _parseOne(String raw, String what) =>
      throw UnsupportedError('a Flag takes no value');

  @override
  Object? _parseMany(List<String> raws, String what) =>
      throw UnsupportedError('a Flag takes no value');

  @override
  Object? _mergeMany(List<String> parentRaws, Object? childValue) =>
      throw UnsupportedError('a Flag takes no value');
}

/// A single valued option definition, read back as `T` itself (`or` when
/// absent). A nullable `T` (`Opt<String?>`) can be absent; a non-nullable
/// `T` without `or` or `required` is an [ArgumentError]. Yes/no is always
/// a [Flag]: `Opt<bool>` is an [ArgumentError].
final class Opt<T> extends Def<T> {
  Opt(String name, String help,
      {String? short, T? or, bool required = false, T Function(String)? parse})
      : _name = name,
        _help = help,
        _short = short,
        _or = or,
        _required = required,
        _parse = parse,
        super._() {
    _checkName(name);
    _checkShort(short);
    Flag._checkHelp(name);
    _checkNoBool<T>(name);
    _checkSupported<T>(name, parse);
    _checkDefault<T>(name, or, required);
  }

  @override
  final String _name;
  @override
  final String _help;
  @override
  final String? _short;
  final T? _or;
  final bool _required;
  final T Function(String)? _parse;

  @override
  bool get _isArg => false;

  @override
  bool get _isMulti => false;

  @override
  bool get _isRequired => _required;

  @override
  Type get _valueType => T;

  @override
  Object? _absent() => _or;

  @override
  Object? _parseOne(String raw, String what) =>
      _readTyped<T>(_name, raw, what, _parse);

  @override
  Object? _parseMany(List<String> raws, String what) =>
      throw UnsupportedError('not a Multi');

  @override
  Object? _mergeMany(List<String> parentRaws, Object? childValue) =>
      throw UnsupportedError('not a Multi');
}

/// A repeatable option definition, read back as `List<T>` (`or` when
/// absent). Occurrences before and after a subcommand merge. Yes/no is
/// always a [Flag]: `Multi<bool>` is an [ArgumentError].
final class Multi<T> extends Def<List<T>> {
  Multi(String name, String help,
      {String? short, List<T> or = const [], T Function(String)? parse})
      : _name = name,
        _help = help,
        _short = short,
        // ignore: prefer_initializing_formals – the public argument stays `or`.
        _or = or,
        _parse = parse,
        super._() {
    _checkName(name);
    _checkShort(short);
    Flag._checkHelp(name);
    _checkNoBool<T>(name);
    _checkSupported<T>(name, parse);
  }

  @override
  final String _name;
  @override
  final String _help;
  @override
  final String? _short;
  final List<T> _or;
  final T Function(String)? _parse;

  @override
  bool get _isArg => false;

  @override
  bool get _isMulti => true;

  @override
  bool get _isRequired => false;

  @override
  Type get _valueType => T;

  @override
  Object? _absent() => List<T>.unmodifiable(List<T>.of(_or));

  @override
  Object? _parseOne(String raw, String what) =>
      throw UnsupportedError('a Multi takes repeated values');

  @override
  Object? _parseMany(List<String> raws, String what) =>
      List<T>.unmodifiable([for (final raw in raws) _readTyped<T>(_name, raw, what, _parse)]);

  @override
  Object? _mergeMany(List<String> parentRaws, Object? childValue) {
    final parent =
        parentRaws.map((raw) => _readTyped<T>(_name, raw, _what, _parse));
    final child = (childValue as List?) ?? const [];
    return List<T>.unmodifiable(List<T>.of([...parent, ...child.cast<T>()]));
  }

  String get _what {
    final s = _short;
    if (s != null) return 'option "--$_name"/"-$s"';
    return 'option "--$_name"';
  }
}

/// A positional argument definition, in declaration order, read back as `T`
/// itself. The positionals left after the `Arg`s are `ctx.rest()`, so there
/// is exactly one way to read the tail. Yes/no is always a [Flag]:
/// `Arg<bool>` is an [ArgumentError].
final class Arg<T> extends Def<T> {
  Arg(String name, String help, {T? or, bool required = false, T Function(String)? parse})
      : _name = name,
        _help = help,
        _or = or,
        _required = required,
        _parse = parse,
        super._() {
    _checkName(name);
    _checkNoBool<T>(name);
    _checkSupported<T>(name, parse);
    _checkDefault<T>(name, or, required);
  }

  @override
  final String _name;
  @override
  final String _help;
  @override
  String? get _short => null;
  final T? _or;
  final bool _required;
  final T Function(String)? _parse;

  @override
  bool get _isArg => true;

  @override
  bool get _isMulti => false;

  @override
  bool get _isRequired => _required;

  @override
  Type get _valueType => T;

  @override
  Object? _absent() => _or;

  @override
  Object? _parseOne(String raw, String what) =>
      _readTyped<T>(_name, raw, what, _parse);

  @override
  Object? _parseMany(List<String> raws, String what) =>
      throw UnsupportedError('not a Multi');

  @override
  Object? _mergeMany(List<String> parentRaws, Object? childValue) =>
      throw UnsupportedError('not a Multi');
}

/// A command: schema plus the handler that runs it.
final class Command {
  Command(String name, String help,
      {List<Def<Object?>> values = const [],
      List<Command> commands = const [],
      FutureOr<void> Function(Ctx ctx)? handler,
      List<String> aliases = const []})
      : _name = name,
        _help = help,
        _values = values,
        _commands = commands,
        // ignore: prefer_initializing_formals – the public argument stays `handler`.
        _handler = handler,
        _aliases = aliases {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Invalid name: empty');
    }
    _checkName(name);
    for (final alias in aliases) {
      _checkName(alias);
    }
    final names = <String>{};
    final shorts = <String, String>{};
    final argDefs = <Def<Object?>>[];
    for (final v in values) {
      final defName = v._name;
      final defShort = v._short;
      if (!names.add(defName)) {
        throw ArgumentError.value(
            defName, 'values', 'Invalid values: declared twice');
      }
      if (defShort != null) {
        final owner = shorts[defShort];
        if (owner != null) {
          throw ArgumentError.value(
              defShort, 'values', 'Invalid values: -$defShort twice');
        }
        shorts[defShort] = defName;
      }
      if (v._isArg) argDefs.add(v);
    }
    var optional = false;
    for (final a in argDefs) {
      final required = a._isRequired;
      if (optional && required) {
        throw ArgumentError.value(a._name, 'values',
            'Invalid arguments: required <${a._name}> after an optional one');
      }
      optional |= !required;
    }
    final seen = <String>{name, ...aliases};
    if (seen.length != aliases.length + 1) {
      throw ArgumentError.value(
          aliases, 'aliases', 'Invalid aliases: duplicate name');
    }
    final subSeen = <String>{};
    for (final c in commands) {
      for (final n in [c._name, ...c._aliases]) {
        if (!subSeen.add(n)) {
          throw ArgumentError.value(
              n, 'commands', 'Invalid commands: "$n" twice');
        }
      }
    }
    // A child cannot redeclare an ancestor's --name or -s with a different
    // meaning (sharing the identical Def object is fine: it is the same
    // meaning).
    _checkSubtree(commands, {for (final v in values) v},
        {for (final v in values) v._name}, {for (final v in values) v._short});
  }

  final String _name;
  final String _help;
  final List<Def<Object?>> _values;
  final List<Command> _commands;
  final FutureOr<void> Function(Ctx ctx)? _handler;
  final List<String> _aliases;

  static void _checkSubtree(List<Command> commands, Set<Def<Object?>> defs,
      Set<String?> longs, Set<String?> shorts) {
    for (final c in commands) {
      for (final v in c._values) {
        if (defs.contains(v)) continue;
        if (!v._isArg && longs.contains(v._name)) {
          throw ArgumentError.value(v._name, 'commands',
              'Invalid commands: "${c._name}" redeclares --${v._name}');
        }
        final s = v._short;
        if (s != null && shorts.contains(s)) {
          throw ArgumentError.value(s, 'commands',
              'Invalid commands: "${c._name}" redeclares -$s');
        }
      }
      _checkSubtree(c._commands, {...defs, ...c._values},
          {...longs, for (final v in c._values) v._name},
          {...shorts, for (final v in c._values) v._short});
    }
  }

  /// Parse [argv], run the named handler, print usage/errors, answer the
  /// exit code. Never calls `exit()`; scripts do `exitCode = await parse(argv)`.
  Future<int> parse(List<String> argv) async {
    final deepest = _Deepest();
    late final _Parsed parsed;
    try {
      parsed = _parseCommand(this, argv, const [], deepest);
    } on FormatException catch (e) {
      io.stderr.writeln(_oneLine(e.message));
      io.stderr.writeln('Run "${deepest.name} --help" for usage.');
      return 64;
    }
    if (parsed.help) {
      print(_commandUsage(parsed.target, parsed.chain));
      return 0;
    }
    final ctx = Ctx._(parsed.target, parsed.chain, parsed.values, parsed.rest);
    try {
      final h = parsed.target._handler ?? ((c) => print(c.usage()));
      await Future.sync(() => h(ctx));
      return 0;
    } on UsageException catch (e) {
      io.stderr.writeln(_oneLine(e.message));
      io.stderr.writeln('Run "${parsed.fullName} --help" for usage.');
      return 64;
    } on Exception catch (e) {
      io.stderr.writeln(_oneLine('$e'));
      return 1;
    }
  }
}

/// What a handler is handed: values read back with `ctx(def)`, typed by
/// the definition.
final class Ctx {
  Ctx._(this._target, this._chain, this._values, List<String> rest)
      : _rest = List.unmodifiable(rest);

  final Command _target;
  final List<Command> _chain;
  final Map<Def<Object?>, Object?> _values;
  final List<String> _rest;

  /// The value of [def], typed by its declaration. A definition this command
  /// (or an ancestor, for options) does not declare is a [StateError].
  T call<T>(Def<T> def) {
    if (!_declares(def)) {
      throw StateError(
          'Cannot read ${_defShown(def)}: it is not declared on "$_fullName"');
    }
    if (_values.containsKey(def)) return _values[def] as T;
    return def._absent() as T;
  }

  /// Positional tail left after [Arg] binding (all of it when no [Arg] defs).
  List<String> rest() => List.of(_rest);

  String usage() => _commandUsage(_target, _chain);

  bool _declares(Def<Object?> def) {
    for (final c in _chain) {
      if (c._values.contains(def)) return true;
    }
    return _target._values.contains(def);
  }

  String get _fullName => _chain.map((c) => c._name).join(' ');
}

/// A usage error a handler throws for a mistake only it can see (exit 64).
final class UsageException implements Exception {
  const UsageException(this.message);

  final String message;

  @override
  String toString() => message;
}

void _checkName(String name) {
  if (name.isEmpty || name.startsWith('-') || RegExp(r'[\s=]').hasMatch(name)) {
    throw ArgumentError.value(name, 'name',
        'Invalid name: expected a word without dashes in front');
  }
}

void _checkShort(String? short) {
  if (short == null) return;
  if (short.length != 1 || short == '-') {
    throw ArgumentError.value(
        short, 'short', 'Invalid short: expected one character');
  }
}

/// Type equality that also works for nullable types (`T == String?` is not
/// valid expression syntax, but a type argument may be nullable).
bool _same<A, B>() => A == B;

/// Runtime-type equality against a (possibly nullable) type.
bool _isA<S>(Type t) => t == S;

void _checkNoBool<T>(String name) {
  if (_same<T, bool>() || _same<T, bool?>()) {
    throw ArgumentError.value(T, 'T',
        'Invalid type for "$name": yes/no is always a Flag');
  }
}

void _checkSupported<T>(String name, T Function(String)? parse) {
  if (parse != null) return;
  if (_same<T, String>() ||
      _same<T, int>() ||
      _same<T, double>() ||
      _same<T, num>() ||
      _same<T, Duration>() ||
      _same<T, DateTime>() ||
      _same<T, Uri>() ||
      _same<T, String?>() ||
      _same<T, int?>() ||
      _same<T, double?>() ||
      _same<T, num?>() ||
      _same<T, Duration?>() ||
      _same<T, DateTime?>() ||
      _same<T, Uri?>()) {
    return;
  }
  throw ArgumentError.value(T, 'T',
      'Unsupported type for "$name": use String, int, double, num, Duration, DateTime, Uri, or parse:');
}

void _checkDefault<T>(String name, T? or, bool required) {
  if (required && or != null) {
    throw ArgumentError.value(
        or, 'or', 'Invalid default: required and defaulted');
  }
  if (or == null && !required && null is! T) {
    throw ArgumentError.value(or, 'or',
        'Invalid default: "$name" is not nullable, so it needs or: or required:');
  }
}

String _defShown(Def<Object?> def) {
  final n = def._name;
  if (def._isArg) return '<$n>';
  return '--$n';
}

int _levenshtein(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      cur[j] = min(min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
    }
    final tmp = prev;
    prev = cur;
    cur = tmp;
  }
  return prev[b.length];
}

String? _closest(String typed, Iterable<String> candidates) {
  String? best;
  var bestD = 1 << 30;
  for (final c in candidates) {
    final d = _levenshtein(typed, c);
    if (d < bestD) {
      best = c;
      bestD = d;
    }
  }
  if (best == null) return null;
  if (bestD <= max(2, typed.length ~/ 3)) return best;
  return null;
}

T _readTyped<T>(
    String name, String raw, String what, T Function(String)? custom) {
  if (custom != null) {
    try {
      return custom(raw);
    } on FormatException catch (e) {
      throw FormatException('Invalid value "$raw" for $what: ${e.message}');
    } catch (e) {
      throw FormatException('Invalid value "$raw" for $what: $e');
    }
  }
  Object? v;
  String expected;
  if (_same<T, String>() || _same<T, String?>()) {
    return raw as T;
  } else if (_same<T, int>() || _same<T, int?>()) {
    v = int.tryParse(raw);
    expected = 'an integer';
  } else if (_same<T, double>() || _same<T, double?>()) {
    v = double.tryParse(raw);
    expected = 'a number';
  } else if (_same<T, num>() || _same<T, num?>()) {
    v = num.tryParse(raw);
    expected = 'a number';
  } else if (_same<T, Duration>() || _same<T, Duration?>()) {
    v = _parseDuration(raw);
    expected = 'a duration such as 90s or 1h30m';
  } else if (_same<T, DateTime>() || _same<T, DateTime?>()) {
    v = DateTime.tryParse(raw);
    expected = 'a date such as 2026-10-08';
  } else if (_same<T, Uri>() || _same<T, Uri?>()) {
    final u = Uri.tryParse(raw);
    if (u != null && u.hasScheme) {
      return u as T;
    }
    throw FormatException('Invalid value "$raw" for $what: expected a URL');
  } else {
    throw ArgumentError.value(T, 'T', 'Unsupported type for "$name"');
  }
  if (v == null) {
    throw FormatException('Invalid value "$raw" for $what: expected $expected');
  }
  return v as T;
}

Duration? _parseDuration(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  var negative = false;
  if (s.startsWith('-') || s.startsWith('+')) {
    negative = s.startsWith('-');
    s = s.substring(1).trim();
    if (s.isEmpty) return null;
  }
  // Inner spaces allowed: "1h 30m".
  final compact = s.replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) return null;
  Duration? parsed;
  if (RegExp(r'^\d+(\.\d+)?$').hasMatch(compact)) {
    final n = num.tryParse(compact);
    if (n != null) parsed = Duration(milliseconds: (n * 1000).round());
  } else {
    final m =
        RegExp(r'(\d+(?:\.\d+)?)(ms|h|m|s|d)', caseSensitive: false)
            .allMatches(compact);
    if (m.isNotEmpty) {
      var covered = 0;
      var ms = 0.0;
      for (final x in m) {
        covered += (x.group(0) ?? '').length;
        final n = num.parse(x.group(1) ?? '0');
        switch ((x.group(2) ?? '').toLowerCase()) {
          case 'd':
            ms += n * 86400000;
          case 'h':
            ms += n * 3600000;
          case 'm':
            ms += n * 60000;
          case 's':
            ms += n * 1000;
          case 'ms':
            ms += n;
        }
      }
      if (covered == compact.length) parsed = Duration(milliseconds: ms.round());
    }
  }
  if (parsed == null) return null;
  return negative ? -parsed : parsed;
}

String _typeHint(Def<Object?> def) {
  final t = def._valueType;
  if (_isA<String>(t) || _isA<String?>(t)) return '<value>';
  if (_isA<int>(t) || _isA<int?>(t)) return '<int>';
  if (_isA<double>(t) ||
      _isA<num>(t) ||
      _isA<double?>(t) ||
      _isA<num?>(t)) {
    return '<number>';
  }
  if (_isA<Duration>(t) || _isA<Duration?>(t)) return '<duration>';
  if (_isA<DateTime>(t) || _isA<DateTime?>(t)) return '<date>';
  if (_isA<Uri>(t) || _isA<Uri?>(t)) return '<url>';
  return '<value>';
}

String _oneLine(String s) => s.split('\n').first.trim();

Command? _findSub(List<Command> commands, String token) {
  for (final c in commands) {
    if (c._name == token || c._aliases.contains(token)) return c;
  }
  return null;
}

/// The deepest command reached so far, for the "Run … --help" hint.
final class _Deepest {
  List<Command> chain = const [];

  void touch(List<Command> c) {
    chain = c;
  }

  String get name => chain.map((c) => c._name).join(' ');
}

final class _Parsed {
  _Parsed(this.target, this.chain, this.values, this.rest, this.help);

  final Command target;
  final List<Command> chain;
  final Map<Def<Object?>, Object?> values;
  final List<String> rest;
  final bool help;

  String get fullName => chain.map((c) => c._name).join(' ');

  _Parsed withHelp(bool h) => _Parsed(target, chain, values, rest, help || h);
}

/// Usage for `help a b …`: the resolved command, or a 64 with a suggestion
/// when a name does not resolve.
_Parsed _helpParsed(
    Command root, List<Command> chain, List<String> argv) {
  var cmd = root;
  var resolved = List<Command>.of(chain);
  for (final t in argv) {
    if (t.startsWith('-') || t == '--') break;
    final sub = _findSub(cmd._commands, t);
    if (sub == null) {
      final guess = _closest(
          t, [for (final c in cmd._commands) ...[c._name, ...c._aliases]]);
      throw FormatException(
        'Unknown command "$t"${guess == null ? '' : '. Did you mean "$guess"?'}.',
      );
    }
    cmd = sub;
    resolved = [...resolved, cmd];
  }
  return _Parsed(cmd, resolved, const {}, const [], true);
}

/// Merge the parent level's values into a dispatched child: singles keep
/// the child's (or take the parent's), multis concatenate parent-first and
/// retype, and the parent's required checks run. Parent Args bind nothing
/// (dispatch happens on the first positional), so a required parent Arg
/// fails here.
_Parsed _mergeParent(
  Command root,
  Map<Def<Object?>, Object?> singles,
  Map<Def<Object?>, List<String>> multiRaws,
  _Parsed child,
) {
  final merged = Map<Def<Object?>, Object?>.of(child.values);
  for (final e in singles.entries) {
    merged.putIfAbsent(e.key, () => e.value);
  }
  for (final e in multiRaws.entries) {
    merged[e.key] = e.key._mergeMany(e.value, merged[e.key]);
  }
  // Required checks run at every level, parent included (skipped for --help).
  if (!child.help) {
    for (final v in root._values) {
      if (v._isRequired && !merged.containsKey(v)) {
        if (v._isArg) {
          throw FormatException('Missing argument <${v._name}>.');
        }
        throw FormatException('Missing option --${v._name}.');
      }
    }
  }
  for (final v in root._values) {
    if (v._isMulti && !merged.containsKey(v)) {
      merged[v] = v._absent();
    }
  }
  return _Parsed(
      child.target, child.chain, merged, child.rest, child.help);
}

List<Def<Object?>> _argDefsOf(Command cmd) {
  final out = <Def<Object?>>[];
  for (final v in cmd._values) {
    if (v._isArg) out.add(v);
  }
  return out;
}

_Parsed _parseCommand(Command root, List<String> argv, List<Command> ancestors,
    _Deepest deepest) {
  final chain = [...ancestors, root];
  deepest.touch(chain);
  // Visible defs, nearest first.
  final byLong = <String, Def<Object?>>{};
  final byShort = <String, Def<Object?>>{};
  for (var i = chain.length - 1; i >= 0; i--) {
    for (final v in chain[i]._values) {
      byLong.putIfAbsent(v._name, () => v);
      final s = v._short;
      if (s != null) byShort.putIfAbsent(s, () => v);
    }
  }
  // `--help` is always reserved (a `--help` definition is rejected at
  // construction); `-h` is help unless the user declared `short: 'h'`.
  final helpShortTaken = byShort.containsKey('h');
  final values = <Def<Object?>, Object?>{};
  final multiRaws = <Def<Object?>, List<String>>{};
  final rest = <String>[];
  var help = false;
  var i = 0;

  void putSingle(Def<Object?> def, Object? value) {
    values[def] = value;
  }

  void putMulti(Def<Object?> def, String raw) {
    multiRaws.putIfAbsent(def, () => []).add(raw);
  }

  String longWhat(String key) => 'option "--$key"';

  bool isHelpToken(String t) {
    if (t == '--help' || t.startsWith('--help=')) return true;
    if (!helpShortTaken) {
      if (t == '-h' || t.startsWith('-h=')) return true;
      // Group containing reserved -h (e.g. -vh): help, handled in group loop.
      // Here (valued-value position) a bare -h group means help.
      if (t.startsWith('-') &&
          !t.startsWith('--') &&
          t.contains('h') &&
          t.length > 1) {
        // Only when h is help (reserved) — group loop would set help.
        // Treat as help, not a value.
        var onlyHelp = true;
        for (var k = 1; k < t.length; k++) {
          if (t[k] != 'h') {
            onlyHelp = false;
            break;
          }
        }
        if (onlyHelp) return true;
      }
    }
    return false;
  }

  Iterable<String> suggestPool() sync* {
    for (final entry in byLong.entries) {
      if (!entry.value._isArg) yield entry.key;
    }
  }

  while (i < argv.length) {
    final token = argv[i];
    if (token == '--') {
      rest.addAll(argv.sublist(i + 1));
      i = argv.length;
      break;
    }
    final isLong = token.startsWith('--');
    if (!isLong && !_isShortish(token)) {
      // Positional: subcommand dispatch, help, or an Arg value.
      // A command named `help` dispatches like any subcommand (not help).
      final helpSub = _findSub(root._commands, 'help');
      final isHelpName = token == 'help' && helpSub == null;
      // Parent Args bind first: while Args are still unbound, a positional
      // binds to the next Arg instead of dispatching (so `[go]` with Arg(go)
      // is arg=go, not a dispatch + Missing argument).
      final argDefs = _argDefsOf(root);
      final argsUnbound = argDefs.isNotEmpty && rest.length < argDefs.length;
      if (rest.isEmpty && root._commands.isNotEmpty && !argsUnbound) {
        if (isHelpName && argDefs.isEmpty) {
          return _helpParsed(root, chain, argv.sublist(i + 1));
        }
        final sub = _findSub(root._commands, token);
        if (sub != null) {
          // Carry parsed-so-far values into the child; the parent's
          // definitions bind and validate first (C2/C3).
          final child = _parseCommand(sub, argv.sublist(i + 1), chain, deepest);
          return _mergeParent(root, values, multiRaws, child.withHelp(help));
        }
        // No subcommand named and no Arg defs: unknown command.
        if (argDefs.isEmpty) {
          final guess = _closest(token, [
            for (final c in root._commands) ...[c._name, ...c._aliases]
          ]);
          throw FormatException(
            'Unknown command "$token"${guess == null ? '' : '. Did you mean "$guess"?'}.',
          );
        }
      } else if (isHelpName &&
          rest.isEmpty &&
          root._commands.isEmpty &&
          argDefs.isEmpty) {
        // Leaf `help` shows help, not the handler.
        return _Parsed(root, chain, values, const [], true);
      }
      rest.add(token);
      i++;
      continue;
    }
    if (isLong) {
      final raw = token.substring(2);
      final eq = raw.indexOf('=');
      final key = eq == -1 ? raw : raw.substring(0, eq);
      final inline = eq == -1 ? null : raw.substring(eq + 1);
      if (key == 'help') {
        help = true;
        i++;
        continue;
      }
      final def = byLong[key];
      if (def == null) {
        if (key.startsWith('no-') && inline == null) {
          final base = byLong[key.substring(3)];
          if (base is Flag && base._or) {
            putSingle(base, false);
            i++;
            continue;
          }
        }
        final guess = _closest(key, suggestPool());
        throw FormatException(
          'Unknown option --$key${guess == null ? '' : '. Did you mean "--$guess"?'}',
        );
      }
      if (def is Flag) {
        putSingle(def, inline == null ? true : _parseFlagValue(def._name, inline));
        i++;
      } else if (def._isMulti) {
        if (inline != null) {
          putMulti(def, inline);
          i++;
        } else if (i + 1 < argv.length && !isHelpToken(argv[i + 1])) {
          putMulti(def, argv[i + 1]);
          i += 2;
        } else if (i + 1 < argv.length && isHelpToken(argv[i + 1])) {
          help = true;
          i += 2;
        } else {
          throw FormatException('Option --$key needs a value.');
        }
      } else if (!def._isArg) {
        final what = longWhat(key);
        if (inline != null) {
          putSingle(def, def._parseOne(inline, what));
          i++;
        } else if (i + 1 < argv.length && !isHelpToken(argv[i + 1])) {
          putSingle(def, def._parseOne(argv[i + 1], what));
          i += 2;
        } else if (i + 1 < argv.length && isHelpToken(argv[i + 1])) {
          help = true;
          i += 2;
        } else {
          throw FormatException('Option --$key needs a value.');
        }
      } else {
        final guess = _closest(key, suggestPool());
        throw FormatException(
          'Unknown option --$key${guess == null ? '' : '. Did you mean "--$guess"?'}',
        );
      }
      continue;
    }
    // Single-dash group / attached / number.
    if (token == '-h' && !helpShortTaken) {
      help = true;
      i++;
      continue;
    }
    if (_isNumberToken(token, byShort)) {
      rest.add(token);
      i++;
      continue;
    }
    for (var k = 1; k < token.length; k++) {
      final c = token[k];
      // A reserved -h inside a group is help (consume the whole token).
      if (c == 'h' && !helpShortTaken) {
        help = true;
        break;
      }
      final def = byShort[c];
      if (def == null) {
        final guess = _closest(
          c,
          byShort.keys,
        );
        throw FormatException(
          'Unknown option -$c in "-${token.substring(1)}"${guess == null ? '' : '. Did you mean "-$guess"?'}',
        );
      }
      if (def is Flag) {
        if (k + 1 < token.length && token[k + 1] == '=') {
          putSingle(def, _parseFlagValue(def._name, token.substring(k + 2)));
          i++;
          break;
        }
        putSingle(def, true);
        continue;
      }
      // Valued short consumes the remainder (after one optional '=').
      // `-n=` means empty string (like `--n=`), not absent.
      final hadEquals = k + 1 < token.length && token[k + 1] == '=';
      var attached = token.substring(k + 1);
      if (hadEquals) attached = attached.substring(1);
      final what = 'option "-$c"';
      if (def._isMulti) {
        if (attached.isNotEmpty || hadEquals) {
          putMulti(def, attached);
        } else if (i + 1 < argv.length && !isHelpToken(argv[i + 1])) {
          putMulti(def, argv[i + 1]);
          i++;
        } else if (i + 1 < argv.length && isHelpToken(argv[i + 1])) {
          help = true;
          i++;
        } else {
          throw FormatException('Option -$c needs a value.');
        }
        break;
      }
      if (!def._isArg) {
        if (attached.isNotEmpty || hadEquals) {
          putSingle(def, def._parseOne(attached, what));
        } else if (i + 1 < argv.length && !isHelpToken(argv[i + 1])) {
          putSingle(def, def._parseOne(argv[i + 1], what));
          i++;
        } else if (i + 1 < argv.length && isHelpToken(argv[i + 1])) {
          help = true;
          i++;
        } else {
          throw FormatException('Option -$c needs a value.');
        }
        break;
      }
      throw FormatException('Unknown option -$c in "-${token.substring(1)}".');
    }
    i++;
  }
  for (final e in multiRaws.entries) {
    values[e.key] = e.key._parseMany(e.value, 'option "--${e.key._name}"');
  }
  // Bind positionals to Arg defs (skipped for --help: help wins over
  // missing/unexpected).
  final args = _argDefsOf(root);
  if (!help) {
    if (args.isNotEmpty) {
      var at = 0;
      for (final def in args) {
        if (at < rest.length) {
          values[def] = def._parseOne(rest[at++], 'argument <${def._name}>');
        } else if (def._isRequired) {
          throw FormatException('Missing argument <${def._name}>.');
        } else {
          // Optional and absent: a default reads back; a nullable type reads
          // null through the missing key.
          final absent = def._absent();
          if (absent != null) values[def] = absent;
        }
      }
      if (at < rest.length) {
        throw FormatException('Unexpected argument "${rest[at]}".');
      }
      rest.clear();
    }
  }
  // Required valued checks (before the handler runs; skipped for --help).
  if (!help) {
    for (final v in root._values) {
      if (!v._isArg && v._isRequired && !values.containsKey(v)) {
        throw FormatException('Missing option --${v._name}.');
      }
    }
  }
  // Fill absent multi defaults so ctx() never misses.
  for (final v in root._values) {
    if (v._isMulti && !values.containsKey(v)) {
      values[v] = v._absent();
    }
  }
  return _Parsed(root, chain, values, List.of(rest), help);
}

bool _isShortish(String t) =>
    t.startsWith('-') && !t.startsWith('--') && t.length > 1 && t != '-';

bool _isNumberToken(String t, Map<String, Def<Object?>> byShort) {
  if (!t.startsWith('-') || t.startsWith('--') || t.length < 2) return false;
  if (num.tryParse(t) == null) return false;
  return !byShort.containsKey(t[1]);
}

bool _parseFlagValue(String name, String raw) {
  switch (raw.toLowerCase()) {
    case 'true':
    case '1':
    case 'yes':
      return true;
    case 'false':
    case '0':
    case 'no':
      return false;
    default:
      throw FormatException(
          'Invalid value "$raw" for option "--$name": a flag takes true or false');
  }
}

String _commandUsage(Command target, List<Command> chain) {
  final full = chain.map((c) => c._name).join(' ');
  final argDefs = _argDefsOf(target);
  final shape = <String>[
    for (final a in argDefs) _argPlaceholder(a),
    '[options]',
    if (target._commands.isNotEmpty) '[command]',
  ];
  final buf = StringBuffer()..writeln('Usage: $full ${shape.join(' ')}'.trimRight());
  if (target._help.isNotEmpty) buf.writeln('\n${target._help}');
  void section(String title, List<(String, String)> rows) {
    if (rows.isEmpty) return;
    buf.writeln('\n$title');
    var width = 18;
    for (final (l, _) in rows) {
      if (l.length > width) width = l.length;
    }
    for (final (l, r) in rows) {
      buf.writeln(r.isEmpty ? '  $l' : '  ${l.padRight(width)}  $r');
    }
  }

  section(
    'Arguments:',
    [for (final a in argDefs) (_argPlaceholder(a), _describeArg(a))],
  );
  section(
    'Commands:',
    [
      for (final c in target._commands) ([c._name, ...c._aliases].join(', '), c._help)
    ],
  );
  final optionRows = _optionRows(target);
  optionRows.add(_helpRow(target, chain));
  section('Options:', optionRows);
  final grows = <(String, String)>[];
  for (final a in chain.sublist(0, max(chain.length - 1, 0)).reversed) {
    grows.addAll(_optionRows(a));
  }
  section('Global options:', grows);
  if (target._commands.isNotEmpty && chain.length == 1) {
    buf.writeln('\nRun "$full <command> --help" for more on a command.');
  }
  return '$buf'.trimRight();
}

(String, String) _helpRow(Command target, List<Command> chain) {
  var shortH = true;
  for (final c in chain) {
    for (final v in c._values) {
      if (v._short == 'h') shortH = false;
    }
  }
  for (final v in target._values) {
    if (v._short == 'h') shortH = false;
  }
  return (
    shortH ? '-h, --help' : '    --help',
    'Show this help and exit.'
  );
}

String _argPlaceholder(Def<Object?> a) {
  if (a._isRequired) return '<${a._name}>';
  return '[${a._name}]';
}

String _describeArg(Def<Object?> a) {
  var d = a._help;
  if (a._isRequired) d = d.isEmpty ? '[required]' : '$d [required]';
  return d.trimLeft();
}

List<(String, String)> _optionRows(Command cmd) {
  final rows = <(String, String)>[];
  for (final v in cmd._values) {
    if (v._isArg) continue;
    if (v is Flag) {
      final left =
          '${v._short != null ? '-${v._short}, ' : '    '}--${v._or ? '[no-]' : ''}${v._name}';
      rows.add((left, v._help));
    } else if (v is Opt<Object?>) {
      final hint = _typeHint(v);
      final left =
          '${v._short != null ? '-${v._short}, ' : '    '}--${v._name} $hint';
      var right = v._help;
      if (v._or != null) {
        right = '${right.isEmpty ? '' : '$right '}[default: ${v._or}]';
      }
      if (v._required) {
        right = '${right.isEmpty ? '' : '$right '}[required]';
      }
      rows.add((left, right.trimLeft()));
    } else if (v is Multi<Object?>) {
      final hint = '${_typeHint(v)}...';
      final left =
          '${v._short != null ? '-${v._short}, ' : '    '}--${v._name} $hint';
      var right = v._help;
      if (v._or.isNotEmpty) {
        right =
            '${right.isEmpty ? '' : '$right '}[default: ${v._or.join(', ')}]';
      }
      rows.add((left, right.trimLeft()));
    }
  }
  return rows;
}
