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

part 'opt.dart';
part 'spec.dart';
part 'parse.dart';
part 'usage.dart';

// ============================================================================
// CLI DOMAIN (cli.*) - Argument Parsing
// ============================================================================

/// A clean, fluent command-line argument parser.
class CliParser {
  final CliAccessor _cli;
  final Map<String, Opt<dynamic>> _options = {};

  /// The syntax line shown in usage help.
  final String? syntax;

  /// The description shown in usage help.
  final String? description;

  /// Creates a new argument parser.
  CliParser({this.syntax, this.description}) : _cli = CliAccessor.isolated();

  /// Declares a boolean flag (e.g. `--force` or `-f`).
  Opt<bool> flag(
    String name, {
    String? abbr,
    String? alias,
    String? desc,
    String? help,
    bool? def,
    bool? defaultsTo,
  }) {
    final opt = _cli.flag(
      name,
      alias: abbr ?? alias,
      desc: help ?? desc ?? '',
      def: defaultsTo ?? def ?? false,
    );
    _options[name] = opt;
    if (abbr != null) _options[abbr] = opt;
    if (alias != null) _options[alias] = opt;
    return opt;
  }

  /// Declares a string option (e.g. `--out <value>`).
  Opt<String> option(
    String name, {
    String? abbr,
    String? alias,
    String? desc,
    String? help,
    String? def,
    String? defaultsTo,
  }) {
    final opt = _cli.option(
      name,
      alias: abbr ?? alias,
      desc: help ?? desc ?? '',
      def: defaultsTo ?? def ?? '',
    );
    _options[name] = opt;
    if (abbr != null) _options[abbr] = opt;
    if (alias != null) _options[alias] = opt;
    return opt;
  }

  /// Declares a numeric option (e.g. `--concurrency <num>`).
  Opt<int> number(
    String name, {
    String? abbr,
    String? alias,
    String? desc,
    String? help,
    num? def,
    num? defaultsTo,
  }) {
    final opt = _cli.number(
      name,
      alias: abbr ?? alias,
      desc: help ?? desc ?? '',
      def: ((defaultsTo ?? def) ?? 0).toInt(),
    );
    _options[name] = opt;
    if (abbr != null) _options[abbr] = opt;
    if (alias != null) _options[alias] = opt;
    return opt;
  }

  /// Declares an option that collects multiple occurrences.
  Opt<List<String>> list(
    String name, {
    String? abbr,
    String? alias,
    String? desc,
    String? help,
    bool csv = true,
    bool splitCommas = true,
  }) {
    final opt = _cli.list(
      name,
      alias: abbr ?? alias,
      desc: help ?? desc ?? '',
      csv: csv || splitCommas,
    );
    _options[name] = opt;
    if (abbr != null) _options[abbr] = opt;
    if (alias != null) _options[alias] = opt;
    return opt;
  }

  /// Declares an option restricted to one of [choices].
  Opt<String> choose(
    String name,
    Iterable<String> choices, {
    String? abbr,
    String? alias,
    String? desc,
    String? help,
    String? def,
    String? defaultsTo,
  }) {
    final opt = _cli.choose(
      name,
      choices.toList(),
      alias: abbr ?? alias,
      desc: help ?? desc ?? '',
      def: defaultsTo ?? def ?? choices.first,
    );
    _options[name] = opt;
    if (abbr != null) _options[abbr] = opt;
    if (alias != null) _options[alias] = opt;
    return opt;
  }

  /// Parses [args] and returns the parsed [ParsedCli] object.
  ParsedCli parse(List<String> args, {bool autoHelp = false}) {
    _cli.parse(args, autoHelp: autoHelp, syntax: syntax, desc: description);
    return ParsedCli(_cli.parsed, Map.unmodifiable(_options));
  }

  /// Generates usage text for the declared arguments.
  String usage() => _cli.usage(syntax: syntax, desc: description);

