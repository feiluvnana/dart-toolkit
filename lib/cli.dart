/// Command-line parsing: declare schema plus handlers, then parse.
///
/// ```dart
/// final top = Opt<int>('top', 'How many.', short: 'n', or: 10, parse: int.parse);
/// final cli = Command('fetch', 'Fetch pages.',
///     values: [top],
///     handler: (ctx) async => print(ctx(top)));
/// exitCode = await cli.parse(argv);
/// ```
///
/// Public surface is exactly: [Flag], [Opt], [Multi], [Arg],
/// [Command], [Ctx], [UsageException].
/// - [Flag]/[Opt]/[Multi]/[Arg] are schema definitions read back with `ctx(def)`.
/// - [Command] supports `parse` (declare schema + handler, then parse).
/// - [Ctx] supports `call` `rest` `usage`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:math';

/// A yes-or-no schema definition: `false` unless given, or [or] by default.
///
/// `or: true` also enables `--no-name` and renders `--[no-]name` in usage.
final class Flag {
  Flag(this.name, this.help, {this.short, this.or = false}) {
    _checkName(name);
    _checkShort(short);
  }

  final String name;
  final String help;
  final String? short;
  final bool or;
}

/// A single valued option definition, read back as `T?` (`or` when absent).
final class Opt<T extends Object> {
  Opt(this.name, this.help, {this.short, this.or, this.required = false, this.parse}) {
    _checkName(name);
    _checkShort(short);
    if (required && or != null) {
      throw ArgumentError.value(or, 'or', 'Invalid default: required and defaulted');
    }
    _checkSupported<T>(name, parse);
  }

  final String name;
  final String help;
  final String? short;
  final T? or;
  final bool required;
  final T Function(String raw)? parse;
}

/// A repeatable option definition, read back as `List<T>` (`or` when absent).
final class Multi<T extends Object> {
  Multi(this.name, this.help, {this.short, this.or = const [], this.required = false, this.parse}) {
    _checkName(name);
    _checkShort(short);
    _checkSupported<T>(name, parse);
  }

  final String name;
  final String help;
  final String? short;
  final List<T> or;
  final bool required;
  final T Function(String raw)? parse;
}

/// A positional argument definition, in declaration order.
final class Arg<T extends Object> {
  Arg(this.name, this.help, {this.or, this.required = false, this.many = false, this.parse}) {
    _checkName(name);
    if (required && or != null) {
      throw ArgumentError.value(or, 'or', 'Invalid default: required and defaulted');
    }
    if (many && or != null) {
      throw ArgumentError.value(or, 'or', 'Invalid default: many takes the rest');
    }
    _checkSupported<T>(name, parse);
  }

  final String name;
  final String help;
  final T? or;
  final bool required;
  final bool many;
  final T Function(String raw)? parse;
}

