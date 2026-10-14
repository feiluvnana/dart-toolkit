/// Command-line parsing: declare schema plus handlers, then run.
///
/// ```dart
/// final port = Option('port', 'Port.', short: 'p', defaultsTo: 8080);  // Option<int>
/// final cli = Command('fetch', 'Fetch pages.',
///     params: [port],
///     handler: (context) async => print(context(port)));
/// exitCode = await cli.run(argv);
/// ```
///
/// Public surface is exactly: [Param], [Flag], [Option], [MultiOption],
/// [Argument], [Command], [Context], [UsageException].
/// - [Flag]/[Option]/[MultiOption]/[Argument] seal [Param]: schema
///   definitions read back with `context(param)`, typed by the definition.
/// - [Command] supports `run` (declare schema + handler, then run).
/// - [Context] supports `call` `extraArgs` `usage`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:math';

/// A schema definition, read back with `context(param)` as a `T`. Sealed:
/// the only inhabitants are [Flag], [Option], [MultiOption] and [Argument],
/// so the type comes from the definition, not the call site.
///
/// Each definition carries one private record: its names, its help, the
/// reader resolved once in the constructor (so parsing a token is one
/// closure call: O(1), not a runtime `Type` chain), the value when absent,
/// and its kind. Behaviour that differs per shape switches on the sealed
/// subtype; nothing throws [UnsupportedError].
sealed class Param<T> {
  Param._({
    required this._name,
    required this._short,
    required this._help,
    required this._kind,
    required this._required,
    required this._hint,
    required this._absent,
    this._readOne,
    this._readMany,
    this._mergeMany,
  });

  final String _name;
  final String? _short;
  final String _help;
  final _Kind _kind;
  final bool _required;
  final String _hint;
  final Object? Function() _absent;
  final Object? Function(String raw, String what)? _readOne;
  final Object? Function(List<String> raws, String what)? _readMany;
  final Object? Function(List<String> parentRaws, String what, Object? child)?
      _mergeMany;

  bool get _isArg => _kind == _Kind.argument;
  bool get _isMulti => _kind == _Kind.multi;
  bool get _isRequired => _required;
}

/// The four shapes a [Param] takes. Switches on the sealed subtypes use this
/// where only the shape matters.
enum _Kind { flag, option, multi, argument }

/// The reader + usage hint for one definition's `T`, resolved once in the
/// constructor by [_resolve].
final class _Reader<T> {
  const _Reader(this.read, this.hint);

  final T Function(String raw, String what) read;
  final String hint;
}

/// A yes-or-no schema definition: `false` unless given, or [defaultsTo] by
/// default.
///
/// `defaultsTo: true` also enables `--no-name` and renders `--[no-]name` in
/// usage.
final class Flag extends Param<bool> {
  Flag(String name, String help, {String? short, bool defaultsTo = false})
      : _defaultsTo = defaultsTo,
        super._(
          name: name,
          short: short,
          help: help,
          kind: _Kind.flag,
          required: false,
          hint: '',
          absent: () => defaultsTo,
        ) {
    _checkName(name);
    _checkShort(short);
    _checkHelpReserved(name);
  }

  final bool _defaultsTo;
}

/// A single valued option definition, read back as `T` itself ([defaultsTo]
/// when absent). `T` is inferred where [defaultsTo] or [parse] gives it:
/// `Option('port', …, defaultsTo: 8080)` is an `Option<int>`. A nullable `T`
/// (`Option<String?>`) can be absent; a non-nullable `T` without
/// [defaultsTo] or `required` is an [ArgumentError]. Yes/no is always a
/// [Flag]: `Option<bool>` is an [ArgumentError].
final class Option<T> extends Param<T> {
  Option(String name, String help,
      {String? short,
      T? defaultsTo,
      bool required = false,
      T Function(String)? parse})
      : this._withReader(name, help, _resolve<T>(name, parse),
            short: short, defaultsTo: defaultsTo, required: required);

