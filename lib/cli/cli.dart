/// # CLI Domain (`cli.*`)
///
/// A dependency-free parser for the flag shapes scripts actually use:
/// `--flag`, `--key=value`, `--key value`, `-k value`, `-abc`, `--no-key`,
/// repeated options, and trailing positional arguments.
///
/// Two ways in. Declare an interface and read it yourself:
///
/// ```dart
/// cli
///   ..flag('force', alias: 'f')
///   ..parse(args);
/// ```
///
/// Or declare commands and let [CliAccessor.run] parse, validate, print
/// `--help` and pick the handler:
///
/// ```dart
/// Future<int> build(Cli cli) async => 0;
///
/// void main(List<String> args) async {
///   cli.handle('build', build, desc: 'Build the project')
///     ..option('out', alias: 'o', def: 'dist', desc: 'Output directory');
///   await system.shutdown(await cli.run(args));
/// }
/// ```
library;

import 'dart:async';
import 'dart:io';

import '../src/shared.dart';
import '../system/console/ansi.dart';
import '../system/console/writer.dart';
import '../util/time.dart';

// ============================================================================
// CLI DOMAIN (cli.*) - Argument Parsing
// ============================================================================

/// The `cli` domain: flags, options, subcommands and usage text.
///
/// Parsing arguments touches nothing — no process, no environment, no
/// terminal — so it is a domain of its own rather than a corner of
/// `system`. Not `const`: the accessor holds the declarations and the last
/// parse.
final CliAccessor cli = CliAccessor();

/// One declared flag or option, and the way to read it.
///
/// A declaration hands one back, so the type is settled once — at the
/// declaration — rather than guessed at every call site:
///
/// ```dart
/// final force = cli.flag('force', alias: 'f');             // Opt<bool>
/// final size = cli.number('concurrency', def: 4);          // Opt<int>
/// final out = cli.option('out', alias: 'o', def: 'dist');  // Opt<String>
///
/// cli.parse(args);
///
/// if (force()) rebuild(out(), size());
/// ```
///
/// Calling the option reads it. Sources resolve in the usual order — the
/// command line, then the `env` variable the declaration names, then [def] —
/// and the answer is a [T], never text that still has to be parsed.
final class Opt<T> {
  /// The long name, without dashes.
  final String name;

  /// The short alias, without dashes, or `null`.
  final String? alias;

  /// What this option reads when nothing supplied a value.
  final T def;

  final _Spec _owner;
  final T Function(Cli cli, Opt<T> self) _resolver;

  const Opt._(this.name, this.alias, this.def, this._owner, this._resolver);

  /// The resolved value.
  ///
  /// Reads from [from], or from whichever command line the declaring object
  /// last parsed — the shared `cli`, a [Cli] itself, or, for an option
  /// declared on a [Command], the scope that command was run with.
  T call([Cli? from]) => _resolver(from ?? _owner._reader, this);

  /// Whether the command line itself carried this option.
  ///
  /// False for a value that came from `env` or [def], which is how a script
  /// tells "not given" from "given the same as the default".
  bool given([Cli? from]) => (from ?? _owner._reader)._given(this);

  /// How many times the command line carried it.
  ///
  /// A repeated switch is how a command line spells a level, so `-vvv` and
  /// `--verbose --verbose --verbose` both count three:
  ///
  /// ```dart
  /// final verbose = cli.flag('verbose', alias: 'v');
  /// final level = switch (verbose.count()) {
  ///   0 => LogLevel.warn,
  ///   1 => LogLevel.info,
  ///   _ => LogLevel.debug,
  /// };
  /// ```
  int count([Cli? from]) => (from ?? _owner._reader)._count(this);

  /// Whether `--no-[name]` was given.
  bool negated([Cli? from]) => (from ?? _owner._reader)._negated(this);

  @override
  String toString() => 'Opt<$T>($name)';
}

/// What an option is parsed as, for validation and the usage block.
enum _Shape { text, number, decimal, list, duration, date }

/// The declaration behind an [Opt].
class _Decl {
  const _Decl({
    this.alias,
    this.desc = '',
    this.def,
    this.flag = false,
    this.required = false,
    this.allowed,
    this.env,
    this.csv = false,
    this.shape = _Shape.text,
  });

  final String? alias;
  final String desc;

  /// The declared default, kept to print it in the usage block and to satisfy
  /// [Cli.require]. The value an [Opt] reads is its own typed [Opt.def].
  final Object? def;
  final bool flag;
  final bool required;
  final List<String>? allowed;
  final String? env;
  final bool csv;
  final _Shape shape;
}