/// A command: schema plus the handler that runs it.
final class Command {
  Command(this.name, this.help, {this.values = const [], this.commands = const [], this.handler, this.aliases = const []}) {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Invalid name: empty');
    }
    final names = <String>{};
    final shorts = <String, String>{};
    final argDefs = <Arg<Object>>[];
    for (final v in values) {
      final defName = _defName(v);
      final defShort = _defShort(v);
      if (!_isDef(v)) {
        throw ArgumentError.value(v, 'values', 'Invalid value: not a Flag, Opt, Multi or Arg');
      }
      if (!names.add(defName)) {
        throw ArgumentError.value(defName, 'values', 'Invalid values: declared twice');
      }
      if (defShort != null) {
        final owner = shorts[defShort];
        if (owner != null) {
          throw ArgumentError.value(defShort, 'values', 'Invalid values: -$defShort twice');
        }
        shorts[defShort] = defName;
      }
      if (v is Arg<Object>) argDefs.add(v);
    }
    var optional = false;
    for (var i = 0; i < argDefs.length; i++) {
      final a = argDefs[i];
      if (a.many && i != argDefs.length - 1) {
        throw ArgumentError.value(a.name, 'values', 'Invalid arguments: <${a.name}> takes the rest, so it comes last');
      }
      if (optional && a.required) {
        throw ArgumentError.value(a.name, 'values', 'Invalid arguments: required <${a.name}> after an optional one');
      }
      optional |= !a.required;
    }
    final seen = <String>{name, ...aliases};
    if (seen.length != aliases.length + 1) {
      throw ArgumentError.value(aliases, 'aliases', 'Invalid aliases: duplicate name');
    }
    final subSeen = <String>{};
    for (final c in commands) {
      for (final n in [c.name, ...c.aliases]) {
        if (!subSeen.add(n)) {
          throw ArgumentError.value(n, 'commands', 'Invalid commands: "$n" twice');
        }
      }
    }
  }

  final String name;
  final String help;
  final List<Object> values;
  final List<Command> commands;
  final Handler? handler;
  final List<String> aliases;

  /// Parse [argv], run the named handler, print usage/errors, answer the
  /// exit code. Never calls `exit()`; scripts do `exitCode = await parse(argv)`.
  Future<int> parse(List<String> argv) async {
    // `help <cmd>` without a `help` subcommand prints that command's usage.
    if (argv.isNotEmpty && argv[0] == 'help' && _findSub(commands, 'help') == null) {
      final target = _resolveHelpTarget(this, argv.sublist(1));
      print(_commandUsage(target.cmd, target.chain));
      return 0;
    }
    late final _Parsed parsed;
    try {
      parsed = _parseCommand(this, argv, const []);
    } on FormatException catch (e) {
      io.stderr.writeln(e.message);
      io.stderr.writeln('Run "${_helpFor(argv)} --help" for usage.');
      return 64;
    }
    if (parsed.help) {
      print(_commandUsage(parsed.target, parsed.chain));
      return 0;
    }
    final ctx = Ctx._(parsed.target, parsed.chain, parsed.values, parsed.rest);
    try {
      final h = parsed.target.handler ?? ((c) => print(c.usage()));
      await Future.sync(() => h(ctx));
      return 0;
    } on UsageException catch (e) {
      io.stderr.writeln(e.message);
      io.stderr.writeln('Run "${parsed.fullName} --help" for usage.');
      return 64;
    } catch (e) {
      io.stderr.writeln(_oneLine('$e'));
      return 1;
    }
  }

  String _helpFor(List<String> argv) {
    var cmd = this;
    var full = name;
    for (final t in argv) {
      if (t.startsWith('-') || t == '--') break;
      final sub = _findSub(cmd.commands, t);
      if (sub == null) break;
      cmd = sub;
      full = '$full ${cmd.name}';
    }
    return full;
  }
}

/// What a handler is handed: values read back with `ctx(def)`.
final class Ctx {
  Ctx._(this._target, this._chain, this._values, List<String> rest) : _rest = List.unmodifiable(rest);

  final Command _target;
  final List<Command> _chain;
  final Map<Object, Object?> _values;
  final List<String> _rest;

  /// The value of [def], typed by its declaration. A definition this command
  /// (or an ancestor, for options) does not declare is a [StateError].
  T call<T>(Object def) {
    if (!_declares(def)) {
      throw StateError('Cannot read ${_defShown(def)}: it is not declared on "$_fullName"');
    }
    if (_values.containsKey(def)) return _values[def] as T;
    return _absent(def) as T;
  }

  /// Positional tail left after [Arg] binding (all of it when no [Arg] defs).
  List<String> rest() => List.of(_rest);

  String usage() => _commandUsage(_target, _chain);

  bool _declares(Object def) {
    for (final c in _chain) {
      if (c.values.contains(def)) return true;
    }
    return _target.values.contains(def);
  }

  String get _fullName => _chain.map((c) => c.name).join(' ');
}