  Option._withReader(String name, String help, _Reader<T> reader,
      {String? short, required T? defaultsTo, required bool required})
      : _defaultsTo = defaultsTo,
        super._(
            name: name,
            short: short,
            help: help,
            kind: _Kind.option,
            required: required,
            hint: reader.hint,
            absent: () => defaultsTo,
            readOne: reader.read) {
    _checkName(name);
    _checkShort(short);
    _checkHelpReserved(name);
    _checkDefault<T>(name, defaultsTo, required);
  }

  final T? _defaultsTo;
}

/// A repeatable option definition, read back as `List<T>` ([defaultsTo] when
/// absent). Occurrences before and after a subcommand merge. `T` is inferred
/// where [defaultsTo] or [parse] gives it. Yes/no is always a [Flag]:
/// `MultiOption<bool>` is an [ArgumentError].
final class MultiOption<T> extends Param<List<T>> {
  MultiOption(String name, String help,
      {String? short,
      List<T> defaultsTo = const [],
      T Function(String)? parse})
      : this._withElement(name, help, _resolve<T>(name, parse),
            short: short, defaultsTo: defaultsTo);

  MultiOption._withElement(String name, String help, _Reader<T> element,
      {String? short, required List<T> defaultsTo})
      : _defaultsTo = defaultsTo,
        super._(
            name: name,
            short: short,
            help: help,
            kind: _Kind.multi,
            required: false,
            hint: '${element.hint}...',
            absent: () => List<T>.unmodifiable(List<T>.of(defaultsTo)),
            readOne: element.read,
            readMany: (raws, what) => List<T>.unmodifiable(
                [for (final raw in raws) element.read(raw, what)]),
            mergeMany: (parentRaws, what, child) => List<T>.unmodifiable([
                  for (final raw in parentRaws) element.read(raw, what),
                  ...((child as List?) ?? const []).cast<T>(),
                ])) {
    _checkName(name);
    _checkShort(short);
    _checkHelpReserved(name);
  }

  final List<T> _defaultsTo;
}

/// A positional argument definition, in declaration order, read back as `T`
/// itself. The positionals left after the [Argument]s are
/// `context.extraArgs()`, so there is exactly one way to read the tail. `T`
/// is inferred where [defaultsTo] or [parse] gives it. Yes/no is always a
/// [Flag]: `Argument<bool>` is an [ArgumentError].
final class Argument<T> extends Param<T> {
  Argument(String name, String help,
      {T? defaultsTo, bool required = false, T Function(String)? parse})
      : this._withReader(name, help, _resolve<T>(name, parse),
            defaultsTo: defaultsTo, required: required);

  Argument._withReader(String name, String help, _Reader<T> reader,
      {required T? defaultsTo, required bool required})
      : super._(
            name: name,
            short: null,
            help: help,
            kind: _Kind.argument,
            required: required,
            hint: reader.hint,
            absent: () => defaultsTo,
            readOne: reader.read) {
    _checkName(name);
    _checkHelpReserved(name);
    _checkDefault<T>(name, defaultsTo, required);
  }
}

