/// Command-line parsing: declare schema plus handlers, then run.
///
/// ```dart
/// final port = Opt('port', 'Port.', short: 'p', or: 8080);  // Opt<int>
/// final cli = Command('fetch', 'Fetch pages.',
///     params: [port],
///     handler: (context) async => print(context(port)));
/// await cli.run(argv);                                  // sets exitCode
/// ```
///
/// Public surface is exactly: [Param], [Flag], [Opt], [Multi],
/// [Arg], [Rest], [Command], [Context], [UsageException].
/// - [Flag]/[Opt]/[Multi]/[Arg]/[Rest] seal [Param]: schema
///   definitions read back with `context(param)`, typed by the definition.
/// - [Command] supports `run` (declare schema + handler, then run).
/// - [Context] supports `call` `usage`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'core.dart';

import 'src/sanitize.dart' as term;

/// A schema definition, read back with `context(param)` as a `T`. Sealed:
/// the only inhabitants are [Flag], [Opt], [Multi], [Arg] and [Rest],
/// so the type comes from the definition, not the call site.
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
  final Object? Function(List<String> parentRaws, String what, Object? child)? _mergeMany;

  bool get _isArg => _kind == _Kind.argument || _kind == _Kind.rest;
  bool get _isRest => _kind == _Kind.rest;
  bool get _isMulti => _kind == _Kind.multi;
  bool get _isRequired => _required;
}

/// The five shapes a [Param] takes. Switches on the sealed subtypes use this
/// where only the shape matters.
enum _Kind { flag, option, multi, argument, rest }

/// The reader + usage hint for one definition's `T`, resolved once in the
/// constructor by [_resolve].
final class _Reader<T> {
  const _Reader(this.read, this.hint);

  final T Function(String raw, String what) read;
  final String hint;
}

/// A yes-or-no schema definition: `false` unless given, or [or] by
/// default.
///
/// `or: true` also enables `--no-name` and renders `--[no-]name` in
/// usage.
final class Flag extends Param<bool> {
  Flag(String name, String help, {String? short, bool or = false})
    : _or = or,
      super._(name: name, short: short, help: help, kind: _Kind.flag, required: false, hint: '', absent: () => or) {
    _checkName(name);
    _checkShort(short);
    _checkHelpReserved(name);
  }

  final bool _or;
}

/// A single valued option definition, read back as `T` itself ([or]
/// when absent). `T` is inferred where [or] or [parse] gives it:
/// `Opt('port', …, or: 8080)` is an `Opt<int>`. A nullable `T`
/// (`Opt<String?>`) can be absent; a non-nullable `T` without
/// [or] or `required` is an [ArgumentError]. Yes/no is always a
/// [Flag]: `Opt<bool>` is an [ArgumentError]. [min] and [max] bound a
/// value that orders (`int`, `double`, `Duration`, `DateTime`):
/// `Opt<int?>('quality', …, min: 1, max: 100)` turns `--quality 150` into a
/// usage error, and usage shows `[1-100]`.
final class Opt<T> extends Param<T> {
  Opt(
    String name,
    String help, {
    String? short,
    T? or,
    bool required = false,
    String? env,
    T Function(String)? parse,
    List<T>? values,
    T? min,
    T? max,
  }) : this._withReader(
         name,
         help,
         _bounded<T>(name, _resolve<T>(name, parse, values), min, max, or),
         short: short,
         or: or,
         required: required,
         env: env,
         min: min,
         max: max,
       );

  Opt._withReader(
    String name,
    String help,
    _Reader<T> reader, {
    String? short,
    required T? or,
    required bool required,
    this._env,
    this._min,
    this._max,
  }) : _or = or,
       super._(
         name: name,
         short: short,
         help: help,
         kind: _Kind.option,
         required: required,
         hint: reader.hint,
         absent: () => or,
         readOne: reader.read,
       ) {
    _checkName(name);
    _checkShort(short);
    _checkHelpReserved(name);
    _checkDefault<T>(name, or, required);
  }

  final T? _or;
  final T? _min, _max;

  /// The environment variable read when the option is not given (a token,
  /// an endpoint): the command line wins, then [_env], then `or`.
  final String? _env;
}

/// A repeatable option definition, read back as `List<T>` ([or] when
/// absent). Occurrences before and after a subcommand merge. `T` is inferred
/// where [or] or [parse] gives it. With [values], one occurrence may also
/// list several, comma-separated (`--kind=photo,reel`). Yes/no is always a
/// [Flag]: `Multi<bool>` is an [ArgumentError].
final class Multi<T> extends Param<List<T>> {
  Multi(String name, String help, {String? short, List<T> or = const [], T Function(String)? parse, List<T>? values})
    : this._withElement(name, help, _resolve<T>(name, parse, values), short: short, or: or, commas: values != null);