/// Declaring an interface: the half of the API shared by [Cli], [Command] and
/// [CliAccessor].
///
/// Every declaration returns the [Opt] that reads it, so the three read the
/// same way and the type of a value is fixed where it is declared.
mixin _Spec {
  final Map<String, _Decl> _declarations = {};
  final Map<String, Command> _children = {};

  /// The command line an [Opt] declared here reads from.
  Cli get _reader;

  /// Called after a declaration changes, so [Cli] can re-read its arguments.
  void _changed() {}

  String? _short(String? alias) => alias == null ? null : Cli._clean(alias);

  Opt<V> _declare<V>(
    String name,
    String? alias,
    V def,
    _Decl decl,
    V Function(Cli cli, Opt<V> self) resolver,
  ) {
    _declarations[Cli._clean(name)] = decl;
    _changed();
    return Opt<V>._(Cli._clean(name), _short(alias), def, this, resolver);
  }

  /// Declares a boolean flag.
  ///
  /// A flag never consumes the token after it, so `--verbose main.dart` leaves
  /// `main.dart` a positional argument. [def] is what the returned [Opt] reads
  /// when neither the command line nor [env] said otherwise.
  ///
  /// [env] names an environment variable to read when the flag is absent, so a
  /// boolean can be set by the shell as well as on the command line —
  /// `CI=true`, `FORCE=1`.
  ///
  /// ```dart
  /// final force = cli.flag('force', alias: 'f');
  /// if (force()) rebuild();
  /// ```
  Opt<bool> flag(
    String name, {
    String? alias,
    String desc = '',
    bool def = false,
    String? env,
  }) => _declare<bool>(
    name,
    alias,
    def,
    _Decl(alias: _short(alias), desc: desc, def: def, flag: true, env: env),
    (cli, self) => cli._readFlag(self),
  );

  /// Declares an option carrying text.
  ///
  /// [def] is what the option reads when nothing supplied a value, and it
  /// satisfies [Cli.require] — so a default is written once, here, rather than
  /// at every call site. [env] names an environment variable to fall back to,
  /// which also satisfies `require`. [allowed] limits the accepted values.
  ///
  /// ```dart
  /// final out = cli.option('out', alias: 'o', def: 'dist');
  /// ```
  Opt<String> option(
    String name, {
    String? alias,
    String desc = '',
    String def = '',
    bool required = false,
    List<String>? allowed,
    String? env,
  }) => _declare<String>(
    name,
    alias,
    def,
    _Decl(
      alias: _short(alias),
      desc: desc,
      def: def.isEmpty ? null : def,
      required: required,
      allowed: allowed,
      env: env,
    ),
    (cli, self) => cli._readText(self) ?? self.def,
  );

  /// Declares an option carrying a whole number.
  ///
  /// ```dart
  /// final size = cli.number('concurrency', def: 4);
  /// ```
  ///
  /// A value that is not a number reads as [def], and [Cli.require] reports it
  /// rather than letting the script run on a number nobody asked for.
  Opt<int> number(
    String name, {
    String? alias,
    String desc = '',
    int def = 0,
    bool required = false,
    String? env,
  }) => _declare<int>(
    name,
    alias,
    def,
    _Decl(
      alias: _short(alias),
      desc: desc,
      def: def,
      required: required,
      env: env,
      shape: _Shape.number,
    ),
    (cli, self) {
      final text = cli._readText(self);
      return text == null ? self.def : int.tryParse(text.trim()) ?? self.def;
    },
  );

  /// Declares an option carrying a decimal number.
  Opt<double> decimal(
    String name, {
    String? alias,
    String desc = '',
    double def = 0,
    bool required = false,
    String? env,
  }) => _declare<double>(
    name,
    alias,
    def,
    _Decl(
      alias: _short(alias),
      desc: desc,
      def: def,
      required: required,
      env: env,
      shape: _Shape.decimal,
    ),
    (cli, self) {
      final text = cli._readText(self);
      return text == null ? self.def : double.tryParse(text.trim()) ?? self.def;
    },
  );

  /// Declares an option that may be given more than once.
  ///
  /// Every occurrence contributes a value. With [csv] set, one comma-separated
  /// value contributes each part, so `--tag a,b` and `--tag a --tag b` read
  /// the same.
  ///
  /// ```dart
  /// final tags = cli.list('tag', csv: true);
  /// for (final tag in tags()) print(tag);
  /// ```
  Opt<List<String>> list(
    String name, {
    String? alias,
    String desc = '',
    List<String> def = const [],
    bool required = false,
    List<String>? allowed,
    bool csv = false,
    String? env,
  }) => _declare<List<String>>(
    name,
    alias,
    def,
    _Decl(
      alias: _short(alias),
      desc: desc,
      required: required,
      allowed: allowed,
      env: env,
      csv: csv,
      shape: _Shape.list,
    ),
    (cli, self) {
      final values = cli._readAll(self);
      return values.isEmpty ? self.def : values;
    },
  );

  /// Declares an option whose value is one of an enum's.
  ///
  /// The accepted spellings are the enum's own names, so the usage block and
  /// the validation both come from the type rather than a second list that can
  /// drift away from it.
  ///
  /// ```dart
  /// final level = cli.choice('level', LogLevel.values, def: LogLevel.info);
  /// system.console.logger.level = level();
  /// ```
  Opt<E> choice<E extends Enum>(
    String name,
    List<E> values, {
    required E def,
    String? alias,
    String desc = '',
    bool required = false,
    String? env,
  }) => _declare<E>(
    name,
    alias,
    def,
    _Decl(
      alias: _short(alias),
      desc: desc,
      def: def.name,
      required: required,
      allowed: [for (final value in values) value.name],
      env: env,
    ),
    (cli, self) {
      final text = cli._readText(self)?.trim().toLowerCase();
      if (text == null) return self.def;
      for (final value in values) {
        if (value.name.toLowerCase() == text) return value;
      }
      return self.def;
    },
  );

  /// Declares an option carrying a length of time.
  ///
  /// The value is read by `util.time.span`, so `--timeout 30s`,
  /// `--timeout 1h30m` and a bare `--timeout 30` (seconds) all work. A value
  /// that is not a duration reads as [def], and [Cli.require] reports it.
  ///
  /// ```dart
  /// final timeout = cli.duration('timeout', def: 30.s);
  /// await net.http.get(url, timeout: timeout());
  /// ```
  Opt<Duration> duration(
    String name, {
    String? alias,
    String desc = '',
    Duration def = Duration.zero,
    bool required = false,
    String? env,
  }) => _declare<Duration>(
    name,
    alias,
    def,
    _Decl(
      alias: _short(alias),
      desc: desc,
      def: _spanText(def),
      required: required,
      env: env,
      shape: _Shape.duration,
    ),
    (cli, self) {
      final text = cli._readText(self);
      return text == null
          ? self.def
          : const TimeAccessor().span(text) ?? self.def;
    },
  );

  /// Declares an option carrying a date.
  ///
  /// The value is read by `util.time.parse`, so ISO-8601 and the loose forms
  /// it accepts all work. There is no sensible default date, so the [Opt]
  /// reads `null` when nothing was given — the option `--since` exists
  /// precisely so a script can tell "not given" from "the beginning of time".
  ///
  /// ```dart
  /// final since = cli.date('since');
  /// rows.transform(.where((r) => since() == null || r.seen.isAfter(since()!)));
  /// ```
  Opt<DateTime?> date(
    String name, {
    String? alias,
    String desc = '',
    DateTime? def,
    bool required = false,
    String? env,
  }) => _declare<DateTime?>(
    name,
    alias,
    def,
    _Decl(
      alias: _short(alias),
      desc: desc,
      def: def == null ? null : const TimeAccessor().iso(def),
      required: required,
      env: env,
      shape: _Shape.date,
    ),
    (cli, self) {
      final text = cli._readText(self);
      return text == null
          ? self.def
          : const TimeAccessor().parse(text) ?? self.def;
    },
  );

  /// [span] in the compact form `duration` reads back, for the usage block.
  static String _spanText(Duration span) {
    if (span == Duration.zero) return '0s';
    final parts = StringBuffer();
    var micros = span.inMicroseconds;
    for (final (label, unit) in const [
      ('d', Duration.microsecondsPerDay),
      ('h', Duration.microsecondsPerHour),
      ('m', Duration.microsecondsPerMinute),
      ('s', Duration.microsecondsPerSecond),
      ('ms', Duration.microsecondsPerMillisecond),
    ]) {
      final whole = micros ~/ unit;
      if (whole != 0) {
        parts.write('$whole$label');
        micros -= whole * unit;
      }
    }
    return parts.isEmpty ? '0s' : parts.toString();
  }

  /// Registers [name] as a subcommand run by [handler], returning it so that
  /// its own flags and options can be declared on the spot.
  ///
  /// ```dart
  /// final cmd = cli.handle('build', build, desc: 'Build the project');
  /// final out = cmd.option('out', alias: 'o', def: 'dist');
  /// ```
  ///
  /// The handler's return value is the exit code — see [Cli.run].
  Command handle(
    String name,
    FutureOr<int> Function(Cli cli) handler, {
    String desc = '',
  }) => _register(name, desc, handler);

  /// Registers [name] as a group of subcommands, returning it to nest under.
  ///
  /// Naming a group without one of its subcommands prints its usage block.
  ///
  /// ```dart
  /// final remote = cli.group('remote', desc: 'Manage remotes');
  /// remote.handle('add', build, desc: 'Add a remote');
  /// remote.handle('rm', build, desc: 'Remove a remote');
  /// ```
  Command group(String name, {String desc = ''}) => _register(name, desc, null);

  Command _register(
    String name,
    String desc,
    FutureOr<int> Function(Cli cli)? handler,
  ) {
    final child = _children[name] = Command._(name, desc, handler);
    _changed();
    return child;
  }

  /// The declaration named [cleanKey], or the one whose alias it is.
  _Decl? _decl(String cleanKey) =>
      _declarations[cleanKey] ??
      _declarations.values.where((d) => d.alias == cleanKey).firstOrNull;
}