/// A command: schema plus the handler that runs it.
final class Command {
  Command(String name, String help,
      {List<Param<Object?>> params = const [],
      List<Command> subcommands = const [],
      FutureOr<void> Function(Context context)? handler,
      List<String> aliases = const []})
      : _name = name,
        _help = help,
        _params = params,
        _subcommands = subcommands,
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
    final argDefs = <Param<Object?>>[];
    for (final p in params) {
      final paramName = p._name;
      final paramShort = p._short;
      if (!names.add(paramName)) {
        throw ArgumentError.value(
            paramName, 'params', 'Invalid params: declared twice');
      }
      if (paramShort != null) {
        final owner = shorts[paramShort];
        if (owner != null) {
          throw ArgumentError.value(
              paramShort, 'params', 'Invalid params: -$paramShort twice');
        }
        shorts[paramShort] = paramName;
      }
      if (p._isArg) argDefs.add(p);
    }
    if (argDefs.isNotEmpty && subcommands.isNotEmpty) {
      throw ArgumentError.value(
          name, 'params', 'Invalid params: arguments and subcommands are exclusive');
    }
    var optional = false;
    for (final a in argDefs) {
      final required = a._isRequired;
      if (optional && required) {
        throw ArgumentError.value(a._name, 'params',
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
    for (final c in subcommands) {
      for (final n in [c._name, ...c._aliases]) {
        if (!subSeen.add(n)) {
          throw ArgumentError.value(
              n, 'subcommands', 'Invalid subcommands: "$n" twice');
        }
      }
    }
    // A child cannot redeclare an ancestor's --name or -s with a different
    // meaning (sharing the identical Param object is fine: it is the same
    // meaning).
    _checkSubtree(subcommands, {for (final p in params) p},
        {for (final p in params) p._name}, {for (final p in params) p._short});
  }

  final String _name;
  final String _help;
  final List<Param<Object?>> _params;
  final List<Command> _subcommands;
  final FutureOr<void> Function(Context context)? _handler;
  final List<String> _aliases;

  static void _checkSubtree(List<Command> subcommands,
      Set<Param<Object?>> seenParams, Set<String?> longs, Set<String?> shorts) {
    for (final c in subcommands) {
      for (final p in c._params) {
        if (seenParams.contains(p)) continue;
        if (!p._isArg && longs.contains(p._name)) {
          throw ArgumentError.value(p._name, 'subcommands',
              'Invalid subcommands: "${c._name}" redeclares --${p._name}');
        }
        final s = p._short;
        if (s != null && shorts.contains(s)) {
          throw ArgumentError.value(s, 'subcommands',
              'Invalid subcommands: "${c._name}" redeclares -$s');
        }
      }
      _checkSubtree(c._subcommands, {...seenParams, ...c._params},
          {...longs, for (final p in c._params) p._name},
          {...shorts, for (final p in c._params) p._short});
    }
  }

  /// Run [argv]: parse, run the named handler, print usage/errors, answer
  /// the exit code. Never calls `exit()`; scripts do
  /// `exitCode = await run(argv)`.
  Future<int> run(List<String> argv) async {
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
    final context = Context._(parsed.target, parsed.chain, parsed.params,
        parsed.extraArgs, {for (final c in parsed.chain) ...c._params});
    try {
      final h = parsed.target._handler ?? ((c) => print(c.usage()));
      await Future.sync(() => h(context));
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

/// What a handler is handed: params read back with `context(param)`, typed
/// by the definition.
final class Context {
  Context._(this._target, this._chain, this._params, List<String> extraArgs,
      Set<Param<Object?>> declared)
      : _rest = List.unmodifiable(extraArgs),
        _declared = Set.unmodifiable(declared);

  final Command _target;
  final List<Command> _chain;
  final Map<Param<Object?>, Object?> _params;
  final List<String> _rest;

  /// Every definition the target or an ancestor declares, built once at
  /// parse: reading a value is a set lookup, O(1), not a scan of the command
  /// chain per read.
  final Set<Param<Object?>> _declared;

  /// The value of [param], typed by its declaration. A definition this command
  /// (or an ancestor, for options) does not declare is a [StateError].
  T call<T>(Param<T> param) {
    if (!_declared.contains(param)) {
      throw StateError(
          'Cannot read ${_paramShown(param)}: it is not declared on "$_fullName"');
    }
    if (_params.containsKey(param)) return _params[param] as T;
    return param._absent() as T;
  }

  /// Positional tail left after [Argument] binding (all of it when no
  /// [Argument] params).
  List<String> extraArgs() => List.of(_rest);

  String usage() => _commandUsage(_target, _chain);

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

void _checkHelpReserved(String name) {
  if (name == 'help') {
    throw ArgumentError.value(name, 'name', 'Invalid name: --help is reserved');
  }
}

void _checkDefault<T>(String name, T? defaultsTo, bool required) {
  if (required && defaultsTo != null) {
    throw ArgumentError.value(
        defaultsTo, 'defaultsTo', 'Invalid default: required and defaulted');
  }
  if (defaultsTo == null && !required && null is! T) {
    throw ArgumentError.value(defaultsTo, 'defaultsTo',
        'Invalid default: "$name" is not nullable, so it needs defaultsTo: or required:');
  }
}

String _paramShown(Param<Object?> param) {
  final n = param._name;
  if (param._isArg) return '<$n>';
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
  if (typed.length >= 3 && bestD <= max(1, typed.length ~/ 3)) return best;
  return null;
}

/// Resolve the reader + usage hint for `T` once, in the constructor, so
/// each parsed token costs one closure call: O(1), with no runtime `Type`
/// chain per token and no chain per usage row.
_Reader<T> _resolve<T>(String name, T Function(String)? parse) {
  if (_same<T, bool>() || _same<T, bool?>()) {
    throw ArgumentError.value(T, 'T',
        'Invalid type for "$name": yes/no is always a Flag');
  }
  if (parse != null) {
    return _Reader((raw, what) {
      try {
        return parse(raw);
      } on FormatException catch (e) {
        throw FormatException('Invalid value "$raw" for $what: ${e.message}');
      } on Exception catch (e) {
        throw FormatException('Invalid value "$raw" for $what: $e');
      }
    }, '<value>');
  }
  if (_same<T, String>() || _same<T, String?>()) {
    return _Reader((raw, _) => raw as T, '<value>');
  } else if (_same<T, int>() || _same<T, int?>()) {
    return _Reader((raw, what) {
      final v = int.tryParse(raw);
      if (v == null) {
        throw FormatException(
            'Invalid value "$raw" for $what: expected an integer');
      }
      return v as T;
    }, '<int>');
  } else if (_same<T, double>() || _same<T, double?>()) {
    return _Reader((raw, what) {
      final v = double.tryParse(raw);
      if (v == null) {
        throw FormatException(
            'Invalid value "$raw" for $what: expected a number');
      }
      return v as T;
    }, '<number>');
  } else if (_same<T, num>() || _same<T, num?>()) {
    return _Reader((raw, what) {
      final v = num.tryParse(raw);
      if (v == null) {
        throw FormatException(
            'Invalid value "$raw" for $what: expected a number');
      }
      return v as T;
    }, '<number>');
  } else if (_same<T, Duration>() || _same<T, Duration?>()) {
    return _Reader((raw, what) {
      final v = _parseDuration(raw);
      if (v == null) {
        throw FormatException(
            'Invalid value "$raw" for $what: expected a duration such as 90s or 1h30m');
      }
      return v as T;
    }, '<duration>');
  } else if (_same<T, DateTime>() || _same<T, DateTime?>()) {
    return _Reader((raw, what) {
      final v = DateTime.tryParse(raw);
      if (v == null) {
        throw FormatException(
            'Invalid value "$raw" for $what: expected a date such as 2026-10-08');
      }
      return v as T;
    }, '<date>');
  } else if (_same<T, Uri>() || _same<T, Uri?>()) {
    return _Reader((raw, what) {
      final u = Uri.tryParse(raw);
      if (u != null && u.hasScheme) return u as T;
      throw FormatException(
          'Invalid value "$raw" for $what: expected a URL');
    }, '<url>');
  }
  throw ArgumentError.value(T, 'T',
      'Unsupported type for "$name": use String, int, double, num, Duration, DateTime, Uri, or parse:');
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

String _oneLine(String s) => s.split('\n').first.trim();

Command? _findSub(List<Command> subcommands, String token) {
  for (final c in subcommands) {
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
  _Parsed(this.target, this.chain, this.params, this.extraArgs, this.help);

  final Command target;
  final List<Command> chain;
  final Map<Param<Object?>, Object?> params;
  final List<String> extraArgs;
  final bool help;

  String get fullName => chain.map((c) => c._name).join(' ');

  _Parsed withHelp(bool h) => _Parsed(target, chain, params, extraArgs, help || h);
}

/// Usage for `help a b …`: the resolved command, or a 64 with a suggestion
/// when a name does not resolve.
_Parsed _helpParsed(
    Command root, List<Command> chain, List<String> argv) {
  var cmd = root;
  var resolved = List<Command>.of(chain);
  for (final t in argv) {
    if (t.startsWith('-') || t == '--') break;
    final sub = _findSub(cmd._subcommands, t);
    if (sub == null) {
      final guess = _closest(
          t, [for (final c in cmd._subcommands) ...[c._name, ...c._aliases]]);
      throw FormatException(
        'Unknown command "$t"${guess == null ? '' : '. Did you mean "$guess"?'}.',
      );
    }
    cmd = sub;
    resolved = [...resolved, cmd];
  }
  return _Parsed(cmd, resolved, const {}, const [], true);
}

/// Merge the parent level's params into a dispatched child: singles keep
/// the child's (or take the parent's), multis concatenate parent-first and
/// retype, and the parent's required checks run. Parent Arguments bind
/// nothing (dispatch happens on the first positional), so a required parent
/// Argument fails here.
_Parsed _mergeParent(
  Command root,
  Map<Param<Object?>, Object?> singles,
  Map<Param<Object?>, List<String>> multiRaws,
  _Parsed child,
) {
  final merged = Map<Param<Object?>, Object?>.of(child.params);
  for (final e in singles.entries) {
    merged.putIfAbsent(e.key, () => e.value);
  }
  for (final e in multiRaws.entries) {
    final key = e.key;
    final s = key._short;
    final what = s == null
        ? 'option "--${key._name}"'
        : 'option "--${key._name}"/"-$s"';
    merged[key] = key._mergeMany!(e.value, what, merged[key]);
  }
  // Required checks run at every level, parent included (skipped for --help).
  if (!child.help) {
    for (final v in root._params) {
      if (v._isRequired && !merged.containsKey(v)) {
        if (v._isArg) {
          throw FormatException('Missing argument <${v._name}>.');
        }
        throw FormatException('Missing option --${v._name}.');
      }
    }
  }
  for (final v in root._params) {
    if (v._isMulti && !merged.containsKey(v)) {
      merged[v] = v._absent();
    }
  }
  return _Parsed(
      child.target, child.chain, merged, child.extraArgs, child.help);
}

List<Param<Object?>> _argDefsOf(Command cmd) {
  final out = <Param<Object?>>[];
  for (final v in cmd._params) {
    if (v._isArg) out.add(v);
  }
  return out;
}

_Parsed _parseCommand(Command root, List<String> argv, List<Command> ancestors,
    _Deepest deepest) {
  final chain = [...ancestors, root];
  deepest.touch(chain);
  // Visible defs, nearest first.
  final byLong = <String, Param<Object?>>{};
  final byShort = <String, Param<Object?>>{};
  for (var i = chain.length - 1; i >= 0; i--) {
    for (final v in chain[i]._params) {
      byLong.putIfAbsent(v._name, () => v);
      final s = v._short;
      if (s != null) byShort.putIfAbsent(s, () => v);
    }
  }
  // `--help` is always reserved (a `--help` definition is rejected at
  // construction); `-h` is help unless the user declared `short: 'h'`.
  final helpShortTaken = byShort.containsKey('h');
  final params = <Param<Object?>, Object?>{};
  final multiRaws = <Param<Object?>, List<String>>{};
  final extraArgs = <String>[];
  var help = false;
  var i = 0;

  void putSingle(Param<Object?> param, Object? value) {
    params[param] = value;
  }

  void putMulti(Param<Object?> param, String raw) {
    multiRaws.putIfAbsent(param, () => []).add(raw);
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
      extraArgs.addAll(argv.sublist(i + 1));
      i = argv.length;
      break;
    }
    final isLong = token.startsWith('--');
    if (!isLong && !_isShortish(token)) {
      // Positional: subcommand dispatch, help, or an Argument value.
      // A command named `help` dispatches like any subcommand (not help).
      final helpSub = _findSub(root._subcommands, 'help');
      final isHelpName = token == 'help' && helpSub == null;
      final argDefs = _argDefsOf(root);
      if (extraArgs.isEmpty && root._subcommands.isNotEmpty) {
        if (isHelpName && argDefs.isEmpty) {
          return _helpParsed(root, chain, argv.sublist(i + 1));
        }
        final sub = _findSub(root._subcommands, token);
        if (sub != null) {
          // Carry parsed-so-far params into the child; the parent's
          // definitions bind and validate first (C2/C3).
          final child = _parseCommand(sub, argv.sublist(i + 1), chain, deepest);
          return _mergeParent(root, params, multiRaws, child.withHelp(help));
        }
        // No subcommand named and no Argument defs: unknown command.
        if (argDefs.isEmpty) {
          final guess = _closest(token, [
            for (final c in root._subcommands) ...[c._name, ...c._aliases]
          ]);
          throw FormatException(
            'Unknown command "$token"${guess == null ? '' : '. Did you mean "$guess"?'}.',
          );
        }
      } else if (isHelpName &&
          extraArgs.isEmpty &&
          root._subcommands.isEmpty &&
          argDefs.isEmpty) {
        // Leaf `help` shows help, not the handler.
        return _Parsed(root, chain, params, const [], true);
      }
      extraArgs.add(token);
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
      final param = byLong[key];
      if (param == null) {
        if (key.startsWith('no-') && inline == null) {
          final base = byLong[key.substring(3)];
          if (base is Flag) {
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
      if (param is Flag) {
        putSingle(param, inline == null ? true : _parseFlagValue(param._name, inline));
        i++;
      } else if (param._isMulti) {
        if (inline != null) {
          putMulti(param, inline);
          i++;
        } else if (i + 1 < argv.length && !isHelpToken(argv[i + 1])) {
          putMulti(param, argv[i + 1]);
          i += 2;
        } else if (i + 1 < argv.length && isHelpToken(argv[i + 1])) {
          help = true;
          i += 2;
        } else {
          throw FormatException('Option --$key needs a value.');
        }
      } else if (!param._isArg) {
        final what = longWhat(key);
        if (inline != null) {
          putSingle(param, param._readOne!(inline, what));
          i++;
        } else if (i + 1 < argv.length && !isHelpToken(argv[i + 1])) {
          putSingle(param, param._readOne!(argv[i + 1], what));
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
      extraArgs.add(token);
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
      final param = byShort[c];
      if (param == null) {
        final swapped = c == c.toLowerCase() ? c.toUpperCase() : c.toLowerCase();
        final guess = byShort.containsKey(swapped) ? swapped : null;
        throw FormatException(
          'Unknown option -$c in "-${token.substring(1)}"${guess == null ? '' : '. Did you mean "-$guess"?'}',
        );
      }
      if (param is Flag) {
        if (k + 1 < token.length && token[k + 1] == '=') {
          putSingle(param, _parseFlagValue(param._name, token.substring(k + 2)));
          i++;
          break;
        }
        putSingle(param, true);
        continue;
      }
      // Valued short consumes the remainder (after one optional '=').
      // `-n=` means empty string (like `--n=`), not absent.
      final hadEquals = k + 1 < token.length && token[k + 1] == '=';
      var attached = token.substring(k + 1);
      if (hadEquals) attached = attached.substring(1);
      final what = 'option "-$c"';
      if (param._isMulti) {
        if (attached.isNotEmpty || hadEquals) {
          putMulti(param, attached);
        } else if (i + 1 < argv.length && !isHelpToken(argv[i + 1])) {
          putMulti(param, argv[i + 1]);
          i++;
        } else if (i + 1 < argv.length && isHelpToken(argv[i + 1])) {
          help = true;
          i++;
        } else {
          throw FormatException('Option -$c needs a value.');
        }
        break;
      }
      if (!param._isArg) {
        if (attached.isNotEmpty || hadEquals) {
          putSingle(param, param._readOne!(attached, what));
        } else if (i + 1 < argv.length && !isHelpToken(argv[i + 1])) {
          putSingle(param, param._readOne!(argv[i + 1], what));
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
    params[e.key] = e.key._readMany!(e.value, 'option "--${e.key._name}"');
  }
  // Bind positionals to Argument defs (skipped for --help: help wins over
  // missing/unexpected).
  final args = _argDefsOf(root);
  if (!help) {
    if (args.isNotEmpty) {
      var at = 0;
      for (final param in args) {
        if (at < extraArgs.length) {
          params[param] = param._readOne!(extraArgs[at++], 'argument <${param._name}>');
        } else if (param._isRequired) {
          throw FormatException('Missing argument <${param._name}>.');
        } else {
          // Optional and absent: a default reads back; a nullable type reads
          // null through the missing key.
          final absent = param._absent();
          if (absent != null) params[param] = absent;
        }
      }
      if (at < extraArgs.length) {
        throw FormatException('Unexpected argument "${extraArgs[at]}".');
      }
      extraArgs.clear();
    }
  }
  // Required valued checks (before the handler runs; skipped for --help).
  if (!help) {
    for (final v in root._params) {
      if (!v._isArg && v._isRequired && !params.containsKey(v)) {
        throw FormatException('Missing option --${v._name}.');
      }
    }
  }
  // Fill absent multi defaults so context() never misses.
  for (final v in root._params) {
    if (v._isMulti && !params.containsKey(v)) {
      params[v] = v._absent();
    }
  }
  return _Parsed(root, chain, params, List.of(extraArgs), help);
}

bool _isShortish(String t) =>
    t.startsWith('-') && !t.startsWith('--') && t.length > 1 && t != '-';

bool _isNumberToken(String t, Map<String, Param<Object?>> byShort) {
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
    if (target._subcommands.isNotEmpty) '[command]',
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
      for (final c in target._subcommands) ([c._name, ...c._aliases].join(', '), c._help)
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
  if (target._subcommands.isNotEmpty && chain.length == 1) {
    buf.writeln('\nRun "$full <command> --help" for more on a command.');
  }
  return '$buf'.trimRight();
}

(String, String) _helpRow(Command target, List<Command> chain) {
  var shortH = true;
  for (final c in chain) {
    for (final v in c._params) {
      if (v._short == 'h') shortH = false;
    }
  }
  for (final v in target._params) {
    if (v._short == 'h') shortH = false;
  }
  return (
    shortH ? '-h, --help' : '    --help',
    'Show this help and exit.'
  );
}

String _argPlaceholder(Param<Object?> a) {
  if (a._isRequired) return '<${a._name}>';
  return '[${a._name}]';
}

String _describeArg(Param<Object?> a) {
  var d = a._help;
  if (a._isRequired) d = d.isEmpty ? '[required]' : '$d [required]';
  return d.trimLeft();
}

List<(String, String)> _optionRows(Command cmd) {
  final rows = <(String, String)>[];
  for (final v in cmd._params) {
    switch (v) {
      case Flag():
        final left =
            '${v._short != null ? '-${v._short}, ' : '    '}--${v._defaultsTo ? '[no-]' : ''}${v._name}';
        rows.add((left, v._help));
      case Option<Object?>():
        final left =
            '${v._short != null ? '-${v._short}, ' : '    '}--${v._name} ${v._hint}';
        var right = v._help;
        if (v._defaultsTo != null) {
          right =
              '${right.isEmpty ? '' : '$right '}[default: ${v._defaultsTo}]';
        }
        if (v._required) {
          right = '${right.isEmpty ? '' : '$right '}[required]';
        }
        rows.add((left, right.trimLeft()));
      case MultiOption<Object?>():
        final left =
            '${v._short != null ? '-${v._short}, ' : '    '}--${v._name} ${v._hint}';
        var right = v._help;
        if (v._defaultsTo.isNotEmpty) {
          right =
              '${right.isEmpty ? '' : '$right '}[default: ${v._defaultsTo.join(', ')}]';
        }
        rows.add((left, right.trimLeft()));
      case Argument<Object?>():
        continue;
    }
  }
  return rows;
}