  Multi._withElement(
    String name,
    String help,
    _Reader<T> element, {
    String? short,
    required List<T> or,
    required bool commas,
  }) : _or = or,
       super._(
         name: name,
         short: short,
         help: help,
         kind: _Kind.multi,
         required: false,
         hint: '${element.hint}...',
         absent: () => List<T>.unmodifiable(List<T>.of(or)),
         readOne: element.read,
         readMany: (raws, what) => List<T>.unmodifiable([
           for (final raw in raws)
             for (final one in commas ? raw.split(',') : [raw]) element.read(one, what),
         ]),
         mergeMany: (parentRaws, what, child) => List<T>.unmodifiable([
           for (final raw in parentRaws)
             for (final one in commas ? raw.split(',') : [raw]) element.read(one, what),
           ...((child as List?) ?? const []).cast<T>(),
         ]),
       ) {
    _checkName(name);
    _checkShort(short);
    _checkHelpReserved(name);
  }

  final List<T> _or;
}

/// A positional argument definition, in declaration order, read back as `T`
/// itself. A positional no [Arg] or [Rest] takes is an error. `T`
/// is inferred where [or] or [parse] gives it. Yes/no is always a
/// [Flag]: `Arg<bool>` is an [ArgumentError].
final class Arg<T> extends Param<T> {
  Arg(String name, String help, {T? or, bool required = false, T Function(String)? parse, List<T>? values})
    : this._withReader(name, help, _resolve<T>(name, parse, values), or: or, required: required);

  Arg._withReader(String name, String help, _Reader<T> reader, {required T? or, required bool required})
    : super._(
        name: name,
        short: null,
        help: help,
        kind: _Kind.argument,
        required: required,
        hint: reader.hint,
        absent: () => or,
        readOne: reader.read,
      ) {
    _checkName(name);
    _checkHelpReserved(name);
    _checkDefault<T>(name, or, required);
  }
}

/// The positionals after the [Arg]s, read back as `List<T>` (empty when
/// none are given; `required` wants at least one). Declared last, at most
/// once per command. `T` is inferred where [parse] gives it.
final class Rest<T> extends Param<List<T>> {
  Rest(String name, String help, {bool required = false, T Function(String)? parse, List<T>? values})
    : this._withElement(name, help, _resolve<T>(name, parse, values), required: required);

  Rest._withElement(String name, String help, _Reader<T> element, {required super.required})
    : super._(
        name: name,
        short: null,
        help: help,
        kind: _Kind.rest,
        hint: element.hint,
        absent: () => List<T>.unmodifiable(const []),
        readMany: (raws, what) => List<T>.unmodifiable([for (final raw in raws) element.read(raw, what)]),
      ) {
    _checkName(name);
    _checkHelpReserved(name);
  }
}