/// Entry point for command-line arguments, reachable as `cli`.
///
/// Declare the interface, then either [parse] it and read the values yourself
/// or hand [run] the arguments and let it dispatch.
///
/// ```dart
/// void main(List<String> args) {
///   final force = cli.flag('force', alias: 'f');
///   final size = cli.number('concurrency', def: 4);
///   cli.parse(args);
///
///   if (force()) print('forcing, ${size()} at a time');
/// }
/// ```
class CliAccessor with _Spec {
  Cli _parsed = Cli(const []);

  /// Creates the accessor. Prefer the shared [cli] instance.
  CliAccessor();

  @override
  Cli get _reader => _parsed._reader;

  @override
  void _changed() {
    _parsed._declarations
      ..clear()
      ..addAll(_declarations);
    _parsed._children
      ..clear()
      ..addAll(_children);
    _parsed._parse();
  }

  /// Parses [args], replacing any previously parsed command line.
  void parse(List<String> args) {
    _parsed = Cli(args);
    _changed();
  }

  /// The command line as last parsed, for handing to code that takes a [Cli].
  Cli get parsed => _parsed;

  /// Parses [args], dispatches to the matching command and returns its exit
  /// code. See [Cli.run].
  Future<int> run(
    List<String> args, {
    String? syntax,
    String? desc,
    String? version,
    bool strict = false,
    FutureOr<int> Function(Cli cli)? body,
  }) {
    parse(args);
    return _parsed.run(
      syntax: syntax,
      desc: desc,
      version: version,
      strict: strict,
      body: body,
    );
  }