/// A usage error a handler throws for a mistake only it can see (exit 64).
final class UsageException implements Exception {
  const UsageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A command handler.
typedef Handler = FutureOr<void> Function(Ctx ctx);


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

void _checkSupported<T>(String name, T Function(String)? parse) {
  if (parse != null) return;
  if (T == String || T == int || T == double || T == num || T == bool || T == Duration || T == DateTime || T == Uri) {
    return;
  }
  throw ArgumentError.value(T, 'T', 'Unsupported type for "$name": use String, int, double, num, bool, Duration, DateTime, Uri, or parse:');
}

bool _isDef(Object v) => v is Flag || v is Opt<Object> || v is Multi<Object> || v is Arg<Object>;

String _defName(Object v) {
  if (v is Flag) return v.name;
  if (v is Opt<Object>) return v.name;
  if (v is Multi<Object>) return v.name;
  if (v is Arg<Object>) return v.name;
  return '';
}

String? _defShort(Object v) {
  if (v is Flag) return v.short;
  if (v is Opt<Object>) return v.short;
  if (v is Multi<Object>) return v.short;
  return null;
}

String _defShown(Object def) {
  final n = _defName(def);
  if (n.isEmpty) return '$def';
  if (def is Arg<Object>) return '<$n>';
  return '--$n';
}

Object? _absent(Object def) {
  if (def is Flag) return def.or;
  if (def is Opt<Object>) return def.or;
  if (def is Multi<Object>) return _typedMultiList(def, def.or);
  if (def is Arg<Object>) {
    if (def.many) return _emptyArgList(def);
    return def.or;
  }
  return null;
}

/// Typed empty list for an absent `many` Arg (reified per T).
Object? _emptyArgList(Arg<Object> def) {
  if (def is Arg<String>) return <String>[];
  if (def is Arg<int>) return <int>[];
  if (def is Arg<double>) return <double>[];
  if (def is Arg<num>) return <num>[];
  if (def is Arg<bool>) return <bool>[];
  if (def is Arg<Duration>) return <Duration>[];
  if (def is Arg<DateTime>) return <DateTime>[];
  if (def is Arg<Uri>) return <Uri>[];
  return <Object?>[];
}

/// Rebuild [raws] as an unmodifiable list reified per the def's T.
Object? _typedMultiList(Object def, List<Object?> raws) {
  if (def is Multi<String>) return List<String>.unmodifiable([for (final e in raws) e as String]);
  if (def is Multi<int>) return List<int>.unmodifiable([for (final e in raws) e as int]);
  if (def is Multi<double>) return List<double>.unmodifiable([for (final e in raws) e as double]);
  if (def is Multi<num>) return List<num>.unmodifiable([for (final e in raws) e as num]);
  if (def is Multi<bool>) return List<bool>.unmodifiable([for (final e in raws) e as bool]);
  if (def is Multi<Duration>) {
    return List<Duration>.unmodifiable([for (final e in raws) e as Duration]);
  }
  if (def is Multi<DateTime>) {
    return List<DateTime>.unmodifiable([for (final e in raws) e as DateTime]);
  }
  if (def is Multi<Uri>) return List<Uri>.unmodifiable([for (final e in raws) e as Uri]);
  return List<Object?>.unmodifiable(raws);
}

/// Coerce [taken] positionals into a list reified per the Arg's T.
Object? _readArgListDynamic(Arg<Object> def, List<String> taken) {
  final what = 'argument <${def.name}>';
  if (def is Arg<String>) {
    return List<String>.unmodifiable([for (final r in taken) _readTyped<String>(def.name, r, what, def.parse)]);
  }
  if (def is Arg<int>) {
    return List<int>.unmodifiable([for (final r in taken) _readTyped<int>(def.name, r, what, def.parse)]);
  }
  if (def is Arg<double>) {
    return List<double>.unmodifiable([for (final r in taken) _readTyped<double>(def.name, r, what, def.parse)]);
  }
  if (def is Arg<num>) {
    return List<num>.unmodifiable([for (final r in taken) _readTyped<num>(def.name, r, what, def.parse)]);
  }
  if (def is Arg<bool>) {
    return List<bool>.unmodifiable([for (final r in taken) _readTyped<bool>(def.name, r, what, def.parse)]);
  }
  if (def is Arg<Duration>) {
    return List<Duration>.unmodifiable([for (final r in taken) _readTyped<Duration>(def.name, r, what, def.parse)]);
  }
  if (def is Arg<DateTime>) {
    return List<DateTime>.unmodifiable([for (final r in taken) _readTyped<DateTime>(def.name, r, what, def.parse)]);
  }
  if (def is Arg<Uri>) {
    return List<Uri>.unmodifiable([for (final r in taken) _readTyped<Uri>(def.name, r, what, def.parse)]);
  }
  final p = def.parse;
  if (p != null) {
    try {
      return List.of([for (final r in taken) p(r)]);
    } on FormatException catch (e) {
      throw FormatException('Invalid value for $what: ${e.message}');
    } catch (e) {
      throw FormatException('Invalid value for $what: $e');
    }
  }
  throw FormatException('Invalid value for $what.');
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
      throw FormatException('Invalid value "$raw" for option "--$name": a flag takes true or false');
  }
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
    final d = c.startsWith(typed) ? 0 : _levenshtein(typed, c);
    if (d < bestD) {
      best = c;
      bestD = d;
    }
  }
  if (best == null) return null;
  if (bestD <= max(2, typed.length ~/ 3) && bestD < typed.length) return best;
  return null;
}

