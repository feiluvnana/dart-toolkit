// The eight declarators, shared by the three receivers.
//
// `cli.flag(x)` is global, `build.flag(x)` is command-local, and
// `Cli.flag(x)` inside a handler reads the one in scope: the receiver is the
// scope. One mixin declared once and mixed three times, which is why three
// receivers for eight declarators is not duplication.

part of 'cli.dart';

// ============================================================================
// THE DECLARATORS (_Spec)
// ============================================================================

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
  /// await net.http.send(.get, url, timeout: timeout());
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
      def: def?.toUtc().toIso8601String(),
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
