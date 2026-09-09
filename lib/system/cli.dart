/// # CLI Arguments (`system.cli.*`)
///
/// A dependency-free parser for the flag shapes scripts actually use:
/// `--flag`, `--key=value`, `--key value`, `-k value`, `-abc`, `--no-key`,
/// repeated options, and trailing positional arguments.
///
/// Two ways in. Declare an interface and read it yourself:
///
/// ```dart
/// system.cli
///   ..flag('force', alias: 'f')
///   ..parse(args);
/// ```
///
/// Or declare commands and let [CliAccessor.run] parse, validate, print
/// `--help` and pick the handler:
///
/// ```dart
/// void main(List<String> args) async {
///   system.cli.handle('build', _build, desc: 'Build the project')
///     ..option('out', alias: 'o', def: 'dist', desc: 'Output directory');
///   await system.shutdown(await system.cli.run(args));
/// }
/// ```
library;

import 'dart:async';
import 'dart:io';

import '../src/shared.dart';
import 'console/terminal.dart';

// ============================================================================
// CLI ARGUMENT PARSER (system.cli.*)
// ============================================================================

/// One declared flag or option.
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
  });

  final String? alias;
  final String desc;
  final Object? def;
  final bool flag;
  final bool required;
  final List<String>? allowed;
  final String? env;
  final bool csv;
}