T _readTyped<T extends Object>(String name, String raw, String what, T Function(String)? custom) {
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
  if (T == String) {
    return raw as T;
  } else if (T == int) {
    v = int.tryParse(raw);
    expected = 'an integer';
  } else if (T == double) {
    v = double.tryParse(raw);
    expected = 'a number';
  } else if (T == num) {
    v = num.tryParse(raw);
    expected = 'a number';
  } else if (T == bool) {
    try {
      return _parseFlagValue(name, raw) as T;
    } on FormatException {
      throw FormatException('Invalid value "$raw" for $what: expected true or false');
    }
  } else if (T == Duration) {
    v = _parseDuration(raw);
    expected = 'a duration such as 90s or 1h30m';
  } else if (T == DateTime) {
    v = DateTime.tryParse(raw);
    expected = 'a date such as 2026-10-08';
  } else if (T == Uri) {
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
  final s = raw.trim();
  if (s.isEmpty) return null;
  if (RegExp(r'^-?\d+(\.\d+)?$').hasMatch(s)) {
    final n = num.tryParse(s);
    if (n == null) return null;
    return Duration(milliseconds: (n * 1000).round());
  }
  final m = RegExp(r'(\d+(?:\.\d+)?)(ms|h|m|s|d)').allMatches(s);
  if (m.isEmpty) return null;
  var covered = 0;
  var ms = 0.0;
  for (final x in m) {
    covered += (x.group(0) ?? '').length;
    final n = num.parse(x.group(1) ?? '0');
    switch (x.group(2)) {
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
  if (covered != s.length) return null;
  return Duration(milliseconds: ms.round());
}

String _typeHint(Type t) {
  if (t == String) return '<value>';
  if (t == int) return '<int>';
  if (t == double || t == num) return '<number>';
  if (t == bool) return '<bool>';
  if (t == Duration) return '<duration>';
  if (t == DateTime) return '<date>';
  if (t == Uri) return '<url>';
  return '<value>';
}

Type _defType(Object def) {
  if (def is Opt<String>) return String;
  if (def is Opt<int>) return int;
  if (def is Opt<double>) return double;
  if (def is Opt<num>) return num;
  if (def is Opt<bool>) return bool;
  if (def is Opt<Duration>) return Duration;
  if (def is Opt<DateTime>) return DateTime;
  if (def is Opt<Uri>) return Uri;
  if (def is Multi<String>) return String;
  if (def is Multi<int>) return int;
  if (def is Multi<double>) return double;
  if (def is Multi<num>) return num;
  if (def is Multi<bool>) return bool;
  if (def is Multi<Duration>) return Duration;
  if (def is Multi<DateTime>) return DateTime;
  if (def is Multi<Uri>) return Uri;
  if (def is Arg<String>) return String;
  if (def is Arg<int>) return int;
  if (def is Arg<double>) return double;
  if (def is Arg<num>) return num;
  if (def is Arg<bool>) return bool;
  if (def is Arg<Duration>) return Duration;
  if (def is Arg<DateTime>) return DateTime;
  if (def is Arg<Uri>) return Uri;
  return Object;
}

String _oneLine(String s) => s.split('\n').first.trim();

Command? _findSub(List<Command> commands, String token) {
  for (final c in commands) {
    if (c.name == token || c.aliases.contains(token)) return c;
  }
  return null;
}

({Command cmd, List<Command> chain}) _resolveHelpTarget(Command root, List<String> argv) {
  var cmd = root;
  var chain = [root];
  for (final t in argv) {
    if (t.startsWith('-') || t == '--') break;
    final sub = _findSub(cmd.commands, t);
    if (sub == null) break;
    cmd = sub;
    chain = [...chain, cmd];
  }
  return (cmd: cmd, chain: chain);
}

final class _Parsed {
  _Parsed(this.target, this.chain, this.values, this.rest, this.help);

  final Command target;
  final List<Command> chain;
  final Map<Object, Object?> values;
  final List<String> rest;
  final bool help;

  String get fullName => chain.map((c) => c.name).join(' ');
}

_Parsed _parseCommand(Command root, List<String> argv, List<Command> ancestors) {
  final chain = [...ancestors, root];
  // Visible defs, nearest first.
  final byLong = <String, Object>{};
  final byShort = <String, Object>{};
  for (var i = chain.length - 1; i >= 0; i--) {
    for (final v in chain[i].values) {
      final n = _defName(v);
      byLong.putIfAbsent(n, () => v);
      final s = _defShort(v);
      if (s != null) byShort.putIfAbsent(s, () => v);
    }
  }
  final hasHelpOpt = byLong.containsKey('help') || byShort.containsKey('h');
  final values = <Object, Object?>{};
  final multiAccum = <Object, List<Object?>>{};
  final rest = <String>[];
  var help = false;
  var i = 0;

  Object? lookupLong(String key) => byLong[key];
  Object? lookupShort(String c) => byShort[c];

  void putSingle(Object def, Object? value) {
    values[def] = value;
  }

  void putMulti(Object def, Object? value) {
    multiAccum.putIfAbsent(def, () => []).add(value);
  }

  String longWhat(String key) => 'option "--$key"';

  while (i < argv.length) {
    final token = argv[i];
    if (token == '--') {
      rest.addAll(argv.sublist(i + 1));
      i = argv.length;
      break;
    }
    final isLong = token.startsWith('--');
    if (!isLong && !_isShortish(token)) {
      // Positional: subcommand dispatch on the first one.
      if (rest.isEmpty && root.commands.isNotEmpty) {
        final sub = _findSub(root.commands, token);
        if (sub != null) {
          // Carry parsed-so-far values into the child.
          final child = _parseCommand(sub, argv.sublist(i + 1), chain);
          // Merge parent values (child wins on conflict by identity; names
          // cannot collide at parse time across levels except by shadowing,
          // where the child's own def object differs).
          for (final e in values.entries) {
            child.values.putIfAbsent(e.key, () => e.value);
          }
          for (final e in multiAccum.entries) {
            child.values.putIfAbsent(e.key, () => e.value);
          }
          return _Parsed(child.target, child.chain, child.values, child.rest, child.help || help);
        }
        // No subcommand named and no Arg defs: unknown command.
        if (_argDefsOf(root).isEmpty) {
          final guess = _closest(token, [for (final c in root.commands) ...[c.name, ...c.aliases]]);
          throw FormatException(
            'Unknown command "$token"${guess == null ? '' : '. Did you mean "$guess"?'}.',
          );
        }
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
      if ((key == 'help') && !hasHelpOpt) {
        help = true;
        i++;
        continue;
      }
      final def = lookupLong(key);
      if (def == null) {
        if (key.startsWith('no-') && inline == null) {
          final base = byLong[key.substring(3)];
          if (base is Flag && base.or) {
            putSingle(base, false);
            i++;
            continue;
          }
        }
        final guess = _closest(key, byLong.keys);
        throw FormatException(
          'Unknown option --$key${guess == null ? '' : '. Did you mean "--$guess"?'}.',
        );
      }
      if (def is Flag) {
        putSingle(def, inline == null ? true : _parseFlagValue(def.name, inline));
        i++;
      } else if (def is Opt<Object>) {
        final what = longWhat(key);
        if (inline != null) {
          putSingle(def, _readDynamic(def, inline, what));
          i++;
        } else if (i + 1 < argv.length) {
          putSingle(def, _readDynamic(def, argv[i + 1], what));
          i += 2;
        } else {
          throw FormatException('Option --$key needs a value.');
        }
      } else if (def is Multi<Object>) {
        final what = longWhat(key);
        if (inline != null) {
          putMulti(def, _readDynamic(def, inline, what));
          i++;
        } else if (i + 1 < argv.length) {
          putMulti(def, _readDynamic(def, argv[i + 1], what));
          i += 2;
        } else {
          throw FormatException('Option --$key needs a value.');
        }
      } else {
        throw FormatException('Unknown option --$key.');
      }
      continue;
    }
    // Single-dash group / attached / number.
    if (token == '-h' && !hasHelpOpt) {
      help = true;
      i++;
      continue;
    }
    if (_isNumberToken(token, byShort)) {
      rest.add(token);
      i++;
      continue;
    }
    var consumed = false;
    for (var k = 1; k < token.length; k++) {
      final c = token[k];
      final def = lookupShort(c);
      if (def == null) {
        throw FormatException('Unknown option -$c in "-${token.substring(1)}".');
      }
      if (!hasHelpOpt && ((c == 'h') || (def is Flag && def.name == 'help'))) {
        // Declared help wins; handled above. Unreachable when built-in.
      }
      if (def is Flag) {
        if (k + 1 < token.length && token[k + 1] == '=') {
          putSingle(def, _parseFlagValue(def.name, token.substring(k + 2)));
          consumed = true;
          break;
        }
        putSingle(def, true);
        continue;
      }
      // Valued short consumes the remainder (after one optional '=').
      var attached = token.substring(k + 1);
      if (attached.startsWith('=')) attached = attached.substring(1);
      final what = 'option "-$c"';
      if (def is Opt<Object>) {
        if (attached.isNotEmpty) {
          putSingle(def, _readDynamic(def, attached, what));
        } else if (i + 1 < argv.length) {
          putSingle(def, _readDynamic(def, argv[i + 1], what));
          i++;
        } else {
          throw FormatException('Option -$c needs a value.');
        }
        consumed = true;
        break;
      }
      if (def is Multi<Object>) {
        if (attached.isNotEmpty) {
          putMulti(def, _readDynamic(def, attached, what));
        } else if (i + 1 < argv.length) {
          putMulti(def, _readDynamic(def, argv[i + 1], what));
          i++;
        } else {
          throw FormatException('Option -$c needs a value.');
        }
        consumed = true;
        break;
      }
      throw FormatException('Unknown option -$c in "-${token.substring(1)}".');
    }
    if (!consumed) {
      // Pure flag group like -vq: nothing more to do (values already set).
    }
    i++;
  }
  for (final e in multiAccum.entries) {
    values[e.key] = _typedMultiList(e.key, e.value);
  }
  // Bind positionals to Arg defs.
  final args = _argDefsOf(root);
  if (args.isNotEmpty) {
    var at = 0;
    for (var a = 0; a < args.length; a++) {
      final def = args[a];
      if (def.many) {
        final taken = rest.sublist(at);
        at = rest.length;
        if (taken.isEmpty && def.required) {
          throw FormatException('Missing argument <${def.name}>.');
        }
        values[def] = _readArgListDynamic(def, taken);
      } else if (at < rest.length) {
        values[def] = _readArgDynamic(def, rest[at++]);
      } else if (def.required) {
        throw FormatException('Missing argument <${def.name}>.');
      } else if (def.or != null) {
        values[def] = def.or;
      }
    }
    if (at < rest.length) {
      throw FormatException('Unexpected argument "${rest[at]}".');
    }
    rest.clear();
  }
  // Required valued checks (before handler runs).
  for (final v in root.values) {
    if (v is Opt<Object> && v.required && !values.containsKey(v)) {
      throw FormatException('Missing option --${v.name}.');
    }
    if (v is Multi<Object> && v.required) {
      final got = values[v] as List?;
      if (got == null || got.isEmpty) {
        throw FormatException('Missing option --${v.name}.');
      }
    }
  }
  // Fill absent multi defaults so ctx() never misses.
  for (final v in root.values) {
    if (v is Multi<Object> && !values.containsKey(v)) {
      values[v] = _typedMultiList(v, v.or);
    }
  }
  return _Parsed(root, chain, values, List.of(rest), help);
}

List<Arg<Object>> _argDefsOf(Command cmd) {
  final out = <Arg<Object>>[];
  for (final v in cmd.values) {
    if (v is Arg<Object>) out.add(v);
  }
  return out;
}

Object? _readDynamic(Object def, String raw, String what) {
  if (def is Opt<Object>) {
    return _readOptDynamic(def, raw, what);
  }
  if (def is Multi<Object>) {
    return _readMultiDynamic(def, raw, what);
  }
  throw FormatException('Invalid value "$raw" for $what.');
}

Object? _readOptDynamic(Opt<Object> def, String raw, String what) {
  if (def is Opt<String>) return _readTyped<String>(def.name, raw, what, def.parse);
  if (def is Opt<int>) return _readTyped<int>(def.name, raw, what, def.parse);
  if (def is Opt<double>) return _readTyped<double>(def.name, raw, what, def.parse);
  if (def is Opt<num>) return _readTyped<num>(def.name, raw, what, def.parse);
  if (def is Opt<bool>) return _readTyped<bool>(def.name, raw, what, def.parse);
  if (def is Opt<Duration>) return _readTyped<Duration>(def.name, raw, what, def.parse);
  if (def is Opt<DateTime>) return _readTyped<DateTime>(def.name, raw, what, def.parse);
  if (def is Opt<Uri>) return _readTyped<Uri>(def.name, raw, what, def.parse);
  final p = def.parse;
  if (p != null) {
    try {
      return p(raw);
    } on FormatException catch (e) {
      throw FormatException('Invalid value "$raw" for $what: ${e.message}');
    } catch (e) {
      throw FormatException('Invalid value "$raw" for $what: $e');
    }
  }
  throw FormatException('Invalid value "$raw" for $what.');
}

Object? _readMultiDynamic(Multi<Object> def, String raw, String what) {
  if (def is Multi<String>) return _readTyped<String>(def.name, raw, what, def.parse);
  if (def is Multi<int>) return _readTyped<int>(def.name, raw, what, def.parse);
  if (def is Multi<double>) return _readTyped<double>(def.name, raw, what, def.parse);
  if (def is Multi<num>) return _readTyped<num>(def.name, raw, what, def.parse);
  if (def is Multi<bool>) return _readTyped<bool>(def.name, raw, what, def.parse);
  if (def is Multi<Duration>) return _readTyped<Duration>(def.name, raw, what, def.parse);
  if (def is Multi<DateTime>) return _readTyped<DateTime>(def.name, raw, what, def.parse);
  if (def is Multi<Uri>) return _readTyped<Uri>(def.name, raw, what, def.parse);
  final p = def.parse;
  if (p != null) {
    try {
      return p(raw);
    } on FormatException catch (e) {
      throw FormatException('Invalid value "$raw" for $what: ${e.message}');
    } catch (e) {
      throw FormatException('Invalid value "$raw" for $what: $e');
    }
  }
  throw FormatException('Invalid value "$raw" for $what.');
}

Object? _readArgDynamic(Arg<Object> def, String raw) {
  final what = 'argument <${def.name}>';
  if (def is Arg<String>) return _readTyped<String>(def.name, raw, what, def.parse);
  if (def is Arg<int>) return _readTyped<int>(def.name, raw, what, def.parse);
  if (def is Arg<double>) return _readTyped<double>(def.name, raw, what, def.parse);
  if (def is Arg<num>) return _readTyped<num>(def.name, raw, what, def.parse);
  if (def is Arg<bool>) return _readTyped<bool>(def.name, raw, what, def.parse);
  if (def is Arg<Duration>) return _readTyped<Duration>(def.name, raw, what, def.parse);
  if (def is Arg<DateTime>) return _readTyped<DateTime>(def.name, raw, what, def.parse);
  if (def is Arg<Uri>) return _readTyped<Uri>(def.name, raw, what, def.parse);
  final p = def.parse;
  if (p != null) {
    try {
      return p(raw);
    } on FormatException catch (e) {
      throw FormatException('Invalid value "$raw" for $what: ${e.message}');
    } catch (e) {
      throw FormatException('Invalid value "$raw" for $what: $e');
    }
  }
  throw FormatException('Invalid value "$raw" for $what.');
}

bool _isShortish(String t) => t.startsWith('-') && !t.startsWith('--') && t.length > 1 && t != '-';

bool _isNumberToken(String t, Map<String, Object> byShort) {
  if (!t.startsWith('-') || t.startsWith('--') || t.length < 2) return false;
  if (num.tryParse(t) == null) return false;
  return !byShort.containsKey(t[1]);
}

String _commandUsage(Command target, List<Command> chain) {
  final full = chain.map((c) => c.name).join(' ');
  final argDefs = _argDefsOf(target);
  final shape = <String>[
    for (final a in argDefs) _argPlaceholder(a),
    '[options]',
    if (target.commands.isNotEmpty) '[command]',
  ];
  final buf = StringBuffer()..writeln('Usage: $full ${shape.join(' ')}'.trimRight());
  if (target.help.isNotEmpty) buf.writeln('\n${target.help}');
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
    [for (final c in target.commands) ([c.name, ...c.aliases].join(', '), c.help)],
  );
  section('Options:', _optionRows(target));
  // Ancestors are chain[:-1] (chain holds Commands already).
  final grows = <(String, String)>[];
  for (final a in chain.sublist(0, chain.length - 1).reversed) {
    grows.addAll(_optionRows(a));
  }
  section('Global options:', grows);
  if (target.commands.isNotEmpty && chain.length == 1) {
    buf.writeln('\nRun "$full <command> --help" for more on a command.');
  }
  return '$buf'.trimRight();
}

String _argPlaceholder(Arg<Object> a) {
  if (a.required && a.many) return '<${a.name}>...';
  if (a.required) return '<${a.name}>';
  if (a.many) return '[${a.name}...]';
  return '[${a.name}]';
}

String _describeArg(Arg<Object> a) {
  var d = a.help;
  if (a.required) d = d.isEmpty ? '[required]' : '$d [required]';
  return d.trimLeft();
}

List<(String, String)> _optionRows(Command cmd) {
  final rows = <(String, String)>[];
  for (final v in cmd.values) {
    if (v is Arg<Object>) continue;
    if (v is Flag) {
      final left = '${v.short != null ? '-${v.short}, ' : '    '}--${v.or ? '[no-]' : ''}${v.name}';
      rows.add((left, v.help));
    } else if (v is Opt<Object>) {
      final hint = _typeHint(_defType(v));
      final left = '${v.short != null ? '-${v.short}, ' : '    '}--${v.name} $hint';
      var right = v.help;
      if (v.or != null) right = '${right.isEmpty ? '' : '$right '}[default: ${v.or}]';
      if (v.required) right = '${right.isEmpty ? '' : '$right '}[required]';
      rows.add((left, right.trimLeft()));
    } else if (v is Multi<Object>) {
      final hint = '${_typeHint(_defType(v))}...';
      final left = '${v.short != null ? '-${v.short}, ' : '    '}--${v.name} $hint';
      var right = v.help;
      if (v.or.isNotEmpty) right = '${right.isEmpty ? '' : '$right '}[default: ${v.or.join(', ')}]';
      if (v.required) right = '${right.isEmpty ? '' : '$right '}[required]';
      rows.add((left, right.trimLeft()));
    }
  }
  return rows;
}