/// A command: schema plus the handler that runs it.
final class Command {
  Command(
    String name,
    String help, {
    List<Param<Object?>> params = const [],
    List<Command> commands = const [],
    FutureOr<void> Function(Context context)? handler,
    List<String> aliases = const [],
    this._dotenv,
    this._version,
  }) : _name = name,
       _help = help,
       _params = params,
       _commands = commands,
       // ignore: prefer_initializing_formals – the public argument stays `handler`.
       _handler = handler,
       _aliases = aliases {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Invalid name: empty');
    }
    if (_version != null && params.any((p) => p._name == 'version')) {
      throw ArgumentError.value('version', 'params', 'Invalid params: --version is reserved by version:');
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
        throw ArgumentError.value(paramName, 'params', 'Invalid params: declared twice');
      }
      if (paramShort != null) {
        final owner = shorts[paramShort];
        if (owner != null) {
          throw ArgumentError.value(paramShort, 'params', 'Invalid params: -$paramShort twice');
        }
        shorts[paramShort] = paramName;
      }
      if (p._isArg) argDefs.add(p);
    }
    if (argDefs.isNotEmpty && commands.isNotEmpty) {
      throw ArgumentError.value(name, 'params', 'Invalid params: arguments and commands are exclusive');
    }
    for (final (i, a) in argDefs.indexed) {
      if (a._isRest && i != argDefs.length - 1) {
        throw ArgumentError.value(a._name, 'params', 'Invalid arguments: <${a._name}...> must be the last one');
      }
    }
    var optional = false;
    for (final a in argDefs) {
      final required = a._isRequired;
      if (optional && required) {
        throw ArgumentError.value(a._name, 'params', 'Invalid arguments: required <${a._name}> after an optional one');
      }
      optional |= !required;
    }
    final seen = <String>{name, ...aliases};
    if (seen.length != aliases.length + 1) {
      throw ArgumentError.value(aliases, 'aliases', 'Invalid aliases: duplicate name');
    }
    final subSeen = <String>{};
    for (final c in commands) {
      for (final n in [c._name, ...c._aliases]) {
        if (!subSeen.add(n)) {
          throw ArgumentError.value(n, 'commands', 'Invalid commands: "$n" twice');
        }
      }
    }
    // A child cannot redeclare an ancestor's --name or -s with a different
    // meaning (sharing the identical Param object is fine: it is the same
    // meaning).
    _checkSubtree(commands, {for (final p in params) p}, {for (final p in params) p._name}, {
      for (final p in params) p._short,
    });
  }

  final String _name;
  final String _help;
  final List<Param<Object?>> _params;
  final List<Command> _commands;
  final FutureOr<void> Function(Context context)? _handler;
  final List<String> _aliases;

  /// A `KEY=VALUE` file loaded before parsing (see [run]).
  final String? _dotenv;

  /// What `--version` prints after the name (`fetch 1.2.3`), for this
  /// command and every command under it.
  final String? _version;

  static void _checkSubtree(
    List<Command> commands,
    Set<Param<Object?>> seenParams,
    Set<String?> longs,
    Set<String?> shorts,
  ) {
    for (final c in commands) {
      for (final p in c._params) {
        if (seenParams.contains(p)) continue;
        if (!p._isArg && longs.contains(p._name)) {
          throw ArgumentError.value(p._name, 'commands', 'Invalid commands: "${c._name}" redeclares --${p._name}');
        }
        final s = p._short;
        if (s != null && shorts.contains(s)) {
          throw ArgumentError.value(s, 'commands', 'Invalid commands: "${c._name}" redeclares -$s');
        }
      }
      _checkSubtree(c._commands, {...seenParams, ...c._params}, {...longs, for (final p in c._params) p._name}, {
        ...shorts,
        for (final p in c._params) p._short,
      });
    }
  }

  /// Run [argv]: parse, run the named handler, print usage/errors and set
  /// the process `exitCode` (64 usage, 1 failure; a success leaves it as
  /// the handler set it). Never calls `exit()`, so pending output and exit
  /// hooks still run. The code is also returned, for tests and embedding.
  ///
  /// With `dotenv:` (`Command(…, dotenv: '.env')`), that file's `KEY=VALUE`
  /// lines are read first (`#` comments, `export `, quotes allowed; a
  /// missing file is skipped) and an `Opt(env:)` sees them, never over the
  /// real environment.
  ///
  /// With `version:` (`Command('fetch', …, version: '1.2.3')`), `--version`
  /// prints `fetch 1.2.3` to stdout and exits 0, here and in every
  /// subcommand; usage lists it.
  Future<int> run(List<String> argv) async {
    final file = _dotenv;
    final code = await _run(argv, file == null ? const {} : _readDotenv(file));
    if (code != 0) io.exitCode = code;
    return code;
  }

  Future<int> _run(List<String> argv, Map<String, String> dotenv) async {
    final deepest = _Deepest(dotenv);
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
    if (parsed.version case final version?) {
      print(version);
      return 0;
    }
    final context = Context._(parsed.target, parsed.chain, parsed.params, {for (final c in parsed.chain) ...c._params});
    final h = parsed.target._handler;
    if (h == null) {
      // A group run bare (no subcommand named) is a usage error; a leaf
      // without a handler just shows its help.
      if (parsed.target._commands.isEmpty) {
        print(context.usage());
        return 0;
      }
      io.stderr.writeln(context.usage());
      return 64;
    }
    try {
      await Future.sync(() => h(context));
      return 0;
    } on UsageException catch (e) {
      io.stderr.writeln(_oneLine(e.message));
      io.stderr.writeln('Run "${parsed.fullName} --help" for usage.');
      return 64;
    } on Exception catch (e) {
      io.stderr.writeln(_lines(_failure(e)));
      return 1;
    }
  }
}

/// What a handler is handed: params read back with `context(param)`, typed
/// by the definition.
final class Context {
  Context._(this._target, this._chain, this._params, Set<Param<Object?>> declared)
    : _declared = Set.unmodifiable(declared);

  final Command _target;
  final List<Command> _chain;
  final Map<Param<Object?>, Object?> _params;

  /// Every definition the target or an ancestor declares, built once at
  /// parse: reading a value is a set lookup, O(1), not a scan of the command
  /// chain per read.
  final Set<Param<Object?>> _declared;

  /// The value of [param], typed by its declaration. A definition this command
  /// (or an ancestor, for options) does not declare is a [StateError].
  T call<T>(Param<T> param) {
    if (!_declared.contains(param)) {
      throw StateError('Cannot read ${_paramShown(param)}: it is not declared on "$_fullName"');
    }
    if (_params.containsKey(param)) return _params[param] as T;
    return param._absent() as T;
  }

  /// The help text for this command (what `--help` prints).
  String usage() => _commandUsage(_target, _chain);

  String get _fullName => _chain.map((c) => c._name).join(' ');
}

/// A usage error a handler throws for a mistake only it can see (exit 64).
/// Extends [ToolkitException], so one `on ToolkitException` covers every
/// failure the toolkit reports.
final class UsageException extends ToolkitException {
  const UsageException(super.message);

  @override
  String toString() => message;
}

void _checkName(String name) {
  if (name.isEmpty || name.startsWith('-') || RegExp(r'[\s=]').hasMatch(name)) {
    throw ArgumentError.value(name, 'name', 'Invalid name: expected a word without dashes in front');
  }
}