  /// Prints usage help to stdout.
  void printUsage() {
    stdout.writeln(usage());
  }
}

/// The result of parsing arguments with [CliParser].
class ParsedCli {
  final Cli _cli;
  final Map<String, Opt<dynamic>> _options;

  /// Creates a parsed CLI result wrapper around [_cli].
  const ParsedCli(this._cli, [this._options = const {}]);

  /// Reads a boolean flag value by [name].
  bool flag(String name) {
    final opt = _options[name];
    if (opt is Opt<bool>) return opt();
    return _cli.flag(name)();
  }

  /// Reads a string option value by [name].
  String option(String name) {
    final opt = _options[name];
    if (opt is Opt<String>) return opt();
    return _cli.option(name)();
  }

  /// Reads an integer option value by [name].
  int number(String name) {
    final opt = _options[name];
    if (opt is Opt<int>) return opt();
    return _cli.number(name)();
  }

  /// Reads a list option value by [name].
  List<String> list(String name) {
    final opt = _options[name];
    if (opt is Opt<List<String>>) return opt();
    return _cli.list(name)();
  }

  /// Positional rest arguments.
  List<String> get rest => _cli.args;

  /// Positional rest arguments.
  List<String> get args => _cli.args;

  /// Every switch the parser saw, declared or not.
  Map<String, String?> get switches => _cli.switches;

  /// The first positional argument as a subcommand name, or null.
  String? get command => _cli.command;

  /// The raw argument list as parsed.
  List<String> get raw => _cli.raw;

  /// The raw underlying [Cli] instance.
  Cli get rawCli => _cli;
}

/// Entry point for command-line arguments, reachable as `cli`.
final CliAccessor cli = CliAccessor();

/// Accessor for command-line arguments.
class CliAccessor with _Spec {
  Cli _parsed = Cli(const []);

  /// Creates the accessor. Prefer the shared [cli] instance.
  CliAccessor();

  /// Creates a fresh, isolated [CliAccessor] instance independent of the shared [cli] singleton.
  static CliAccessor isolated() => CliAccessor();

  /// Resets all declarations, subcommands, and parsed state.
  ///
  /// Useful in tests to prevent registered flags and options from leaking
  /// across test cases.
  void reset() {
    _declarations.clear();
    _children.clear();
    _parsed = Cli(const []);
  }

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
  ///
  /// When [autoHelp] is true, registers `-h`/`--help` if not already declared,
  /// and if present in [args], prints usage and exits with code 0.
  void parse(
    List<String> args, {
    bool autoHelp = false,
    String? syntax,
    String? desc,
  }) {
    if (autoHelp && !_declarations.containsKey('help')) {
      flag('help', alias: 'h', desc: 'Show this message');
    }
    _parsed = Cli(args);
    _changed();
    if (autoHelp) {
      if (_parsed.switches.containsKey('help') ||
          _parsed.switches.containsKey('h')) {
        stdout.writeln(usage(syntax: syntax, desc: desc));
        exit(0);
      }
    }
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

  /// Every switch given that no declaration covers.
  List<String> unknown() => _parsed.unknown();

  /// Every switch the parser saw, declared or not. See [Cli.switches].
  ///
  /// The member that completed the mirror in 6.0.0: it was on [Cli] only, so
  /// a script outside a handler had to write `cli.parsed.switches` — a third
  /// spelling of a member that has one.
  Map<String, String?> get switches => _parsed.switches;

  /// First positional argument as a subcommand name, or `null`.
  String? get command => _parsed.command;

  /// Positional arguments, in order. See [Cli.args].
  List<String> get args => _parsed.args;

  /// The raw argument list as parsed.
  List<String> get raw => _parsed.raw;

  /// Generates a formatted usage block string. See [Cli.usage].
  String usage({
    String? syntax,
    String? desc,
    Map<String, String>? flags,
    Map<String, String>? options,
  }) =>
      _parsed.usage(syntax: syntax, desc: desc, flags: flags, options: options);
}