  /// Validates that [names] (or all declared required options) were supplied.
  void require([Iterable<String>? names]) => _parsed.require(names);

  /// Throws [ArgumentError] if any given switch was not declared.
  void strict() => _parsed.strict();

  /// Every switch given that no declaration covers.
  List<String> unknown() => _parsed.unknown();

  /// First positional argument as a subcommand name, or `null`.
  String? get command => _parsed.command;

  /// Positional arguments, in order. See [Cli.args].
  List<String> get args => _parsed.args;

  /// The raw argument list as parsed.
  List<String> get raw => _parsed.raw;

  /// Generates a formatted usage block string.
  String usage({
    String? syntax,
    String? desc,
    Map<String, String>? flags,
    Map<String, String>? options,
  }) =>
      _parsed.usage(syntax: syntax, desc: desc, flags: flags, options: options);

  /// Prints a usage block to stdout.
  void help({
    String? syntax,
    String? desc,
    Map<String, String>? flags,
    Map<String, String>? options,
  }) =>
      _parsed.help(syntax: syntax, desc: desc, flags: flags, options: options);
}

/// A parsed command line.
///
/// Normally reached through `cli`; construct one directly to parse an
/// argument list other than the program's own.
///
/// Declare the interface with [flag] and [option] before reading it. Declaring
/// is what lets the parser tell `--verbose main.dart` — a flag and a
/// positional — from `--out dist`, an option and its value; an *undeclared*
/// switch followed by a bare word takes that word as its value. [strict]
/// rejects switches that no declaration covers.
class Cli with _Spec {
  /// The exit code for a command line that could not be understood.
  ///
  /// The conventional `EX_USAGE`: an unknown switch, a missing required
  /// option, a value outside `allowed`, or an unrecognised command.
  static const int usageExit = 64;

  /// The raw arguments this instance parsed.
  final List<String> raw;

  final Map<String, String> _options = {};
  final Map<String, List<String>> _repeated = {};
  final Set<String> _flags = {};
  // How many times each switch was given, which the set alone cannot say. A
  // repeated flag is how a CLI spells a level: -v, -vv, -vvv.
  final Map<String, int> _tally = {};
  final List<String> _rest = [];
  final List<int> _restAt = [];

  /// Parses the given argument list, exposed as [raw].
  Cli(this.raw) {
    _parse();
  }

  /// The scope [run] built for the command it dispatched to, if any.
  ///
  /// An option declared globally is read from the same re-parse the handler
  /// gets, so a command's own declarations cannot change how a global one
  /// parses without the global reader noticing.
  Cli? _scopeInUse;

  @override
  Cli get _reader => _scopeInUse ?? this;

  @override
  void _changed() => _parse();

  void _parse() {
    _options.clear();
    _repeated.clear();
    _flags.clear();
    _tally.clear();
    _rest.clear();
    _restAt.clear();

    for (var i = 0; i < raw.length; i++) {
      final arg = raw[i];
      if (arg == '--') {
        for (var j = i + 1; j < raw.length; j++) {
          _rest.add(raw[j]);
          _restAt.add(j);
        }
        break;
      }

      final isLong = arg.startsWith('--');
      final isShort = !isLong && arg.startsWith('-') && arg.length > 1;
      if (!isLong && !isShort) {
        _rest.add(arg);
        _restAt.add(i);
        continue;
      }

      final token = arg.substring(isLong ? 2 : 1);
      final split = token.indexOf('=');
      final key = split != -1 ? token.substring(0, split) : token;
      final cleanKey = _clean(key);
      final decl = _decl(cleanKey);

      if (split != -1) {
        _option(cleanKey, token.substring(split + 1));
        continue;
      }

      // `-abc` is three short switches, unless a declaration claims the whole
      // token — so `-rf` stays a single switch once you declare it.
      if (isShort && token.length > 1 && decl == null && _clustered(token)) {
        i += _cluster(token, i);
        continue;
      }

      // If declared as a flag, do not consume the next token as a value.
      if (decl != null && decl.flag) {
        _mark(cleanKey);
        continue;
      }

      // `--key value`, but only when the next token is not itself a switch.
      if (i + 1 < raw.length && _isValue(raw[i + 1])) {
        _option(cleanKey, raw[i + 1]);
        i++;
        continue;
      }
      _mark(cleanKey);
    }
  }

  /// Whether a short token is a cluster of one-letter switches.
  ///
  /// Only all-letter tokens cluster, so `-p8` stays the single switch `p8`
  /// rather than becoming `p` and `8`.
  static bool _clustered(String token) =>
      RegExp(r'^[A-Za-z]+$').hasMatch(token);

  /// Records each short switch in [token], which sits at index [at].
  ///
  /// A clustered switch declared with a value ends the cluster and takes the
  /// rest of it, or else the next argument: `-o dist`, `-odist` and `-vodist`
  /// all set `o`. Returns how many extra arguments were consumed.
  int _cluster(String token, int at) {
    for (var c = 0; c < token.length; c++) {
      final short = token[c];
      final decl = _decl(short);
      if (decl == null || decl.flag) {
        _mark(short);
        continue;
      }
      final inline = token.substring(c + 1);
      if (inline.isNotEmpty) {
        _option(short, inline);
        return 0;
      }
      if (at + 1 < raw.length && _isValue(raw[at + 1])) {
        _option(short, raw[at + 1]);
        return 1;
      }
      _mark(short);
      return 0;
    }
    return 0;
  }

