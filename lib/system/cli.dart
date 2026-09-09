/// # CLI Arguments (`system.cli.*`)
///
/// A dependency-free parser for the flag shapes scripts actually use:
/// `--flag`, `--key=value`, `--key value`, `-k value`, `--no-key`, repeated
/// options, and trailing positional arguments.
library;

import 'dart:io';

// ============================================================================
// CLI ARGUMENT PARSER (system.cli.*)
// ============================================================================

/// Entry point for command-line arguments, reachable as `system.cli`.
///
/// Call [parse] with your `main` arguments before reading anything; until then
/// the accessor reports an empty command line.
///
/// ```dart
/// void main(List<String> args) {
///   system.cli.parse(args);
///   final force = system.cli.has('force', 'f');
///   final size = system.cli.get('concurrency', 4);
/// }
/// ```
class CliAccessor {
  final Map<
    String,
    ({String? alias, String desc, Object? def, bool flag, bool required})
  >
  _declarations = {};
  Cli _parsed = Cli(const []);

  /// Creates the accessor. Prefer the shared `system.cli` instance.
  CliAccessor();

  /// Parses [args], replacing any previously parsed command line.
  void parse(List<String> args) {
    _parsed = Cli(args);
    _parsed._declarations.addAll(_declarations);
  }

  /// Declares a boolean flag.
  CliAccessor flag(
    String name, {
    String? alias,
    String desc = '',
    bool def = false,
  }) {
    _declarations[Cli._clean(name)] = (
      alias: alias == null ? null : Cli._clean(alias),
      desc: desc,
      def: def,
      flag: true,
      required: false,
    );
    _parsed.flag(name, alias: alias, desc: desc, def: def);
    return this;
  }

  /// Declares an option with a value.
  CliAccessor option(
    String name, {
    String? alias,
    String desc = '',
    Object? def,
    bool required = false,
  }) {
    _declarations[Cli._clean(name)] = (
      alias: alias == null ? null : Cli._clean(alias),
      desc: desc,
      def: def,
      flag: false,
      required: required,
    );
    _parsed.option(
      name,
      alias: alias,
      desc: desc,
      def: def,
      required: required,
    );
    return this;
  }

  /// Validates that [names] (or all declared required options) were supplied.
  void require([Iterable<String>? names]) => _parsed.require(names);

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
class Cli {
  /// The raw arguments this instance parsed.
  final List<String> raw;

  final Map<String, String> _options = {};
  final Map<String, List<String>> _repeated = {};
  final Set<String> _flags = {};
  final List<String> _rest = [];

  /// Parses the given argument list, exposed as [raw].
  Cli(this.raw) {
    _parse();
  }

  void _parse() {
    _options.clear();
    _repeated.clear();
    _flags.clear();
    _rest.clear();

    for (var i = 0; i < raw.length; i++) {
      final arg = raw[i];
      if (arg == '--') {
        _rest.addAll(raw.sublist(i + 1));
        break;
      }

      final isLong = arg.startsWith('--');
      final isShort = !isLong && arg.startsWith('-') && arg.length > 1;
      if (!isLong && !isShort) {
        _rest.add(arg);
        continue;
      }

      final token = arg.substring(isLong ? 2 : 1);
      final split = token.indexOf('=');
      final key = split != -1 ? token.substring(0, split) : token;
      final cleanKey = _clean(key);
      final decl =
          _declarations[cleanKey] ??
          _declarations.values.where((d) => d.alias == cleanKey).firstOrNull;

      if (split != -1) {
        _option(cleanKey, token.substring(split + 1));
        continue;
      }

      // If declared as a flag, do not consume the next token as a value.
      if (decl != null && decl.flag) {
        _flags.add(cleanKey);
        continue;
      }

      // `--key value`, but only when the next token is not itself a switch.
      if (i + 1 < raw.length) {
        final next = raw[i + 1];
        final isNum = num.tryParse(next) != null;
        if (!next.startsWith('-') || isNum || next == '-') {
          _option(cleanKey, next);
          i++;
          continue;
        }
      }
      _flags.add(cleanKey);
    }
  }

  void _option(String key, String value) {
    final cleanKey = _clean(key);
    _options[cleanKey] = value;
    _repeated.putIfAbsent(cleanKey, () => []).add(value);
    _flags.add(cleanKey);
  }

  static String _clean(String name) => name.replaceFirst(RegExp(r'^-+'), '');

  /// The alias to use for [name]: the one passed in, else the one declared.
  ///
  /// So an alias given once to [flag] or [option] is honoured by every later
  /// lookup, instead of having to be repeated at each call site.
  String? _alias(String name, String? explicit) {
    if (explicit != null) return _clean(explicit);
    return _declarations[_clean(name)]?.alias;
  }