void _checkShort(String? short) {
  if (short == null) return;
  if (short.length != 1 || short == '-') {
    throw ArgumentError.value(short, 'short', 'Invalid short: expected one character');
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

void _checkDefault<T>(String name, T? or, bool required) {
  if (required && or != null) {
    throw ArgumentError.value(or, 'or', 'Invalid default: required and defaulted');
  }
  if (or == null && !required && null is! T) {
    throw ArgumentError.value(or, 'or', 'Invalid default: "$name" is not nullable, so it needs or: or required:');
  }
}

String _paramShown(Param<Object?> param) {
  final n = param._name;
  if (param._isRest) return '<$n>...';
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
_Reader<T> _resolve<T>(String name, T Function(String)? parse, List<T>? values) {
  if (_same<T, bool>() || _same<T, bool?>()) {
    throw ArgumentError.value(T, 'T', 'Invalid type for "$name": yes/no is always a Flag');
  }
  if (values != null) {
    if (parse != null) throw ArgumentError.value(name, 'values', 'Invalid "$name": give values or parse, not both');
    final byName = {for (final v in values) _shown(v).toLowerCase(): v};
    final shown = [for (final v in values) _shown(v)];
    return _Reader((raw, what) {
      final key = raw.trim().toLowerCase();
      if (byName.containsKey(key)) return byName[key] as T;
      final guess = _closest(key, byName.keys);
      throw ContentException(
        'Invalid value "$raw" for $what: expected ${shown.join(', ')}${guess == null ? '' : '. Did you mean "$guess"?'}',
      );
    }, '<${shown.join('|')}>');
  }
  if (parse != null) {
    return _Reader((raw, what) {
      try {
        return parse(raw);
      } on FormatException catch (e) {
        throw ContentException('Invalid value "$raw" for $what: ${e.message}');
      } on Exception catch (e) {
        throw ContentException('Invalid value "$raw" for $what: ${_failure(e)}');
      }
    }, '<value>');
  }
  if (_same<T, String>() || _same<T, String?>()) {
    return _Reader((raw, _) => raw as T, '<value>');
  } else if (_same<T, int>() || _same<T, int?>()) {
    return _Reader((raw, what) {
      final v = int.tryParse(raw);
      if (v == null) {
        throw ContentException('Invalid value "$raw" for $what: expected an integer');
      }
      return v as T;
    }, '<int>');
  } else if (_same<T, double>() || _same<T, double?>()) {
    return _Reader((raw, what) {
      final v = double.tryParse(raw);
      if (v == null) {
        throw ContentException('Invalid value "$raw" for $what: expected a number');
      }
      return v as T;
    }, '<number>');
  } else if (_same<T, num>() || _same<T, num?>()) {
    return _Reader((raw, what) {
      final v = num.tryParse(raw);
      if (v == null) {
        throw ContentException('Invalid value "$raw" for $what: expected a number');
      }
      return v as T;
    }, '<number>');
  } else if (_same<T, Duration>() || _same<T, Duration?>()) {
    return _Reader((raw, what) {
      final v = _parseDuration(raw);
      if (v == null) {
        throw ContentException('Invalid value "$raw" for $what: expected a duration such as 90s or 1h30m');
      }
      return v as T;
    }, '<duration>');
  } else if (_same<T, DateTime>() || _same<T, DateTime?>()) {
    return _Reader((raw, what) {
      final v = DateTime.tryParse(raw);
      if (v == null) {
        throw ContentException('Invalid value "$raw" for $what: expected a date such as 2026-10-08');
      }
      return v as T;
    }, '<date>');
  } else if (_same<T, Uri>() || _same<T, Uri?>()) {
    return _Reader((raw, what) {
      final u = Uri.tryParse(raw);
      if (u != null && u.hasScheme) return u as T;
      throw ContentException('Invalid value "$raw" for $what: expected a URL');
    }, '<url>');
  }
  throw ArgumentError.value(
    T,
    'T',
    'Unsupported type for "$name": use String, int, double, num, Duration, DateTime, Uri, or parse:',
  );
}

/// [reader] refusing values outside [min]..[max] (either may be null).
/// A bound on a type that does not order, or an [or] outside the bounds,
/// is an [ArgumentError].
_Reader<T> _bounded<T>(String name, _Reader<T> reader, T? min, T? max, T? or) {
  if (min == null && max == null) return reader;
  for (final b in [min, max]) {
    if (b != null && b is! Comparable) {
      throw ArgumentError.value(b, 'min/max', 'Invalid bound for "$name": $T does not order');
    }
  }
  if (min != null && max != null && (min as Comparable).compareTo(max) > 0) {
    throw ArgumentError.value(min, 'min', 'Invalid bounds for "$name": min is above max');
  }
  String? fault(Object v) {
    final low = min != null && (v as Comparable).compareTo(min) < 0;
    final high = max != null && (v as Comparable).compareTo(max) > 0;
    if (!low && !high) return null;
    if (min != null && max != null) return 'between ${_shown(min)} and ${_shown(max)}';
    return low ? 'at least ${_shown(min)}' : 'at most ${_shown(max)}';
  }

  if (or != null && fault(or) != null) {
    throw ArgumentError.value(or, 'or', 'Invalid default for "$name": must be ${fault(or)}');
  }
  return _Reader((raw, what) {
    final v = reader.read(raw, what);
    final f = v == null ? null : fault(v);
    if (f != null) throw ContentException('Invalid value "$raw" for $what: must be $f');
    return v;
  }, reader.hint);
}

/// The longest Duration in milliseconds (2^63 microseconds, rounded down):
/// past it the value wraps negative.
const _maxMs = 9.2e15;

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
    if (n != null && n * 1000 <= _maxMs) parsed = Duration(milliseconds: (n * 1000).round());
  } else {
    final m = RegExp(r'(\d+(?:\.\d+)?)(ms|h|m|s|d)', caseSensitive: false).allMatches(compact);
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
      if (covered == compact.length && ms <= _maxMs) parsed = Duration(milliseconds: ms.round());
    }
  }
  if (parsed == null) return null;
  return negative ? -parsed : parsed;
}