  /// Whether [arg] can serve as an option's value rather than being a switch.
  ///
  /// A negative number is a value, so `--offset -5` reads as `offset = -5`.
  static bool _isValue(String arg) =>
      !arg.startsWith('-') || arg == '-' || num.tryParse(arg) != null;

  void _option(String key, String value) {
    final cleanKey = _clean(key);
    final values = (_decl(cleanKey)?.csv ?? false)
        ? value.split(',').map((v) => v.trim()).where((v) => v.isNotEmpty)
        : [value];
    _options[cleanKey] = values.isEmpty ? value : values.last;
    _repeated.putIfAbsent(cleanKey, () => []).addAll(values);
    _mark(cleanKey);
  }

  static String _clean(String name) => name.replaceFirst(RegExp(r'^-+'), '');

  /// The alias to use for [name]: the one passed in, else the one declared.
  ///
  /// So an alias given once to [flag] or [option] is honoured by every later
  /// lookup, instead of having to be repeated at each call site.
  String? _alias(String name, String? explicit) {
    if (explicit != null) return _clean(explicit);
    return _decl(_clean(name))?.alias;
  }

  /// Records that switch [name] was given, and how many times.
  void _mark(String name) {
    _flags.add(name);
    _tally[name] = (_tally[name] ?? 0) + 1;
  }

  /// How many times the command line carried [opt]. See [Opt.count].
  int _count(Opt<Object?> opt) =>
      (_tally[opt.name] ?? 0) +
      (opt.alias != null ? (_tally[opt.alias!] ?? 0) : 0);

  /// Whether the command line carried [opt] at all. See [Opt.given].
  bool _given(Opt<Object?> opt) =>
      _flags.contains(opt.name) ||
      (opt.alias != null && _flags.contains(opt.alias!));

  /// Whether `--no-[name]` was given for [opt]. See [Opt.negated].
  bool _negated(Opt<Object?> opt) =>
      _no(opt.name) || (opt.alias != null && _no(opt.alias!));

  /// Whether `--no-[clean]` (or `--no[clean]`) was given.
  bool _no(String clean) =>
      _flags.contains('no-$clean') || _flags.contains('no$clean');

  /// The value of a boolean [opt], from every source in order.
  ///
  /// An explicit `--no-[name]` wins, then `--[name]=true|1`, then the bare
  /// switch, then `env`, then the declared default. An environment variable
  /// arrives as text, so it is read as a flag word rather than type-tested —
  /// without that, `env: 'FORCE'` could never satisfy a boolean.
  bool _readFlag(Opt<bool> opt) {
    if (_negated(opt)) return false;
    final given = _value(opt);
    if (given != null) return _truthy(given);
    if (_given(opt)) return true;
    final fromEnv = _fromEnv(_decl(opt.name));
    if (fromEnv != null) return _truthy(fromEnv);
    return opt.def;
  }

  /// The text [opt] resolved to, or `null` when nothing supplied one.
  ///
  /// The command line first, then the environment variable the declaration
  /// names. The declared default is [Opt.def]'s job, so it stays typed.
  String? _readText(Opt<Object?> opt) =>
      _value(opt) ?? _fromEnv(_decl(opt.name));

  /// Every value given for a repeated [opt], in order.
  List<String> _readAll(Opt<Object?> opt) {
    final values = [
      ...?_repeated[opt.name],
      if (opt.alias != null) ...?_repeated[opt.alias!],
    ];
    if (values.isNotEmpty) return values;
    final fromEnv = _fromEnv(_decl(opt.name));
    if (fromEnv == null) return const [];
    if (!(_decl(opt.name)?.csv ?? false)) return [fromEnv];
    return fromEnv
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
  }

  /// Every switch the command line carried, with the value each was given.
  ///
  /// The parser's own answer, before any declaration is consulted: keys are
  /// names without dashes, in the order they were first seen, and a value is
  /// `null` for a switch given without one. This is what [unknown] reads, and
  /// what a script inspecting an argument list it did not declare wants —
  /// reading a *declared* option is [Opt]'s job, and keeps the type.
  ///
  /// ```dart
  /// Cli(['-abc', 'x']).switches.keys;   // ('a', 'b', 'c')
  /// Cli(['--out=dist']).switches;       // {'out': 'dist'}
  /// ```
  Map<String, String?> get switches => {
    for (final name in _flags) name: _options[name],
  };

  /// The value the command line carried for [opt], under its name or alias.
  String? _value(Opt<Object?> opt) =>
      _options[opt.name] ?? (opt.alias == null ? null : _options[opt.alias!]);

  /// Whether [value] spells a true boolean.
  ///
  /// Accepts the words an environment variable or `.env` file is likely to
  /// carry, matching [EnvAccessor.get].
  static bool _truthy(String value) => switch (value.trim().toLowerCase()) {
    'true' || '1' || 'yes' || 'on' => true,
    _ => false,
  };

  /// The value of the environment variable this declaration names, if set.
  String? _fromEnv(_Decl? decl) {
    final key = decl?.env;
    if (key == null || !sharedEnv.has(key)) return null;
    final String value = sharedEnv.get(key, '');
    return value;
  }

