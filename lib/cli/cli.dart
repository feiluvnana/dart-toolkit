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

/// The `cli` domain: flags, options, subcommands and usage text.
///
/// Parsing arguments touches nothing — no process, no environment, no
/// terminal — so it is a domain of its own rather than a corner of
/// `system`. Not `const`: the accessor holds the declarations and the last
/// parse.
final CliAccessor cli = CliAccessor();

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