/// A failure's message: a toolkit error's message (not the SDK type's
/// `toString`, which adds `uri = …` or a source excerpt), a plain
/// `Exception('…')` without its prefix, anything else as it prints.
String _failure(Exception e) => switch (e) {
  ToolkitException(:final message) => message,
  _ => '$e'.startsWith('Exception: ') ? '$e'.substring(11) : '$e',
};

/// The first line of [s], controls shown as `�`: messages quote argv.
String _oneLine(String s) => term.plainLabel(s.split('\n').first.trim());

/// Every line of [s] (a tool's stderr is often after the first), each with
/// controls shown as `�`.
String _lines(String s) => s.trimRight().split('\n').map((l) => term.plainLabel(l.trimRight())).join('\n');

Command? _findSub(List<Command> commands, String token) {
  for (final c in commands) {
    if (c._name == token || c._aliases.contains(token)) return c;
  }
  return null;
}

/// The deepest command reached so far, for the "Run … --help" hint.
final class _Deepest {
  _Deepest(this.dotenv);

  /// What the running command's `dotenv:` file holds: per run, never
  /// shared between runs.
  final Map<String, String> dotenv;
  List<Command> chain = const [];

  void touch(List<Command> c) {
    chain = c;
  }

  String get name => chain.map((c) => c._name).join(' ');
}

final class _Parsed {
  _Parsed(this.target, this.chain, this.params, this.help, [this.version]);

  final Command target;
  final List<Command> chain;
  final Map<Param<Object?>, Object?> params;
  final bool help;

  /// `name version` when `--version` was given.
  final String? version;

  /// Help or a version: nothing runs, so nothing is required.
  bool get shown => help || version != null;

  String get fullName => chain.map((c) => c._name).join(' ');

  _Parsed withHelp(bool h, String? v) => _Parsed(target, chain, params, help || h, version ?? v);
}

/// Usage for `help a b …`: the resolved command, or a 64 with a suggestion
/// when a name does not resolve.
_Parsed _helpParsed(Command root, List<Command> chain, List<String> argv) {
  var cmd = root;
  var resolved = List<Command>.of(chain);
  for (final t in argv) {
    if (t.startsWith('-') || t == '--') break;
    final sub = _findSub(cmd._commands, t);
    if (sub == null) {
      final guess = _closest(t, [
        for (final c in cmd._commands) ...[c._name, ...c._aliases],
      ]);
      throw ContentException('Unknown command "$t"${guess == null ? '' : '. Did you mean "$guess"?'}');
    }
    cmd = sub;
    resolved = [...resolved, cmd];
  }
  return _Parsed(cmd, resolved, const {}, true);
}

/// Merge the parent level's params into a dispatched child: singles keep
/// the child's (or take the parent's), multis concatenate parent-first and
/// retype, and the parent's required checks run. Parent Arguments bind
/// nothing (dispatch happens on the first positional), so a required parent
/// Arg fails here.
_Parsed _mergeParent(
  Command root,
  Map<String, String> dotenv,
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
    final what = s == null ? 'option "--${key._name}"' : 'option "--${key._name}"/"-$s"';
    merged[key] = key._mergeMany!(e.value, what, merged[key]);
  }
  _fromEnv(root, merged, dotenv);
  // Required checks run at every level, parent included (skipped for --help).
  if (!child.shown) {
    for (final v in root._params) {
      if (v._isRequired && !merged.containsKey(v)) {
        if (v._isArg) {
          throw ContentException('Missing argument <${v._name}>');
        }
        throw ContentException('Missing option --${v._name}');
      }
    }
  }
  for (final v in root._params) {
    if (v._isMulti && !merged.containsKey(v)) {
      merged[v] = v._absent();
    }
  }
  return _Parsed(child.target, child.chain, merged, child.help, child.version);
}

List<Param<Object?>> _argDefsOf(Command cmd) {
  final out = <Param<Object?>>[];
  for (final v in cmd._params) {
    if (v._isArg) out.add(v);
  }
  return out;
}

_Parsed _parseCommand(Command root, List<String> argv, List<Command> ancestors, _Deepest deepest) =>
    _Parse(root, argv, ancestors, deepest).run();