  /// Whether [name] (or its short [alias]) was given.
  ///
  /// [alias] defaults to the one declared with [flag] or [option].
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
  /// [T] is inferred from [fallback], which is required so the result is never
  /// null. For `bool`, an explicit `--no-[name]` yields `false`, a bare
  /// `--[name]` yields `true`, and `--[name]=true|1` is honoured.
  ///
  /// ```dart
  /// system.cli.get('concurrency', 4); // int
  /// system.cli.get('name', '');       // String
  /// ```
  T get<T>(String name, T fallback, [String? alias]) {
    final clean = _clean(name);
    final cleanAlias = _alias(name, alias);
    final raw =
        _options[clean] ?? (cleanAlias == null ? null : _options[cleanAlias]);

    if (T == bool || fallback is bool) {
      if (no(clean) || (cleanAlias != null && no(cleanAlias))) {
        return false as T;
      }
      if (raw != null) return (raw == 'true' || raw == '1') as T;
      if (_flags.contains(clean) ||
          (cleanAlias != null && _flags.contains(cleanAlias))) {
        return true as T;
      }
      return fallback;
    }

    if (raw == null) return fallback;
    return switch (T) {
      const (int) => (int.tryParse(raw) ?? fallback) as T,
      const (double) => (double.tryParse(raw) ?? fallback) as T,
      _ => raw as T,
    };
  }

  final Map<
    String,
    ({String? alias, String desc, Object? def, bool flag, bool required})
  >
  _declarations = {};

  /// Declares a boolean flag.
  Cli flag(String name, {String? alias, String desc = '', bool def = false}) {
    _declarations[_clean(name)] = (
      alias: alias == null ? null : _clean(alias),
      desc: desc,
      def: def,
      flag: true,
      required: false,
    );
    _parse();
    return this;
  }

  /// Declares an option with a value.
  Cli option(
    String name, {
    String? alias,
    String desc = '',
    Object? def,
    bool required = false,
  }) {
    _declarations[_clean(name)] = (
      alias: alias == null ? null : _clean(alias),
      desc: desc,
      def: def,
      flag: false,
      required: required,
    );
    _parse();
    return this;
  }

  /// Validates that [names] (or all declared required options) were supplied.
  ///
  /// Throws [ArgumentError] if any required argument is missing.
  void require([Iterable<String>? names]) {
    final requiredNames =
        names ??
        _declarations.entries.where((e) => e.value.required).map((e) => e.key);

    final missing = [
      for (final name in requiredNames)
        if (!has(name, _declarations[_clean(name)]?.alias)) name,
    ];
    if (missing.isNotEmpty) {
      throw ArgumentError(
        'Missing required argument(s): ${missing.map((m) => '--$m').join(', ')}',
      );
    }
  }

  /// First positional argument as a subcommand name, or `null`.
  String? get command => _rest.firstOrNull;

  /// Positional arguments following the subcommand.
  List<String> get rest =>
      _rest.length > 1 ? List.unmodifiable(_rest.sublist(1)) : const [];

  /// Dispatches execution to [handler] if [command] equals [name].
  bool subcommand(String name, void Function(Cli cli) handler) {
    if (command == name) {
      handler(this);
      return true;
    }
    return false;
  }

  /// Positional arguments, in order.
  List<String> list() => List.unmodifiable(_rest);

  /// Generates a formatted usage block string.
  ///
  /// If [flags] or [options] are omitted, formats declared flags and options.
  String usage({
    String? syntax,
    String? desc,
    Map<String, String>? flags,
    Map<String, String>? options,
  }) {
    final buffer = StringBuffer();
    if (desc != null && desc.isNotEmpty) buffer.writeln('$desc\n');
    if (syntax != null && syntax.isNotEmpty) buffer.writeln('Usage: $syntax\n');

    final flagEntries =
        flags != null ? Map<String, String>.from(flags) : <String, String>{};
    final optionEntries =
        options != null
            ? Map<String, String>.from(options)
            : <String, String>{};

    if (flags == null && options == null && _declarations.isNotEmpty) {
      for (final entry in _declarations.entries) {
        final name = entry.key;
        final decl = entry.value;
        final aliasStr = decl.alias != null ? '-${decl.alias}, ' : '    ';
        if (decl.flag) {
          flagEntries['$aliasStr--$name'] = decl.desc;
        } else {
          final reqStr = decl.required ? ' (required)' : '';
          final defStr = decl.def != null ? ' [default: ${decl.def}]' : '';
          optionEntries['$aliasStr--$name <value>'] =
              '${decl.desc}$reqStr$defStr';
        }
      }
    }

    void section(String title, Map<String, String> entries) {
      if (entries.isEmpty) return;
      buffer.writeln('$title:');
      entries.forEach((k, v) => buffer.writeln('  ${k.padRight(24)} $v'));
      buffer.writeln();
    }

    section('Flags', flagEntries);
    section('Options', optionEntries);
    return buffer.toString().trimRight();
  }

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
