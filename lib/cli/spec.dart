// The eight declarators, shared by the three receivers.
//
// `parser.flag(x)` is global, `build.flag(x)` is command-local, and
// `Cli.flag(x)` inside a handler reads the one in scope: the receiver is the
// scope. One mixin declared once and mixed three times, which is why three
// receivers for eight declarators is not duplication.

part of 'cli.dart';

// ============================================================================
// THE DECLARATORS (_Spec)
// ============================================================================

/// Declaring an interface: the half of the API shared by [Cli], [Command] and
/// [CliParser].
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

  String? _short(String? abbr) => abbr == null ? null : Cli._clean(abbr);

  Opt<V> _declare<V>(
    String name,
    String? abbr,
    V defaultsTo,
    _Decl decl,
    V Function(Cli cli, Opt<V> self) resolver,
  ) {
    _declarations[Cli._clean(name)] = decl;
    _changed();
    return Opt<V>._(Cli._clean(name), _short(abbr), defaultsTo, this, resolver);
  }

  /// Declares a boolean flag.
  ///
  /// A flag never consumes the token after it, so `--verbose main.dart` leaves
  /// `main.dart` a positional argument. [defaultsTo] is what the returned [Opt] reads
  /// when neither the command line nor [env] said otherwise.
  ///
  /// [env] names an environment variable to read when the flag is absent, so a
  /// boolean can be set by the shell as well as on the command line —
  /// `CI=true`, `FORCE=1`.
  ///
  /// ```dart
  /// final force = parser.flag('force', abbr: 'f');
  /// if (force()) rebuild();
  /// ```
  Opt<bool> flag(
    String name, {
    String? abbr,
    String help = '',
    bool defaultsTo = false,
    String? env,
  }) => _declare<bool>(
    name,
    abbr,
    defaultsTo,
    _Decl(
      abbr: _short(abbr),
      help: help,
      defaultsTo: defaultsTo,
      flag: true,
      env: env,
    ),
    (cli, self) => cli._readFlag(self),
  );

  /// Declares an option carrying text.
  ///
  /// [defaultsTo] is what the option reads when nothing supplied a value, and it
  /// satisfies [Cli.require] — so a default is written once, here, rather than
  /// at every call site. [env] names an environment variable to fall back to,
  /// which also satisfies `require`. [allowed] limits the accepted values.
  ///
  /// ```dart
  /// final out = parser.option('out', abbr: 'o', defaultsTo: 'dist');
  /// ```
  Opt<String> option(
    String name, {
    String? abbr,
    String help = '',
    String defaultsTo = '',
    bool required = false,
    List<String>? allowed,
    String? env,
  }) => _declare<String>(
    name,
    abbr,
    defaultsTo,
    _Decl(
      abbr: _short(abbr),
      help: help,
      defaultsTo: defaultsTo.isEmpty ? null : defaultsTo,
      required: required,
      allowed: allowed,
      env: env,
    ),
    (cli, self) => cli._readText(self) ?? self.defaultsTo,
  );

  /// Declares an option carrying a whole number.
  ///
  /// ```dart
  /// final size = parser.number('concurrency', defaultsTo: 4);
  /// ```
  ///
  /// A value that is not a number reads as [defaultsTo], and [Cli.require] reports it
  /// rather than letting the script run on a number nobody asked for.
  Opt<int> number(
    String name, {
    String? abbr,
    String help = '',
    int defaultsTo = 0,
    bool required = false,
    String? env,
  }) => _declare<int>(
    name,
    abbr,
    defaultsTo,
    _Decl(
      abbr: _short(abbr),
      help: help,
      defaultsTo: defaultsTo,
      required: required,
      env: env,
      shape: _Shape.number,
    ),
    (cli, self) {
      final text = cli._readText(self);
      return text == null
          ? self.defaultsTo
          : int.tryParse(text.trim()) ?? self.defaultsTo;
    },
  );

  /// Declares an option carrying a decimal number.
  Opt<double> decimal(
    String name, {
    String? abbr,
    String help = '',
    double defaultsTo = 0,
    bool required = false,
    String? env,
  }) => _declare<double>(
    name,
    abbr,
    defaultsTo,
    _Decl(
      abbr: _short(abbr),
      help: help,
      defaultsTo: defaultsTo,
      required: required,
      env: env,
      shape: _Shape.decimal,
    ),
    (cli, self) {
      final text = cli._readText(self);
      return text == null
          ? self.defaultsTo
          : double.tryParse(text.trim()) ?? self.defaultsTo;
    },
  );

  /// Declares an option that may be given more than once.
  ///
  /// Every occurrence contributes a value. With [splitCommas] set, one comma-separated
  /// value contributes each part, so `--tag a,b` and `--tag a --tag b` read
  /// the same.
  ///
  /// ```dart
  /// final tags = parser.list('tag', splitCommas: true);
  /// for (final tag in tags()) print(tag);
  /// ```
  Opt<List<String>> list(
    String name, {
    String? abbr,
    String help = '',
    List<String> defaultsTo = const [],
    bool required = false,
    List<String>? allowed,
    bool splitCommas = false,
    String? env,
  }) => _declare<List<String>>(
    name,
    abbr,
    defaultsTo,
    _Decl(
      abbr: _short(abbr),
      help: help,
      required: required,
      allowed: allowed,
      env: env,
      splitCommas: splitCommas,
      shape: _Shape.list,
    ),
    (cli, self) {
      final values = cli._readAll(self);
      return values.isEmpty ? self.defaultsTo : values;
    },
  );

  /// Declares an option whose value is one of an enum's.
  ///
  /// The accepted spellings are the enum's own names, so the usage block and
  /// the validation both come from the type rather than a second list that can
  /// drift away from it.
  ///
  /// ```dart
  /// final level = parser.choice('level', LogLevel.values, defaultsTo: LogLevel.info);
  /// logger.level = level();
  /// ```
  Opt<E> choice<E extends Enum>(
    String name,
    List<E> values, {
    required E defaultsTo,
    String? abbr,
    String help = '',
    bool required = false,
    String? env,
  }) => _declare<E>(
    name,
    abbr,
    defaultsTo,
    _Decl(
      abbr: _short(abbr),
      help: help,
      defaultsTo: defaultsTo.name,
      required: required,
      allowed: [for (final value in values) value.name],
      env: env,
    ),
    (cli, self) {
      final text = cli._readText(self)?.trim().toLowerCase();
      if (text == null) return self.defaultsTo;
      for (final value in values) {
        if (value.name.toLowerCase() == text) return value;
      }
      return self.defaultsTo;
    },
  );

  /// Declares an option whose value is one of a list of allowed strings.
  ///
  /// ```dart
  /// final format = parser.choose('format', ['mp3', 'flac', 'both'], defaultsTo: 'mp3');
  /// ```
  Opt<String> choose(
    String name,
    List<String> choices, {
    required String defaultsTo,
    String? abbr,
    String help = '',
    bool required = false,
    String? env,
  }) => _declare<String>(
    name,
    abbr,
    defaultsTo,
    _Decl(
      abbr: _short(abbr),
      help: help,
      defaultsTo: defaultsTo,
      required: required,
      allowed: choices,
      env: env,
    ),
    (cli, self) {
      final text = cli._readText(self)?.trim();
      if (text == null) return self.defaultsTo;
      for (final choice in choices) {
        if (choice.toLowerCase() == text.toLowerCase()) return choice;
      }
      return self.defaultsTo;
    },
  );

  /// Declares an option carrying a length of time.
  ///
  /// The value is read by [parseDuration], so `--timeout 30s`,
  /// `--timeout 1h30m` and a bare `--timeout 30` (seconds) all work. A value
  /// that is not a duration reads as [defaultsTo], and [Cli.require] reports it.
  ///
  /// ```dart
  /// final timeout = parser.duration('timeout', defaultsTo: 30.s);
  /// await Http.get(url, timeout: timeout());
  /// ```
  Opt<Duration> duration(
    String name, {
    String? abbr,
    String help = '',
    Duration defaultsTo = Duration.zero,
    bool required = false,
    String? env,
  }) => _declare<Duration>(
    name,
    abbr,
    defaultsTo,
    _Decl(
      abbr: _short(abbr),
      help: help,
      defaultsTo: _spanText(defaultsTo),
      required: required,
      env: env,
      shape: _Shape.duration,
    ),
    (cli, self) {
      final text = cli._readText(self);
      return text == null ? self.defaultsTo : text.duration ?? self.defaultsTo;
    },
  );

  /// Declares an option carrying a date.
  ///
  /// The value is read by [parseTime], so ISO-8601 and the loose forms
  /// it accepts all work. There is no sensible default date, so the [Opt]
  /// reads `null` when nothing was given — the option `--since` exists
  /// precisely so a script can tell "not given" from "the beginning of time".
  ///
  /// ```dart
  /// final since = parser.date('since');
  /// rows.where((r) => since() == null || r.seen.isAfter(since()!));
  /// ```
  Opt<DateTime?> date(
    String name, {
    String? abbr,
    String help = '',
    DateTime? defaultsTo,
    bool required = false,
    String? env,
  }) => _declare<DateTime?>(
    name,
    abbr,
    defaultsTo,
    _Decl(
      abbr: _short(abbr),
      help: help,
      defaultsTo: defaultsTo?.toUtc().toIso8601String(),
      required: required,
      env: env,
      shape: _Shape.date,
    ),
    (cli, self) {
      final text = cli._readText(self);
      return text == null ? self.defaultsTo : text.date ?? self.defaultsTo;
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
  /// final cmd = parser.handle('build', build, help: 'Build the project');
  /// final out = cmd.option('out', abbr: 'o', defaultsTo: 'dist');
  /// ```
  ///
  /// The handler's return value is the exit code — see [Cli.run].
  Command handle(
    String name,
    FutureOr<int> Function(Cli cli) handler, {
    String help = '',
  }) => _register(name, help, handler);

  /// Registers [name] as a group of subcommands, returning it to nest under.
  ///
  /// Naming a group without one of its subcommands prints its usage block.
  ///
  /// ```dart
  /// final remote = parser.group('remote', help: 'Manage remotes');
  /// remote.handle('add', build, help: 'Add a remote');
  /// remote.handle('rm', build, help: 'Remove a remote');
  /// ```
  Command group(String name, {String help = ''}) => _register(name, help, null);

  Command _register(
    String name,
    String help,
    FutureOr<int> Function(Cli cli)? handler,
  ) {
    final child = _children[name] = Command._(name, help, handler);
    _changed();
    return child;
  }

  /// The declaration named [cleanKey], or the one whose abbr it is.
  _Decl? _decl(String cleanKey) =>
      _declarations[cleanKey] ??
      _declarations.values.where((d) => d.abbr == cleanKey).firstOrNull;
}