  /// Validates the declared contract: required arguments and allowed values.
  ///
  /// Checks that [names] — or, by default, every option declared
  /// `required: true` — resolved to a value. A declared `def`, or an `env`
  /// variable that is set, counts as supplied. Every value that *was* given is
  /// also checked against its declaration's `allowed` list.
  ///
  /// Throws [ArgumentError] naming everything that failed.
  void require([Iterable<String>? names]) {
    final requiredNames =
        names ??
        _declarations.entries.where((e) => e.value.required).map((e) => e.key);

    final problems = <String>[
      for (final name in requiredNames)
        if (!_supplied(name)) 'missing --${_clean(name)}',
      ..._offending(),
    ];
    if (problems.isNotEmpty) {
      throw ArgumentError(problems.join(', '));
    }
  }

  /// Whether [name] resolved to a value from any source.
  ///
  /// For an option this means a *value*: `--out` with nothing after it parses
  /// as a bare switch, and satisfying `required` with it would leave the
  /// option reading its default for an argument the script was told it had. A
  /// flag is satisfied by its presence alone.
  bool _supplied(String name) {
    final clean = _clean(name);
    final decl = _decl(clean);
    final alias = _alias(name, null);
    final present =
        _flags.contains(clean) || (alias != null && _flags.contains(alias));
    if (decl?.flag ?? false) return present;
    if (decl?.def != null || _fromEnv(decl) != null) return true;
    if (_options.containsKey(clean)) return true;
    if (alias != null && _options.containsKey(alias)) return true;
    // Undeclared names have no shape to enforce; presence is all there is.
    return decl == null && present;
  }

  /// Descriptions of every given value its declaration disallows, and every
  /// one that is not the number its declaration says it is.
  ///
  /// A number that does not parse used to reach the script as the default,
  /// which is worse than refusing it: `--concurrency=fast` ran on four
  /// workers and said nothing.
  List<String> _offending() {
    final problems = <String>[];
    for (final entry in _declarations.entries) {
      final decl = entry.value;
      if (decl.flag) continue;
      final given = [
        ...?_repeated[entry.key],
        if (decl.alias != null) ...?_repeated[decl.alias!],
      ];
      for (final value in given) {
        final allowed = decl.allowed;
        if (allowed != null && !allowed.contains(value)) {
          problems.add(
            '--${entry.key} must be one of ${allowed.join(', ')} '
            '(got "$value")',
          );
          continue;
        }
        final wanted = switch (decl.shape) {
          _Shape.number when int.tryParse(value.trim()) == null => 'a number',
          _Shape.decimal when double.tryParse(value.trim()) == null =>
            'a number',
          _Shape.duration when const TimeAccessor().span(value) == null =>
            'a duration such as 30s, 5m or 1h30m',
          _Shape.date when const TimeAccessor().parse(value) == null =>
            'a date such as 2024-03-09',
          _ => null,
        };
        if (wanted != null) {
          problems.add('--${entry.key} must be $wanted (got "$value")');
        }
      }
    }
    return problems;
  }

  /// Every switch given on the command line that no declaration covers.
  ///
  /// A negative form counts as covered once its positive name is declared, so
  /// `--no-cache` is known as soon as `cache` is. Names come back without
  /// dashes, in the order they were given. Only meaningful once the interface
  /// is declared: with no declarations at all, every switch is unknown.
  List<String> unknown() {
    final known = <String>{
      for (final entry in _declarations.entries) ...[
        entry.key,
        if (entry.value.alias != null) entry.value.alias!,
      ],
    };
    return [
      for (final given in _flags)
        if (!known.contains(given) && !known.contains(_positive(given))) given,
    ];
  }

  /// [given] without a `no-` or `no` prefix, so `--no-cache` maps to `cache`.
  static String _positive(String given) {
    if (given.startsWith('no-')) return given.substring(3);
    if (given.startsWith('no')) return given.substring(2);
    return given;
  }

  /// Throws [ArgumentError] if any given switch was not declared.
  ///
  /// The cheapest way to catch a typo: without it `--verbse` parses happily as
  /// a flag nothing reads. See [unknown].
  void strict() {
    final extra = unknown();
    if (extra.isNotEmpty) {
      throw ArgumentError(
        'unknown argument(s): ${extra.map((e) => '--$e').join(', ')}',
      );
    }
  }

  /// First positional argument as a subcommand name, or `null`.
  String? get command => _rest.firstOrNull;

  /// Positional arguments, in order.
  ///
  /// Named `args` and not `list`, because [Cli.list] declares a repeated
  /// option and one name cannot mean both.
  ///
  /// Inside a handler [run] dispatched to, the command names have already
  /// been taken off, so this is the arguments *to that command* — which is
  /// what a `rest` would have meant and is why there is no longer one. `rest`
  /// stood beside this through 4.0.0 as `args` minus its first element, with
  /// nothing in either name saying which was which; it existed to serve
  /// `subcommand`, and that went with it. See [command] for reading the first
  /// positional as a name.
  List<String> get args => List.unmodifiable(_rest);

  // --------------------------------------------------------------------------
  // DISPATCH
  // --------------------------------------------------------------------------