/// One command's pass over [argv]: options, then positionals (a subcommand
/// takes the rest), then binding Args, the environment and defaults.
final class _Parse {
  _Parse(this.root, this.argv, List<Command> ancestors, this.deepest) : chain = [...ancestors, root] {
    deepest.touch(chain);
    // Visible defs, nearest first.
    for (var k = chain.length - 1; k >= 0; k--) {
      for (final v in chain[k]._params) {
        byLong.putIfAbsent(v._name, () => v);
        final s = v._short;
        if (s != null) byShort.putIfAbsent(s, () => v);
      }
    }
    // `--help` is always reserved (a `--help` definition is rejected at
    // construction); `-h` is help unless the user declared `short: 'h'`.
    helpShortTaken = byShort.containsKey('h');
  }

  final Command root;
  final List<String> argv;
  final _Deepest deepest;
  final List<Command> chain;
  final byLong = <String, Param<Object?>>{};
  final byShort = <String, Param<Object?>>{};
  late final bool helpShortTaken;
  final params = <Param<Object?>, Object?>{};
  final multiRaws = <Param<Object?>, List<String>>{};
  final extraArgs = <String>[];
  var help = false;
  String? version;
  var i = 0;

  _Parsed run() {
    while (i < argv.length) {
      final token = argv[i];
      if (token == '--') {
        extraArgs.addAll(argv.sublist(i + 1));
        break;
      }
      if (token.startsWith('--')) {
        _long(token);
      } else if (_isShortish(token)) {
        _short(token);
      } else {
        final done = _positional(token);
        if (done != null) return done;
      }
      i++;
    }
    return _finish();
  }

  /// A positional: subcommand dispatch, help, or an Arg value. A command
  /// named `help` dispatches like any subcommand. Non-null when it ends the
  /// parse (a subcommand or help took over).
  _Parsed? _positional(String token) {
    final helpSub = _findSub(root._commands, 'help');
    final isHelpName = token == 'help' && helpSub == null;
    final argDefs = _argDefsOf(root);
    if (extraArgs.isEmpty && root._commands.isNotEmpty) {
      if (isHelpName && argDefs.isEmpty) return _helpParsed(root, chain, argv.sublist(i + 1));
      final sub = _findSub(root._commands, token);
      if (sub != null) {
        // Carry parsed-so-far params into the child; the parent's
        // definitions bind and validate first.
        final child = _parseCommand(sub, argv.sublist(i + 1), chain, deepest);
        return _mergeParent(root, deepest.dotenv, params, multiRaws, child.withHelp(help, version));
      }
      // No subcommand named and no Arg defs: unknown command.
      if (argDefs.isEmpty) {
        final guess = _closest(token, [
          for (final c in root._commands) ...[c._name, ...c._aliases],
        ]);
        throw ContentException('Unknown command "$token"${guess == null ? '' : '. Did you mean "$guess"?'}');
      }
    } else if (isHelpName && extraArgs.isEmpty && root._commands.isEmpty && argDefs.isEmpty) {
      // Leaf `help` shows help, not the handler.
      return _Parsed(root, chain, params, true);
    }
    extraArgs.add(token);
    return null;
  }

  /// `--name`, `--name=value`, `--no-flag`.
  void _long(String token) {
    final raw = token.substring(2);
    final eq = raw.indexOf('=');
    final key = eq == -1 ? raw : raw.substring(0, eq);
    final inline = eq == -1 ? null : raw.substring(eq + 1);
    if (key == 'help') {
      help = true;
      return;
    }
    if (key == 'version' && inline == null) {
      for (final c in chain.reversed) {
        if (c._version case final v?) {
          version = '${c._name} $v';
          return;
        }
      }
    }
    final param = byLong[key];
    if (param == null || param._isArg) {
      if (param == null && key.startsWith('no-') && inline == null) {
        final base = byLong[key.substring(3)];
        if (base is Flag && base._or) {
          params[base] = false;
          return;
        }
      }
      final guess = _closest(key, [
        for (final e in byLong.entries)
          if (!e.value._isArg) e.key,
      ]);
      throw ContentException('Unknown option --$key${guess == null ? '' : '. Did you mean "--$guess"?'}');
    }
    if (param is Flag) {
      params[param] = inline == null ? true : _parseFlagValue(param._name, inline);
      return;
    }
    _take(param, _value(inline, '--$key'), 'option "--$key"');
  }

  /// `-v`, `-vn3`, `-n=3`, `-n 3`, a negative number, or a group holding
  /// a reserved `-h`.
  void _short(String token) {
    if (token == '-h' && !helpShortTaken) {
      help = true;
      return;
    }
    if (_isNumberToken(token, byShort)) {
      extraArgs.add(token);
      return;
    }
    for (var k = 1; k < token.length; k++) {
      final c = token[k];
      // A reserved -h inside a group is help (consume the whole token).
      if (c == 'h' && !helpShortTaken) {
        help = true;
        return;
      }
      final param = byShort[c];
      if (param == null) {
        final swapped = c == c.toLowerCase() ? c.toUpperCase() : c.toLowerCase();
        final guess = byShort.containsKey(swapped) ? swapped : null;
        throw ContentException(
          'Unknown option -$c in "-${token.substring(1)}"${guess == null ? '' : '. Did you mean "-$guess"?'}',
        );
      }
      if (param is Flag) {
        if (k + 1 < token.length && token[k + 1] == '=') {
          params[param] = _parseFlagValue(param._name, token.substring(k + 2));
          return;
        }
        params[param] = true;
        continue;
      }
      if (param._isArg) throw ContentException('Unknown option -$c in "-${token.substring(1)}"');
      // A valued short takes the remainder (after one optional '='); `-n=`
      // is the empty string (like `--n=`), not absent.
      final hadEquals = k + 1 < token.length && token[k + 1] == '=';
      final attached = token.substring(k + (hadEquals ? 2 : 1));
      _take(param, _value(attached.isNotEmpty || hadEquals ? attached : null, '-$c'), 'option "-$c"');
      return;
    }
  }