/// Declaring an interface: the half of the API shared by [Cli], [Command] and
/// [CliAccessor].
///
/// [T] is the implementing type, so every declaration returns the receiver and
/// cascades read the same on all three.
mixin _Spec<T> {
  final Map<String, _Decl> _declarations = {};
  final Map<String, Command> _children = {};

  T get _self;

  /// Called after a declaration changes, so [Cli] can re-read its arguments.
  void _changed() {}

  /// Declares a boolean flag.
  ///
  /// A flag never consumes the token after it, so `--verbose main.dart` leaves
  /// `main.dart` a positional argument. [def] is the value [Cli.get] reports
  /// when the flag is absent; leave it unset to fall back to the call site.
  T flag(String name, {String? alias, String desc = '', bool? def}) {
    _declarations[Cli._clean(name)] = _Decl(
      alias: alias == null ? null : Cli._clean(alias),
      desc: desc,
      def: def,
      flag: true,
    );
    _changed();
    return _self;
  }

  /// Declares an option with a value.
  ///
  /// [def] is used by [Cli.get] and satisfies [Cli.require], so a default is
  /// written once here instead of at every call site. [env] names an
  /// environment variable to read when the option is absent, which also
  /// satisfies [Cli.require]. [allowed] limits the accepted values, and [csv]
  /// splits one comma-separated value into repeated ones for [Cli.all].
  ///
  /// Values resolve in that order: the command line, then [env], then [def].
  T option(
    String name, {
    String? alias,
    String desc = '',
    Object? def,
    bool required = false,
    List<String>? allowed,
    String? env,
    bool csv = false,
  }) {
    _declarations[Cli._clean(name)] = _Decl(
      alias: alias == null ? null : Cli._clean(alias),
      desc: desc,
      def: def,
      required: required,
      allowed: allowed,
      env: env,
      csv: csv,
    );
    _changed();
    return _self;
  }

  /// Registers [name] as a subcommand run by [handler], returning it so that
  /// its own flags and options can be declared on the spot.
  ///
  /// ```dart
  /// system.cli.handle('build', _build, desc: 'Build the project')
  ///   ..flag('release', desc: 'Optimise the output')
  ///   ..option('out', alias: 'o', def: 'dist');
  /// ```
  ///
  /// The handler's return value becomes the exit code — see [Cli.run].
  Command handle(
    String name,
    FutureOr<Object?> Function(Cli cli) handler, {
    String desc = '',
  }) => _register(name, desc, handler);

  /// Registers [name] as a group of subcommands, returning it to nest under.
  ///
  /// Naming a group without one of its subcommands prints its usage block.
  ///
  /// ```dart
  /// final remote = system.cli.group('remote', desc: 'Manage remotes');
  /// remote.handle('add', _add, desc: 'Add a remote');
  /// remote.handle('rm', _remove, desc: 'Remove a remote');
  /// ```
  Command group(String name, {String desc = ''}) => _register(name, desc, null);

  Command _register(
    String name,
    String desc,
    FutureOr<Object?> Function(Cli cli)? handler,
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

/// Entry point for command-line arguments, reachable as `system.cli`.
///
/// Declare the interface, then either [parse] it and read the values yourself
/// or hand [run] the arguments and let it dispatch.
///
/// ```dart
/// void main(List<String> args) {
///   system.cli.parse(args);
///   final force = system.cli.has('force', 'f');
///   final size = system.cli.get('concurrency', 4);
/// }
/// ```
class CliAccessor with _Spec<CliAccessor> {
  Cli _parsed = Cli(const []);

  /// Creates the accessor. Prefer the shared `system.cli` instance.
  CliAccessor();

  @override
  CliAccessor get _self => this;

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
    FutureOr<Object?> Function(Cli cli)? body,
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

  /// Positional arguments following the subcommand.
  List<String> get rest => _parsed.rest;

  /// Dispatches execution to [handler] if [command] equals [name].
  bool subcommand(String name, void Function(Cli cli) handler) =>
      _parsed.subcommand(name, handler);

  /// Whether [name] (or its short [alias]) was given as a flag or an option.
  bool has(String name, [String? alias]) => _parsed.has(name, alias);

  /// Reads [name] as [T], falling back to [fallback].
  T get<T>(String name, T fallback, [String? alias]) =>
      _parsed.get<T>(name, fallback, alias);

  /// Every value given for a repeated option.
  List<T> all<T>(String name, [String? alias]) => _parsed.all<T>(name, alias);

  /// Whether `--no-[name]` was given.
  bool no(String name) => _parsed.no(name);

  /// Positional arguments, in order.
  List<String> list() => _parsed.list();

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
/// Normally reached through `system.cli`; construct one directly to parse an
/// argument list other than the program's own.
///
/// Declare the interface with [flag] and [option] before reading it. Declaring
/// is what lets the parser tell `--verbose main.dart` — a flag and a
/// positional — from `--out dist`, an option and its value; an *undeclared*
/// switch followed by a bare word takes that word as its value. [strict]
/// rejects switches that no declaration covers.
class Cli with _Spec<Cli> {
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
  final List<String> _rest = [];
  final List<int> _restAt = [];

  /// Parses the given argument list, exposed as [raw].
  Cli(this.raw) {
    _parse();
  }

  @override
  Cli get _self => this;

  @override
  void _changed() => _parse();

  void _parse() {
    _options.clear();
    _repeated.clear();
    _flags.clear();
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
        _flags.add(cleanKey);
        continue;
      }

      // `--key value`, but only when the next token is not itself a switch.
      if (i + 1 < raw.length && _isValue(raw[i + 1])) {
        _option(cleanKey, raw[i + 1]);
        i++;
        continue;
      }
      _flags.add(cleanKey);
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
        _flags.add(short);
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
      _flags.add(short);
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
    final values =
        (_decl(cleanKey)?.csv ?? false)
            ? value.split(',').map((v) => v.trim()).where((v) => v.isNotEmpty)
            : [value];
    _options[cleanKey] = values.isEmpty ? value : values.last;
    _repeated.putIfAbsent(cleanKey, () => []).addAll(values);
    _flags.add(cleanKey);
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

  /// Whether [name] (or its short [alias]) was given.
  ///
  /// [alias] defaults to the one declared with [flag] or [option].
  ///
  /// This asks only what the command line carried: a value reached through
  /// `env` or `def` does not make it true, though either satisfies [require].
  ///
  /// `--no-force` does *not* make `has('force')` true; test for it with [no],
  /// or read a tri-state value with `get<bool>`.
  bool has(String name, [String? alias]) {
    final short = _alias(name, alias);
    return _flags.contains(_clean(name)) ||
        (short != null && _flags.contains(short));
  }

  /// Whether `--no-[name]` (or `--no[name]`) was given.
  bool no(String name) {
    final clean = _clean(name);
    return _flags.contains('no-$clean') || _flags.contains('no$clean');
  }

  /// Every value given for a repeated option, parsed as [T].
  ///
  /// [T] may be `String`, `int` or `double`. Unparseable values are skipped.
  /// An option declared with `csv: true` contributes each comma-separated
  /// part, so `--tag a,b` and `--tag a --tag b` read the same.
  List<T> all<T>(String name, [String? alias]) {
    final short = _alias(name, alias);
    final values = [
      ...?_repeated[_clean(name)],
      if (short != null) ...?_repeated[short],
    ];
    return switch (T) {
      const (int) => values.map(int.tryParse).whereType<T>().toList(),
      const (double) => values.map(double.tryParse).whereType<T>().toList(),
      _ => values.cast<T>(),
    };
  }

  /// Reads [name] (or its short [alias]) as [T], falling back to [fallback].
  ///
  /// Sources are tried in order: the command line, the `env` variable named in
  /// the declaration, the declared `def`, then [fallback] — which is required,
  /// so the result is never null and never needs an explicit type argument.
  ///
  /// For `bool`, an explicit `--no-[name]` yields `false`, a bare `--[name]`
  /// yields `true`, and `--[name]=true|1` is honoured.
  ///
  /// ```dart
  /// system.cli.get('concurrency', 4); // int
  /// system.cli.get('name', '');       // String
  /// ```
  T get<T>(String name, T fallback, [String? alias]) {
    final clean = _clean(name);
    final cleanAlias = _alias(name, alias);
    final given =
        _options[clean] ?? (cleanAlias == null ? null : _options[cleanAlias]);
    final decl = _decl(clean);

    if (T == bool || fallback is bool) {
      if (no(clean) || (cleanAlias != null && no(cleanAlias))) {
        return false as T;
      }
      if (given != null) return (given == 'true' || given == '1') as T;
      if (_flags.contains(clean) ||
          (cleanAlias != null && _flags.contains(cleanAlias))) {
        return true as T;
      }
      final def = decl?.def ?? _fromEnv(decl);
      return def is T ? def : fallback;
    }

    final raw = given ?? _fromEnv(decl) ?? decl?.def;
    if (raw == null) return fallback;
    if (raw is T) return raw as T;
    final text = raw.toString();
    return switch (T) {
      const (int) => (int.tryParse(text) ?? fallback) as T,
      const (double) => (double.tryParse(text) ?? fallback) as T,
      _ => text as T,
    };
  }

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
  bool _supplied(String name) {
    final decl = _decl(_clean(name));
    return has(name, decl?.alias) ||
        decl?.def != null ||
        _fromEnv(decl) != null;
  }

  /// Descriptions of every given value that its declaration disallows.
  List<String> _offending() {
    final problems = <String>[];
    for (final entry in _declarations.entries) {
      final allowed = entry.value.allowed;
      if (allowed == null) continue;
      for (final value in all<String>(entry.key)) {
        if (allowed.contains(value)) continue;
        problems.add(
          '--${entry.key} must be one of ${allowed.join(', ')} '
          '(got "$value")',
        );
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

  /// Positional arguments following the subcommand.
  List<String> get rest =>
      _rest.length > 1 ? List.unmodifiable(_rest.sublist(1)) : const [];

  /// Dispatches execution to [handler] if [command] equals [name].
  ///
  /// The primitive behind [run], for scripts that would rather branch by hand.
  /// [run] adds nesting, per-command options, `--help` and exit codes.
  bool subcommand(String name, void Function(Cli cli) handler) {
    if (command == name) {
      handler(this);
      return true;
    }
    return false;
  }

  /// Positional arguments, in order.
  List<String> list() => List.unmodifiable(_rest);

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
  /// void main(List<String> args) async {
  ///   system.cli.handle('build', _build, desc: 'Build the project');
  ///   await system.shutdown(await system.cli.run(args, version: '1.1.0'));
  /// }
  /// ```
  Future<int> run({
    String? syntax,
    String? desc,
    String? version,
    bool strict = false,
    FutureOr<Object?> Function(Cli cli)? body,
  }) async {
    if (!_declarations.containsKey('help')) {
      flag('help', alias: 'h', desc: 'Show this message');
    }
    if (version != null && !_declarations.containsKey('version')) {
      flag('version', desc: 'Show the version and exit');
    }

    final path = _resolve();
    final target = path.isEmpty ? null : path.last;
    final scoped = _scope(path);
    final program = _program(syntax);
    final line = [program, ...path.map((c) => c.name)].join(' ');
    final trailing =
        (target?._children.isNotEmpty ?? false)
            ? '<command> [options]'
            : '[options]';

    String text() => _usage(
      syntax:
          path.isEmpty
              ? (syntax ?? '$program <command> [options]')
              : '$line $trailing',
      desc: path.isEmpty ? desc : (target!.desc.isEmpty ? null : target.desc),
      declarations: scoped._declarations,
      children: (target?._children ?? _children),
    );

    if (scoped.get('help', false)) {
      stdout.writeln(text());
      return 0;
    }
    if (version != null && scoped.get('version', false)) {
      stdout.writeln(version);
      return 0;
    }

    // A positional the command tree did not claim is a typo, not an argument,
    // whenever the command it would have run does not exist.
    final extra = scoped.list();
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

    try {
      return _code(await handler(scoped));
    } on ArgumentError catch (error) {
      return _reject(error.message.toString(), text());
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

  static int _code(Object? result) => switch (result) {
    null => 0,
    final int code => code,
    final bool ok => ok ? 0 : 1,
    _ => 0,
  };

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
/// system.cli.handle('build', _build, desc: 'Build the project')
///   ..option('out', alias: 'o', def: 'dist', desc: 'Output directory')
///   ..flag('release', desc: 'Optimise the output');
/// ```
class Command with _Spec<Command> {
  Command._(this.name, this.desc, this.handler);

  /// The word that selects this command.
  final String name;

  /// The one-line description shown in usage blocks.
  final String desc;

  /// What runs when this command is selected, or `null` for a [group].
  final FutureOr<Object?> Function(Cli cli)? handler;

  @override
  Command get _self => this;
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
  final width = const Terminal().width.clamp(40, 100);
  if (desc != null && desc.isNotEmpty) buffer.writeln('$desc\n');
  if (syntax != null && syntax.isNotEmpty) buffer.writeln('Usage: $syntax\n');

  final labels = [
    ...commandEntries.keys,
    ...flagEntries.keys,
    ...optionEntries.keys,
  ];
  final column =
      labels.isEmpty
          ? 24
          : labels
              .map((l) => l.length)
              .reduce((a, b) => a > b ? a : b)
              .clamp(12, 34);

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

/// Splits [text] into lines of at most [width] characters, breaking on spaces.
List<String> _wrap(String text, int width) {
  if (text.isEmpty) return const [''];
  if (width < 8) return [text];
  final lines = <String>[];
  var line = '';
  for (final word in text.split(' ')) {
    if (line.isEmpty) {
      line = word;
    } else if (line.length + 1 + word.length <= width) {
      line = '$line $word';
    } else {
      lines.add(line);
      line = word;
    }
  }
  if (line.isNotEmpty) lines.add(line);
  return lines;
}