  /// Resolves the command named by the positional arguments, runs it, and
  /// returns the exit code to leave the process with.
  ///
  /// In order: matches the deepest registered [handle] or [group], re-reads the
  /// remaining arguments against that command's declarations plus the global
  /// ones, then prints `--help` or `--version` if asked, applies [strict] and
  /// [require], and finally awaits the handler.
  ///
  /// The handler's return value becomes the exit code: `null` and `true` mean
  /// success, `false` means failure, and an `int` is used as given. A command
  /// line that could not be understood returns [usageExit] after printing the
  /// reason and the usage block. [body] runs when no subcommand matches, which
  /// is how a script with no commands at all still gets `--help` and
  /// validation.
  ///
  /// Only [ArgumentError] is caught, so a genuine failure inside a handler
  /// still reaches the caller with its stack trace intact.
  ///
  /// ```dart
  /// Future<int> build(Cli cli) async => 0;
  ///
  /// void main(List<String> args) async {
  ///   cli.handle('build', build, desc: 'Build the project');
  ///   await system.shutdown(await cli.run(args, version: '1.1.0'));
  /// }
  /// ```
  Future<int> run({
    String? syntax,
    String? desc,
    String? version,
    bool strict = false,
    FutureOr<int> Function(Cli cli)? body,
  }) async {
    final help = _declarations.containsKey('help')
        ? Opt<bool>._(
            'help',
            'h',
            false,
            this,
            (cli, self) => cli._readFlag(self),
          )
        : flag('help', alias: 'h', desc: 'Show this message');
    final showVersion = version == null
        ? null
        : (_declarations.containsKey('version')
              ? Opt<bool>._(
                  'version',
                  null,
                  false,
                  this,
                  (cli, self) => cli._readFlag(self),
                )
              : flag('version', desc: 'Show the version and exit'));

    final path = _resolve();
    final target = path.isEmpty ? null : path.last;
    final scoped = _scope(path);
    final program = _program(syntax);
    final line = [program, ...path.map((c) => c.name)].join(' ');
    final trailing = (target?._children.isNotEmpty ?? false)
        ? '<command> [options]'
        : '[options]';

    String text() => _usage(
      syntax: path.isEmpty
          ? (syntax ?? '$program <command> [options]')
          : '$line $trailing',
      desc: path.isEmpty ? desc : (target!.desc.isEmpty ? null : target.desc),
      declarations: scoped._declarations,
      children: (target?._children ?? _children),
    );

    if (help(scoped)) {
      stdout.writeln(text());
      return 0;
    }
    if (showVersion != null && showVersion(scoped)) {
      stdout.writeln(version!);
      return 0;
    }

    // A positional the command tree did not claim is a typo, not an argument,
    // whenever the command it would have run does not exist.
    final extra = scoped.args;
    if (target == null && _children.isNotEmpty && extra.isNotEmpty) {
      return _reject('unknown command: ${extra.first}', text());
    }
    if (target != null && target._children.isNotEmpty && extra.isNotEmpty) {
      return _reject(
        'unknown subcommand: ${line.split(' ').last} ${extra.first}',
        text(),
      );
    }

    try {
      if (strict) scoped.strict();
      scoped.require();
    } on ArgumentError catch (error) {
      return _reject(error.message.toString(), text());
    }

    final handler = target?.handler ?? (target == null ? body : null);
    if (handler == null) {
      // A group, or a bare invocation with nothing to run: show the way in.
      stdout.writeln(text());
      return 0;
    }

    // Options declared on this object, or on any command along the path, read
    // from the same scope the handler gets.
    _scopeInUse = scoped;
    for (final node in path) {
      node._scopeInUse = scoped;
    }
    try {
      return await handler(scoped);
    } on ArgumentError catch (error) {
      return _reject(error.message.toString(), text());
    } finally {
      _scopeInUse = null;
      for (final node in path) {
        node._scopeInUse = null;
      }
    }
  }

  /// Prints [reason] and [usage] to stderr and returns [usageExit].
  int _reject(String reason, String usage) {
    stderr
      ..writeln('error: $reason')
      ..writeln()
      ..writeln(usage);
    return usageExit;
  }

  /// The deepest chain of registered commands the positionals spell out.
  List<Command> _resolve() {
    final path = <Command>[];
    var level = _children;
    for (final positional in _rest) {
      final match = level[positional];
      if (match == null) break;
      path.add(match);
      level = match._children;
    }
    return path;
  }

  /// The arguments with [path]'s command names removed, re-read against the
  /// global declarations plus every declaration along [path].
  Cli _scope(List<Command> path) {
    if (path.isEmpty) {
      final root = Cli(raw);
      root._declarations.addAll(_declarations);
      root._parse();
      return root;
    }
    final consumed = _restAt.take(path.length).toSet();
    final scoped = Cli([
      for (var i = 0; i < raw.length; i++)
        if (!consumed.contains(i)) raw[i],
    ]);
    scoped._declarations.addAll(_declarations);
    for (final node in path) {
      scoped._declarations.addAll(node._declarations);
    }
    scoped._parse();
    return scoped;
  }

  /// The name to print in usage lines: the first word of [syntax] if given,
  /// else the script's own filename.
  static String _program(String? syntax) {
    final given = syntax?.trim().split(' ').first;
    if (given != null && given.isNotEmpty) return given;
    final path = Platform.script.pathSegments;
    return path.isEmpty ? 'program' : path.last;
  }

  // --------------------------------------------------------------------------
  // HELP
  // --------------------------------------------------------------------------

