// One declared flag or option, and the reader for it.
//
// Split out of `cli.dart`, which was 1,379 lines and seven public
// types. A `part` rather than a library, because `_Decl` and `_Spec` are
// private to the domain and splitting them into separate libraries would
// mean making them public to keep them reachable. No name moved.

part of 'cli.dart';

// ============================================================================
// DECLARATIONS (Opt)
// ============================================================================

/// One declared flag or option, and the way to read it.
///
/// A declaration hands one back, so the type is settled once — at the
/// declaration — rather than guessed at every call site:
///
/// ```dart
/// final force = parser.flag('force', abbr: 'f');             // Opt<bool>
/// final size = parser.number('concurrency', defaultsTo: 4);          // Opt<int>
/// final out = parser.option('out', abbr: 'o', defaultsTo: 'dist');  // Opt<String>
///
/// parser.parse(args);
///
/// if (force()) rebuild(out(), size());
/// ```
///
/// Calling the option reads it. Sources resolve in the usual order — the
/// command line, then the `env` variable the declaration names, then [defaultsTo] —
/// and the answer is a [T], never text that still has to be parsed.
final class Opt<T> {
  /// The long name, without dashes.
  final String name;

  /// The short abbr, without dashes, or `null`.
  final String? abbr;

  /// What this option reads when nothing supplied a value.
  final T defaultsTo;

  final _Spec _owner;
  final T Function(Cli cli, Opt<T> self) _resolver;

  const Opt._(
    this.name,
    this.abbr,
    this.defaultsTo,
    this._owner,
    this._resolver,
  );

  /// The resolved value.
  ///
  /// Reads from [from], or from whichever command line the declaring object
  /// last parsed — the shared `cli`, a [Cli] itself, or, for an option
  /// declared on a [Command], the scope that command was run with.
  ///
  /// **Four readers, four questions, and no `!` collapses any of them.**
  /// [call] is the value. [given] is whether it was supplied — a switch set
  /// explicitly to its default is `given`, so this is not `call() != defaultsTo`.
  /// [count] is how many times, for `-vvv`, so it is not `given ? 1 : 0`.
  /// [negated] is whether it arrived as `--no-x`, which is not `!call()`: a
  /// flag absent entirely is neither given nor negated.
  T call([Cli? from]) => _resolver(from ?? _owner._reader, this);

  /// Whether the command line itself carried this option.
  ///
  /// False for a value that came from `env` or [defaultsTo], which is how a script
  /// tells "not given" from "given the same as the default".
  bool given([Cli? from]) => (from ?? _owner._reader)._given(this);

  /// How many times the command line carried it.
  ///
  /// A repeated switch is how a command line spells a level, so `-vvv` and
  /// `--verbose --verbose --verbose` both count three:
  ///
  /// ```dart
  /// final verbose = parser.flag('verbose', abbr: 'v');
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
    this.abbr,
    this.help = '',
    this.defaultsTo,
    this.flag = false,
    this.required = false,
    this.allowed,
    this.env,
    this.splitCommas = false,
    this.shape = _Shape.text,
  });

  final String? abbr;
  final String help;

  /// The declared default, kept to print it in the usage block and to satisfy
  /// [Cli.require]. The value an [Opt] reads is its own typed [Opt.defaultsTo].
  final Object? defaultsTo;
  final bool flag;
  final bool required;
  final List<String>? allowed;
  final String? env;
  final bool splitCommas;
  final _Shape shape;
}
