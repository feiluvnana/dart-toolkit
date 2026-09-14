/// # Command-line arguments
///
/// A dependency-free parser for the flag shapes scripts actually use:
/// `--flag`, `--key=value`, `--key value`, `-k value`, `-abc`, `--no-key`,
/// repeated options, and trailing positional arguments.
///
/// Declaring an option hands back a typed [Opt] handle; calling the handle
/// reads the value. There is no name-based lookup to get it wrong:
///
/// ```dart
/// final parser = CliParser(description: 'Scrape a catalogue');
/// final force = parser.flag('force', abbr: 'f', help: 'Overwrite output');
/// final size = parser.number('concurrency', abbr: 'c', defaultsTo: 4);
///
/// final cli = parser.parse(args);
/// if (force()) rebuild('dist', size());
/// print(cli.args); // positional arguments
/// ```
///
/// Or declare commands and let [CliParser.run] parse, validate, print
/// `--help` and pick the handler:
///
/// ```dart
/// Future<int> build(Cli cli) async => 0;
///
/// void main(List<String> args) async {
///   final parser = CliParser();
///   parser.handle('build', build, help: 'Build the project')
///     ..option('out', abbr: 'o', defaultsTo: 'dist', help: 'Output directory');
///   await shutdown(await parser.run(args));
/// }
/// ```
///
/// **One name per concept.** An option is declared with `abbr`, `help` and
/// `defaultsTo` — the `package:args` spelling — and nothing accepts a second
/// name for any of the three.
/// {@category CLI}
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

/// Declares a command-line interface, then parses arguments against it.
///
/// Declarations ([flag], [option], [number], [list], [choose] and the rest)
/// each return a typed [Opt] handle. Handles are readable after [parse], and
/// re-reading is free.
///
/// Construct one per program, or one per test — there is no shared instance,
/// so declarations cannot leak between them.
class CliParser with _Spec {
  Cli _parsed = Cli(const []);

  /// The syntax line shown in usage help, e.g. `mytool <command> [options]`.
  final String? syntax;

  /// The one-line description shown in usage help.
  final String? description;

  /// Creates a parser with no declarations.
  CliParser({this.syntax, this.description});

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

  /// Parses [args] against the declarations made so far.
  ///
  /// Returns the parsed command line, which carries the positional [Cli.args],
  /// the raw [Cli.switches] and the subcommand [Cli.command]. Declared options
  /// are read through the [Opt] handles the declarations returned.
  ///
  /// When [autoHelp] is set, `-h`/`--help` is registered if not already
  /// declared, and printing usage then exits with code 0.
  ///
  /// **That exit does not run [onExit] hooks**, because this method is
  /// synchronous and [shutdown] is not. Parse before registering any hook — or
  /// use [run], which is async and shuts down cleanly.
  Cli parse(List<String> args, {bool autoHelp = false}) {
    if (autoHelp && !_declarations.containsKey('help')) {
      flag('help', abbr: 'h', help: 'Show this message');
    }
    _parsed = Cli(args);
    _changed();
    if (autoHelp &&
        (_parsed.switches.containsKey('help') ||
            _parsed.switches.containsKey('h'))) {
      stdout.writeln(usage());
      exit(0);
    }
    return _parsed;
  }

  /// The command line as last parsed.
  ///
  /// Before the first [parse] this is an empty command line, not `null`, so
  /// reading an [Opt] early gives its default rather than throwing.
  Cli get parsed => _parsed;

  /// Parses [args], dispatches to the matching command and returns its exit
  /// code. See [Cli.run].
  Future<int> run(
    List<String> args, {
    String? version,
    bool strict = false,
    FutureOr<int> Function(Cli cli)? body,
  }) {
    parse(args);
    return _parsed.run(
      syntax: syntax,
      description: description,
      version: version,
      strict: strict,
      body: body,
    );
  }

  /// Validates that [names] — or every declared required option — were given.
  void require([Iterable<String>? names]) => _parsed.require(names);

  /// Every switch given that no declaration covers.
  List<String> unknown() => _parsed.unknown();

  /// Every switch the parser saw, declared or not. See [Cli.switches].
  Map<String, String?> get switches => _parsed.switches;

  /// The first positional argument, when it names a subcommand.
  String? get command => _parsed.command;

  /// Positional arguments, in order. See [Cli.args].
  List<String> get args => _parsed.args;

  /// The raw argument list as parsed.
  List<String> get raw => _parsed.raw;

  /// The formatted usage block for the declarations made so far.
  String usage({Map<String, String>? flags, Map<String, String>? options}) =>
      _parsed.usage(
        syntax: syntax,
        description: description,
        flags: flags,
        options: options,
      );

  /// Writes [usage] to stdout.
  void printUsage() => stdout.writeln(usage());

  /// Clears every declaration, subcommand and parsed value.
  void reset() {
    _declarations.clear();
    _children.clear();
    _parsed = Cli(const []);
  }
}