  /// Generates a formatted usage block string.
  ///
  /// If [flags] or [options] are omitted, formats declared flags and options,
  /// along with any commands registered through [handle] or [group].
  String usage({
    String? syntax,
    String? desc,
    Map<String, String>? flags,
    Map<String, String>? options,
  }) => _usage(
    syntax: syntax,
    desc: desc,
    declarations: flags == null && options == null ? _declarations : const {},
    children: _children,
    flags: flags,
    options: options,
  );

  /// Prints a usage block to stdout.
  void help({
    String? syntax,
    String? desc,
    Map<String, String>? flags,
    Map<String, String>? options,
  }) {
    stdout.writeln(
      usage(syntax: syntax, desc: desc, flags: flags, options: options),
    );
  }
}

/// One subcommand in a command tree, created by [Cli.handle].
///
/// Declare its own flags and options on it; they are read alongside the global
/// ones when the command runs.
///
/// ```dart
/// cli.handle('build', build, desc: 'Build the project')
///   ..option('out', alias: 'o', def: 'dist', desc: 'Output directory')
///   ..flag('release', desc: 'Optimise the output');
/// ```
class Command with _Spec {
  Command._(this.name, this.desc, this.handler);

  /// The word that selects this command.
  final String name;

  /// The one-line description shown in usage blocks.
  final String desc;

  /// What runs when this command is selected, or `null` for a [group].
  final FutureOr<int> Function(Cli cli)? handler;

  /// The scope [Cli.run] built for this command, while it is running.
  Cli? _scopeInUse;

  @override
  Cli get _reader {
    final scope = _scopeInUse;
    if (scope == null) {
      throw StateError(
        'The command "$name" is not running, so its options have nothing to '
        'read. Read them inside its handler, or pass the Cli the handler was '
        'given: out(cli).',
      );
    }
    return scope;
  }
}

// ============================================================================
// USAGE FORMATTING
// ============================================================================

/// Renders a usage block, wrapped to the terminal.
String _usage({
  String? syntax,
  String? desc,
  Map<String, _Decl> declarations = const {},
  Map<String, Command> children = const {},
  Map<String, String>? flags,
  Map<String, String>? options,
}) {
  final flagEntries = <String, String>{...?flags};
  final optionEntries = <String, String>{...?options};
  final commandEntries = <String, String>{};

  for (final entry in declarations.entries) {
    final name = entry.key;
    final decl = entry.value;
    final label = '${decl.alias != null ? '-${decl.alias}, ' : '    '}--$name';
    if (decl.flag) {
      final def = decl.def == true ? ' [default: true]' : '';
      flagEntries[label] = '${decl.desc}$def';
      continue;
    }
    // `required` is only worth printing when nothing else can supply a value.
    final required = decl.required && decl.def == null ? ' (required)' : '';
    final def = decl.def != null ? ' [default: ${decl.def}]' : '';
    final env = decl.env != null ? ' [env: ${decl.env}]' : '';
    final allowed = decl.allowed != null ? ' (${decl.allowed!.join('|')})' : '';
    optionEntries['$label <value>'] = '${decl.desc}$allowed$required$env$def';
  }
  for (final child in children.values) {
    commandEntries[child.name] = child.desc;
  }

  final buffer = StringBuffer();
  final width = ConsoleWriter().width.clamp(40, 100);
  if (desc != null && desc.isNotEmpty) buffer.writeln('$desc\n');
  if (syntax != null && syntax.isNotEmpty) buffer.writeln('Usage: $syntax\n');

  final labels = [
    ...commandEntries.keys,
    ...flagEntries.keys,
    ...optionEntries.keys,
  ];
  final column = labels.isEmpty
      ? 24
      : labels.map(Ansi.width).reduce((a, b) => a > b ? a : b).clamp(12, 34);

  void section(String title, Map<String, String> entries) {
    if (entries.isEmpty) return;
    buffer.writeln('$title:');
    entries.forEach((label, text) {
      final lines = _wrap(text.trim(), width - column - 4);
      buffer.writeln('  ${label.padRight(column)}  ${lines.first}'.trimRight());
      for (final line in lines.skip(1)) {
        buffer.writeln('  ${' ' * column}  $line');
      }
    });
    buffer.writeln();
  }

  section('Commands', commandEntries);
  section('Flags', flagEntries);
  section('Options', optionEntries);
  return buffer.toString().trimRight();
}

/// Splits [text] into lines of at most [width] columns, breaking on spaces.
///
/// Measured with [Ansi.width] rather than by code units, the way every other
/// box this library draws is: a CJK ideograph is one code unit and two
/// columns, an emoji is two code units and two columns, and a `desc:` holding
/// either wrapped past the edge of the terminal it was being wrapped for.
List<String> _wrap(String text, int width) {
  if (text.isEmpty) return const [''];
  if (width < 8) return [text];
  final lines = <String>[];
  var line = '';
  var columns = 0;
  for (final word in text.split(' ')) {
    final wordWidth = Ansi.width(word);
    if (line.isEmpty) {
      line = word;
      columns = wordWidth;
    } else if (columns + 1 + wordWidth <= width) {
      line = '$line $word';
      columns += 1 + wordWidth;
    } else {
      lines.add(line);
      line = word;
      columns = wordWidth;
    }
  }
  if (line.isNotEmpty) lines.add(line);
  return lines;
}