  /// A valued option's text: [inline] when given, else the next token
  /// (consumed). A help token there is help, and null comes back.
  String? _value(String? inline, String name) {
    if (inline != null) return inline;
    if (i + 1 >= argv.length) throw ContentException('Option $name needs a value');
    final next = argv[++i];
    if (_isHelpToken(next)) {
      help = true;
      return null;
    }
    return next;
  }

  void _take(Param<Object?> param, String? raw, String what) {
    if (raw == null) return;
    if (param._isMulti) {
      multiRaws.putIfAbsent(param, () => []).add(raw);
    } else {
      params[param] = param._readOne!(raw, what);
    }
  }

  bool _isHelpToken(String t) {
    if (t == '--help' || t.startsWith('--help=')) return true;
    if (helpShortTaken) return false;
    if (t == '-h' || t.startsWith('-h=')) return true;
    // A group of nothing but reserved h's in a value position is help too.
    return t.length > 1 && t.startsWith('-') && !t.startsWith('--') && t.substring(1).split('').every((c) => c == 'h');
  }

  /// Multi values, Args, the environment, required options and defaults.
  _Parsed _finish() {
    for (final e in multiRaws.entries) {
      params[e.key] = e.key._readMany!(e.value, 'option "--${e.key._name}"');
    }
    // Bind positionals to Arg defs (skipped for --help: help wins over
    // missing/unexpected).
    final args = _argDefsOf(root);
    final shown = help || version != null;
    if (!shown) {
      var at = 0;
      for (final param in args) {
        if (param._isRest) {
          if (at == extraArgs.length && param._isRequired) throw ContentException('Missing argument <${param._name}>');
          params[param] = param._readMany!(extraArgs.sublist(at), 'argument <${param._name}>');
          at = extraArgs.length;
        } else if (at < extraArgs.length) {
          params[param] = param._readOne!(extraArgs[at++], 'argument <${param._name}>');
        } else if (param._isRequired) {
          throw ContentException('Missing argument <${param._name}>');
        } else {
          // Optional and absent: a default reads back; a nullable type reads
          // null through the missing key.
          final absent = param._absent();
          if (absent != null) params[param] = absent;
        }
      }
      if (at < extraArgs.length) throw ContentException('Unexpected argument "${extraArgs[at]}"');
      extraArgs.clear();
    }
    _fromEnv(root, params, deepest.dotenv);
    // Required valued checks (before the handler runs; skipped for --help).
    if (!shown) {
      for (final v in root._params) {
        if (!v._isArg && v._isRequired && !params.containsKey(v)) {
          throw ContentException('Missing option --${v._name}');
        }
      }
    }
    // Fill absent multi defaults so context() never misses.
    for (final v in root._params) {
      if (v._isMulti && !params.containsKey(v)) params[v] = v._absent();
    }
    return _Parsed(root, chain, params, help, version);
  }
}

/// `KEY=VALUE` lines of [path]; empty when it does not exist.
Map<String, String> _readDotenv(String path) {
  final String text;
  try {
    text = io.File(path).readAsStringSync();
  } on io.PathNotFoundException {
    return const {};
  }
  final out = <String, String>{};
  for (var line in const LineSplitter().convert(text)) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('export ')) line = line.substring(7).trimLeft();
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    var value = line.substring(eq + 1).trim();
    if (value.isNotEmpty && (value[0] == '"' || value[0] == "'")) {
      // A quoted value ends at its matching quote; a comment may follow.
      // Double quotes decode \n, \t, \" and \\ in one left-to-right pass.
      final quote = value[0];
      final out = StringBuffer();
      var i = 1;
      for (; i < value.length && value[i] != quote; i++) {
        if (quote == '"' && value[i] == r'\' && i + 1 < value.length) {
          final c = value[++i];
          out.write(switch (c) {
            'n' => '\n',
            't' => '\t',
            _ => c,
          });
        } else {
          out.write(value[i]);
        }
      }
      value = i < value.length ? out.toString() : value; // unterminated: kept as written
    } else {
      final hash = value.indexOf(' #');
      if (hash >= 0) value = value.substring(0, hash).trimRight();
    }
    out[line.substring(0, eq).trim()] = value;
  }
  return out;
}

/// Options not given fall back to their environment variable.
void _fromEnv(Command root, Map<Param<Object?>, Object?> params, Map<String, String> dotenv) {
  for (final v in root._params) {
    if (v is Opt<Object?> && !params.containsKey(v)) {
      final name = v._env;
      final raw = name == null ? null : io.Platform.environment[name] ?? dotenv[name];
      if (raw == null || raw.isEmpty) continue;
      try {
        params[v] = v._readOne!(raw, 'environment variable \$$name');
      } on ContentException catch (e) {
        // Environment variables hold tokens: the message names the
        // variable, never its value.
        throw ContentException(e.message.replaceFirst('Invalid value "$raw" ', 'Invalid value '));
      }
    }
  }
}

bool _isShortish(String t) => t.startsWith('-') && !t.startsWith('--') && t.length > 1 && t != '-';

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
      throw ContentException('Invalid value "$raw" for option "--$name": a flag takes true or false');
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

  section('Arguments:', [for (final a in argDefs) (_argPlaceholder(a), _describeArg(a))]);
  section('Commands:', [
    for (final c in target._commands) ([c._name, ...c._aliases].join(', '), c._help),
  ]);
  final optionRows = _optionRows(target);
  optionRows.add(_helpRow(target, chain));
  if (chain.any((c) => c._version != null)) optionRows.add(('    --version', 'Show the version and exit.'));
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
    for (final v in c._params) {
      if (v._short == 'h') shortH = false;
    }
  }
  for (final v in target._params) {
    if (v._short == 'h') shortH = false;
  }
  return (shortH ? '-h, --help' : '    --help', 'Show this help and exit.');
}

String _argPlaceholder(Param<Object?> a) {
  if (a._isRest) return a._isRequired ? '<${a._name}>...' : '[${a._name}...]';
  if (a._isRequired) return '<${a._name}>';
  return '[${a._name}]';
}

/// How a value reads on the command line: an enum by its name, a
/// [Duration] in the syntax the parser accepts (`1m30s`, `250ms`).
String _shown(Object? v) => switch (v) {
  Enum() => v.name,
  Duration() => _shownDuration(v),
  _ => '$v',
};

String _shownDuration(Duration d) {
  if (d == Duration.zero) return '0s';
  if (d.isNegative) return '-${_shownDuration(-d)}';
  final b = StringBuffer();
  void unit(int n, String u) {
    if (n != 0) b.write('$n$u');
  }

  unit(d.inDays, 'd');
  unit(d.inHours % 24, 'h');
  unit(d.inMinutes % 60, 'm');
  unit(d.inSeconds % 60, 's');
  unit(d.inMilliseconds % 1000, 'ms');
  return b.isEmpty ? '0s' : '$b';
}

String _describeArg(Param<Object?> a) {
  var d = a._help;
  if (a._hint.contains('|')) d = '$d ${a._hint}'; // values:
  if (a._isRequired) d = d.isEmpty ? '[required]' : '$d [required]';
  return d.trimLeft();
}

/// A `values:` hint short enough stays in the flag column (`<a|b>`); a long
/// one becomes `<value>` with the choices after the help, so one option does
/// not push every description off the screen.
(String, String) _valuesHint(String hint) {
  if (!hint.contains('|') || hint.length <= 24) return (hint, '');
  final choices = hint.substring(1, hint.length - (hint.endsWith('...') ? 4 : 1)).split('|');
  return ('<value>${hint.endsWith('...') ? '...' : ''}', ' One of: ${choices.join(', ')}.');
}

List<(String, String)> _optionRows(Command cmd) {
  final rows = <(String, String)>[];
  for (final v in cmd._params) {
    switch (v) {
      case Flag():
        final left = '${v._short != null ? '-${v._short}, ' : '    '}--${v._or ? '[no-]' : ''}${v._name}';
        rows.add((left, v._help));
      case Opt<Object?>():
        final (hint, choices) = _valuesHint(v._hint);
        final left = '${v._short != null ? '-${v._short}, ' : '    '}--${v._name} $hint';
        var right = '${v._help}$choices';
        if (v._min != null || v._max != null) {
          final range = v._min == null
              ? '<= ${_shown(v._max)}'
              : v._max == null
              ? '>= ${_shown(v._min)}'
              : '${_shown(v._min)}-${_shown(v._max)}';
          right = '${right.isEmpty ? '' : '$right '}[$range]';
        }
        if (v._env != null) right = '${right.isEmpty ? '' : '$right '}[env: ${v._env}]';
        if (v._or != null) {
          right = '${right.isEmpty ? '' : '$right '}[default: ${_shown(v._or)}]';
        }
        if (v._required) {
          right = '${right.isEmpty ? '' : '$right '}[required]';
        }
        rows.add((left, right.trimLeft()));
      case Multi<Object?>():
        final (hint, choices) = _valuesHint(v._hint);
        final left = '${v._short != null ? '-${v._short}, ' : '    '}--${v._name} $hint';
        var right = '${v._help}$choices';
        if (v._or.isNotEmpty) {
          // Every value as the default reads as "all".
          final every = v._hint.contains('|') && v._or.length == v._hint.split('|').length;
          right = '${right.isEmpty ? '' : '$right '}[default: ${every ? 'all' : v._or.map(_shown).join(', ')}]';
        }
        rows.add((left, right.trimLeft()));
      case Arg<Object?>() || Rest<Object?>():
        continue;
    }
  }
  return rows;
}
