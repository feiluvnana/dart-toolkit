part of '../../cli.dart';

/// A command line the program cannot act on: an unknown option, a bad value, a missing
/// required option. [Cli.run] prints it and exits 64; [CliCommand.run] throws it.
///
/// {@category CLI}
final class UsageException implements Exception {
  final String message;
  final String? command;

  const UsageException(this.message, [this.command]);

  @override
  String toString() => message;
}

/// Callback action executed when a CLI command is triggered.
typedef CommandHandler = FutureOr<void> Function(CliContext ctx);

/// Something a [CliCommand] declares and a handler reads back through [CliContext.call]:
/// an [Opt], written `--name`, or an [Arg], written by its position.
///
/// The declaration itself is the key, so a name is written once and its type is the type
/// that comes back:
///
/// ```dart
/// final top = Opt.number('top', abbr: 'n').or(10);
/// final id  = Arg.text('id').required();
/// …
/// ctx(top)  // an int, statically
/// ctx(id)   // a String, statically
/// ```
///
/// [T] carries whether a value is guaranteed: both are nullable until `or` gives a default
/// or `required` insists on one, and a flag is always a `bool`.
///
/// {@category CLI}
sealed class CliValue<T> {
  /// What it is called: in `--name` for an option, in `<name>` for an argument.
  final String name;

  /// Help text shown by `--help`.
  final String description;

  const CliValue(this.name, {this.description = ''});

  /// Turns the text on the command line into the value, throwing [UsageException] when it
  /// is not one.
  T _parse(String raw);

  /// Used when it is absent, or `null` when there is none.
  T? get _or;

  /// Whether parsing fails when it is absent. Never true for a flag.
  bool get _isRequired;

  /// The values it is restricted to, shown in help, or `null` when it is not.
  List<Object?>? get _choices => null;

  /// What kind of value it takes, as help writes it after the name: `<int>`, `<a|b>`.
  String get _hint;
}

/// An option declared on a [CliCommand], written `--name` or `-n`. See [Opt].
///
/// {@category CLI}
sealed class CliOption<T> extends CliValue<T> {
  /// The single-character short form, used as `-a`.
  final String? abbr;

  /// The environment variable read when the option is not on the command line.
  final String? _env;

  const CliOption(super.name, {super.description, this.abbr, String? env})
    : _env = env,
      assert(abbr == null || abbr.length == 1, 'abbr is one character');

  /// Whether this option takes a value of its own on the command line.
  bool get _takesValue => true;

  /// How a second occurrence combines with the first, or `null` when the last one wins.
  _Join? get _join => null;

  /// The same option, falling back to the environment variable [name] when it is not on
  /// the command line: `Opt.text('token').env('GITHUB_TOKEN').required()`.
  ///
  /// A set variable satisfies `required()`, and `--help` shows it as `[env: NAME]`. An
  /// empty one is treated as unset.
  CliOption<T> env(String name);
}

/// A positional argument, written where it stands rather than by name. See [Arg].
///
/// A positional is a declared value like an option, which is the whole point: it is typed,
/// it may have a default, it may be required, and it prints itself in `--help`. Before this
/// existed every program pulled its own out of `CliContext.rest` and checked it by hand, and
/// none of them showed up in the usage line.
///
/// {@category CLI}
final class Arg<T> extends CliValue<T> {
  final T Function(String raw) _parseValue;

  @override
  final List<Object?>? _choices;

  @override
  final T? _or;

  @override
  final bool _isRequired;

  @override
  final String _hint;

  /// How the values of a variadic argument fold into one list, or `null` when it takes one
  /// value. Its presence is what makes it variadic: at most one per command, and last.
  final _Join? _join;

  bool get _variadic => _join != null;

  const Arg._(
    super.name, {
    required T Function(String raw) parse,
    required String hint,
    super.description,
    List<Object?>? choices,
    T? or,
    bool required = false,
    _Join? join,
  }) : _parseValue = parse,
       _hint = hint,
       _choices = choices,
       _or = or,
       _isRequired = required,
       _join = join;

  /// A string argument.
  static Arg<String?> text(String name, {String description = ''}) =>
      Arg<String?>._(name, parse: (raw) => raw, hint: '<text>', description: description);

  /// An integer argument, rejected during parsing when it is not one.
  static Arg<int?> number(String name, {String description = ''}) =>
      Arg<int?>._(name, parse: (raw) => _int('argument <$name>', raw), hint: '<int>', description: description);

  /// An argument restricted to [values], matched by [Enum.name] or `toString()`.
  static Arg<V?> among<V>(String name, List<V> values, {String description = ''}) => Arg<V?>._(
    name,
    parse: (raw) => _among('argument <$name>', values, raw),
    hint: _choiceHint(values),
    description: description,
    choices: values,
  );

  /// An argument parsed by [parse]; anything it throws becomes a [UsageException].
  ///
  /// A constructor tears off as a parser, so `Arg.by('file', Path.new)` is an argument that
  /// arrives as a `Path`.
  static Arg<V?> by<V>(String name, V Function(String raw) parse, {String description = ''}) => Arg<V?>._(
    name,
    parse: (raw) => _guard('argument <$name>', parse, raw),
    hint: '<value>',
    description: description,
  );

  @override
  T _parse(String raw) => _parseValue(raw);

  /// The same argument as an [Arg] of [U], with a default or a requirement.
  Arg<U> _as<U>({U Function(String raw)? parse, U? or, bool required = false, _Join? join}) => Arg<U>._(
    name,
    parse: parse ?? (raw) => _parse(raw) as U,
    hint: _hint,
    description: description,
    choices: _choices,
    or: or,
    required: required,
    join: join ?? _join,
  );

  /// How it is written in the usage line: `<id>`, `[id]`, `<paths>...`, `[paths...]`.
  String get _placeholder => switch ((_isRequired, _variadic)) {
    (true, true) => '<$name>...',
    (true, false) => '<$name>',
    (false, true) => '[$name...]',
    (false, false) => '[$name]',
  };
}

/// What turns an optional [Arg] into one whose value is guaranteed, and so whose
/// [CliContext.call] is non-nullable. It reads the same as [OptionalOpt] on purpose.
///
/// {@category CLI}
extension OptionalArg<T extends Object> on Arg<T?> {
  /// The same argument with [value] when it is absent.
  Arg<T> or(T value) => _as(or: _allowed(_choices, value));

  /// The same argument, but parsing fails when it is absent — for a variadic one, when
  /// nothing at all was given.
  Arg<T> required() => _as(required: true);

  /// The same argument, taking everything that is left: `tk hash <paths>...`. None at all is
  /// `[]`; `.many().required()` insists on at least one. It reads the same as
  /// [OptionalOpt.many], and each value is parsed and checked as one would be.
  ///
  /// At most one per command, and it must be declared last.
  Arg<List<T>> many() => _as(
    parse: (raw) => [_parse(raw) as T],
    or: List<T>.unmodifiable(const []),
    join: (previous, next) => <T>[...previous! as List<T>, ...next! as List<T>],
  );
}

/// A boolean option: present means true, and it never consumes a value. See [Opt.flag].
///
/// `--dry=false` and `--no-dry` both say false; anything but `true` or `false` after an `=`
/// is a usage error rather than a silent `true`.
final class _Flag extends CliOption<bool> {
  const _Flag(super.name, {super.description, super.abbr, super.env});

  @override
  bool _parse(String raw) => switch (raw.toLowerCase()) {
    'true' || '1' || 'yes' => true,
    'false' || '0' || 'no' => false,
    _ => throw UsageException('Option "--$name" is a flag: it takes true or false, not "$raw".'),
  };

  @override
  bool get _or => false;

  @override
  bool get _isRequired => false;

  @override
  bool get _takesValue => false;

  @override
  String get _hint => '';

  @override
  CliOption<bool> env(String name) => _Flag(this.name, description: description, abbr: abbr, env: name);
}

/// An option: a flag, a string, an integer, one of a fixed set, or whatever a function
/// of your own returns. Every kind is behind this one name.
///
/// All but [flag] produce a nullable option; [OptionalOpt.or] and [OptionalOpt.required]
/// are what guarantee a value, and they are what make [CliContext.call] return a
/// non-nullable [T]. [OptionalOpt.many] takes it any number of times, and [env] reads it
/// from the environment when it is not given.
///
/// ```dart
/// final dry     = Opt.flag('dry-run', abbr: 'd');                  // bool
/// final out     = Opt.text('out', abbr: 'o');                      // String?
/// final to      = Opt.text('to', abbr: 't').required();            // String
/// final top     = Opt.number('top', abbr: 'n').or(10);             // int
/// final algo    = Opt.among('algo', Hash.values).or(Hash.sha256);  // Hash
/// final since   = Opt.by('since', DateTime.parse);                 // DateTime?
/// final headers = Opt.text('header', abbr: 'H').many();            // List<String>
/// final token   = Opt.text('token').env('GITHUB_TOKEN').required(); // String
/// ```
///
/// {@category CLI}
final class Opt<T> extends CliOption<T> {
  final T Function(String raw) _parseValue;

  @override
  final List<Object?>? _choices;

  @override
  final T? _or;

  @override
  final bool _isRequired;

  @override
  final _Join? _join;

  @override
  final String _hint;

  const Opt._(
    super.name, {
    required T Function(String raw) parse,
    required String hint,
    super.description,
    super.abbr,
    super.env,
    List<Object?>? choices,
    T? or,
    bool required = false,
    _Join? join,
  }) : _parseValue = parse,
       _hint = hint,
       _choices = choices,
       _or = or,
       _isRequired = required,
       _join = join;

  /// A boolean option. Present means true; it never consumes a value.
  static CliOption<bool> flag(String name, {String description = '', String? abbr}) =>
      _Flag(name, description: description, abbr: abbr);

  /// A string option.
  static Opt<String?> text(String name, {String description = '', String? abbr}) =>
      Opt<String?>._(name, parse: (raw) => raw, hint: '<text>', description: description, abbr: abbr);

  /// An integer option, rejected during parsing when it is not one.
  static Opt<int?> number(String name, {String description = '', String? abbr}) => Opt<int?>._(
    name,
    parse: (raw) => _int('option "--$name"', raw),
    hint: '<int>',
    description: description,
    abbr: abbr,
  );

  /// An option restricted to [values], matched by [Enum.name] or `toString()`.
  static Opt<V?> among<V>(String name, List<V> values, {String description = '', String? abbr}) => Opt<V?>._(
    name,
    parse: (raw) => _among('option "--$name"', values, raw),
    hint: _choiceHint(values),
    description: description,
    abbr: abbr,
    choices: values,
  );

  /// An option parsed by [parse]; anything it throws becomes a [UsageException].
  static Opt<V?> by<V>(String name, V Function(String raw) parse, {String description = '', String? abbr}) => Opt<V?>._(
    name,
    parse: (raw) => _guard('option "--$name"', parse, raw),
    hint: '<value>',
    description: description,
    abbr: abbr,
  );

  @override
  T _parse(String raw) => _parseValue(raw);

  @override
  Opt<T> env(String name) => _as(parse: _parseValue, env: name, or: _or, required: _isRequired, join: _join);

  /// The same option as an [Opt] of [U]: everything carried over but what is given here.
  Opt<U> _as<U>({U Function(String raw)? parse, String? env, U? or, bool required = false, _Join? join}) => Opt<U>._(
    name,
    parse: parse ?? (raw) => _parse(raw) as U,
    hint: _hint,
    description: description,
    abbr: abbr,
    env: env ?? _env,
    choices: _choices,
    or: or,
    required: required,
    join: join,
  );
}

/// What turns an optional [Opt] into one whose value is guaranteed, and so whose
/// [CliContext.call] is non-nullable.
///
/// {@category CLI}
extension OptionalOpt<T extends Object> on Opt<T?> {
  /// The same option with [value] when it is absent.
  ///
  /// Throws [ArgumentError] when the option is restricted and [value] is not one of its
  /// choices — a default the parser would reject is a bug in the declaration, not in the
  /// command line.
  Opt<T> or(T value) => _as(or: _allowed(_choices, value));

  /// The same option, but parsing fails when it is absent.
  Opt<T> required() => _as(required: true);

  /// The same option, taken any number of times: `-H a -H b` is `['a', 'b']`, and none
  /// at all is `[]`. Without it the last occurrence wins.
  Opt<List<T>> many() => _as(
    parse: (raw) => [_parse(raw) as T],
    or: List<T>.unmodifiable(const []),
    join: (previous, next) => <T>[...previous! as List<T>, ...next! as List<T>],
  );
}

/// How a repeated option folds a second occurrence into the first. Untyped, because a
/// generic function type would not survive being read through a `CliOption<Object?>`.
typedef _Join = Object? Function(Object? previous, Object? next);

/// [value], when [choices] allows it: a default the parser would reject is a bug in the
/// declaration, not in the command line.
T _allowed<T>(List<Object?>? choices, T value) {
  if (choices != null && !choices.contains(value)) {
    throw ArgumentError.value(value, 'value', 'Not one of ${choices.map(_label).join(', ')}');
  }
  return value;
}

/// The label a value is spelled with on the command line and in help text.
String _label(Object? value) => value is Enum ? value.name : '$value';

/// [what] is how the error names it: `option "--top"`, `argument <n>`.
T _int<T>(String what, String raw) {
  final value = int.tryParse(raw);
  if (value == null) throw UsageException('Invalid value "$raw" for $what. Expected an integer.');
  return value as T;
}

/// `<a|b|c>`, or `<choice>` when spelling every one out would crowd the help line.
String _choiceHint(List<Object?> values) {
  final all = values.map(_label).join('|');
  return all.length <= 24 ? '<$all>' : '<choice>';
}

/// [what] is how the error names it: `option "--algo"`, `argument <mode>`.
T _among<T, V>(String what, List<V> values, String raw) {
  for (final value in values) {
    if (_label(value) == raw) return value as T;
  }
  throw UsageException('Invalid value "$raw" for $what. Allowed choices: ${values.map(_label).join(', ')}');
}

T _guard<T, V>(String what, V Function(String raw) parse, String raw) {
  try {
    return parse(raw) as T;
  } on UsageException {
    rethrow;
  } catch (e) {
    throw UsageException('Invalid value "$raw" for $what: $e');
  }
}

/// The closest of [candidates] to [typed], for a did-you-mean, or `null` when none is close.
String? _closest(String typed, Iterable<String> candidates) {
  int distance(String a, String b) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    var current = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      current[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        current[j] = min(min(current[j - 1] + 1, previous[j] + 1), previous[j - 1] + cost);
      }
      final temp = previous;
      previous = current;
      current = temp;
    }
    return previous[b.length];
  }

  String? best;
  var bestDistance = 1 << 30;
  for (final candidate in candidates) {
    final d = candidate.startsWith(typed) ? 0 : distance(typed, candidate);
    if (d < bestDistance) (best, bestDistance) = (candidate, d);
  }
  return bestDistance <= max(2, typed.length ~/ 3) && bestDistance < typed.length ? best : null;
}

/// Parsed arguments passed to a [CommandHandler].
///
/// {@category CLI}
class CliContext {
  /// Positional arguments as they were typed, plus everything after a `--` terminator.
  ///
  /// The raw list, for a command that declares no [Arg]s. One that does reads them through
  /// [call] instead, typed and checked, and this is what they were bound from.
  final List<String> rest;

  /// The command that was dispatched.
  final CliCommand command;

  /// Cancelled on SIGINT, SIGTERM and [Lifecycle.exit], before the other exit hooks run.
  ///
  /// [Cli.run] makes it the ambient [Cancel.token] for the whole action, so a download,
  /// a crawl, a `retry` or a `run` inside it already stops; this is the handle that stops them.
  final CancelToken cancel;

  final Map<CliValue<Object?>, Object?> _values;

  CliContext(this.rest, Map<CliValue<Object?>, Object?> values, this.command, {CancelToken? cancel})
    : _values = values,
      cancel = cancel ?? CancelToken();

  /// The value of [option] — the option itself is the key, so its type is its value's.
  ///
  /// ```dart
  /// if (ctx(dry)) return;
  /// final n = ctx(top); // int, because `top` was declared with `.or(10)`
  /// ```
  ///
  /// Throws [StateError] only when a non-nullable option somehow reaches a handler
  /// unset — a declared default or `required()` is what rules that out.
  T call<T>(CliValue<T> value) {
    if (_values.containsKey(value)) return _values[value] as T;
    if (value._or case final fallback?) return fallback;
    if (null is T) return null as T;
    throw StateError('${value is Arg ? '<${value.name}>' : '--${value.name}'} was not given and has no default.');
  }

  /// Whether [value] was given — on the command line, or through its [CliOption.env] —
  /// rather than defaulted.
  bool given(CliValue<Object?> value) => _values.containsKey(value);
}

/// A command: a name, the values it takes, subcommands and the handler that runs it.
///
/// Everything a command is, it is given: `values`, `commands` and [handler] are constructor
/// arguments, and nothing sets them afterwards. `values` holds its [Arg]s and [Opt]s in one
/// list — the kind is in the type — and the [Arg]s bind in the order they are listed.
///
/// ```dart
/// CliCommand('fetch', description: 'Fetch a thing', values: [url, verbose], handler: fetch)
/// ```
///
/// {@category CLI}
class CliCommand {
  final String name;
  final String description;

  /// What runs when this command is dispatched; usage is printed when it is `null`.
  final CommandHandler? handler;

  final List<Arg<Object?>> _args;
  final List<CliOption<Object?>> _options;
  final Map<String, CliCommand> _subcommands;
  CliCommand? _parent;

  CliCommand(
    this.name, {
    this.description = '',
    this.handler,
    Iterable<CliValue<Object?>> values = const [],
    Iterable<CliCommand> commands = const [],
  }) : _args = List.unmodifiable(values.whereType<Arg<Object?>>()),
       _options = List.unmodifiable(values.whereType<CliOption<Object?>>()),
       _subcommands = {for (final c in commands) c.name: c} {
    assert(
      _args.where((a) => a._variadic).length <= 1 &&
          (_args.isEmpty || !_args.take(_args.length - 1).any((a) => a._variadic)),
      'at most one variadic argument, and it is the last one',
    );
    for (final c in _subcommands.values) {
      c._parent = this;
    }
  }

  /// Looks up an option by name, walking up to the root command.
  CliOption<Object?>? _findOption(String name) {
    for (final option in _options) {
      if (option.name == name) return option;
    }
    return _parent?._findOption(name);
  }

  /// Looks up an option by short form, walking up to the root command.
  CliOption<Object?>? _findAbbr(String abbr) {
    for (final option in _options) {
      if (option.abbr == abbr) return option;
    }
    return _parent?._findAbbr(abbr);
  }

  /// This command, then each ancestor up to the root.
  Iterable<CliCommand> get _chain sync* {
    for (CliCommand? cur = this; cur != null; cur = cur._parent) {
      yield cur;
    }
  }

  /// Prints usage help for this command, to [sink] — stdout for `--help`, stderr when it is
  /// the answer to a mistake.
  void _printUsage([StringSink? sink]) {
    final out = sink ?? Io.out;
    // Only what this command actually has. `[command]` on a program with no subcommands is
    // an invitation to type something that cannot work.
    final shape = [for (final arg in _args) arg._placeholder, '[options]', if (_subcommands.isNotEmpty) '[command]'];
    out.writeln('${'Usage:'.bold} $_fullName ${shape.join(' ')}');
    if (description.isNotEmpty) out.writeln('\n$description');

    // Every row first, then one column wide enough for the widest left-hand side: an option
    // that shows what it takes (`-a, --algo <md5|sha1>`) does not fit a fixed 20.
    final inherited = [for (final cmd in _chain.skip(1)) ...cmd._options];
    final args = [for (final arg in _args) (arg._placeholder, _describe(arg))];
    final commands = [for (final sub in _subcommands.values) (sub.name, sub.description)];
    final options = [
      ..._optionRows(_options),
      // Only what this command will actually answer to.
      if (_findOption('help') == null)
        (_findAbbr('h') == null ? '-h, --help' : '    --help', 'Print this help message'),
      if (_parent == null && _version != null && _findOption('version') == null) ('    --version', 'Print the version'),
      if (_parent == null && this is Cli && _findOption('completion') == null)
        ('    --completion <shell>', 'Print a completion script (bash, zsh, fish)'),
    ];
    // What an ancestor declared is accepted here too, so it is shown here too — apart, since
    // it means the same under every command.
    final global = _optionRows(inherited);
    final width = [
      for (final (left, _) in [...args, ...commands, ...options, ...global]) left.length,
    ].fold(18, max);

    void section(String title, List<(String, String)> rows) {
      if (rows.isEmpty) return;
      out.writeln('\n${title.bold}');
      for (final (left, right) in rows) {
        out.writeln('  ${left.padRight(width)}  $right'.trimRight());
      }
    }

    section('Arguments:', args);
    section('Commands:', commands);
    section('Options:', options);
    section('Global options:', global);
  }

  List<(String, String)> _optionRows(Iterable<CliOption<Object?>> options) => [
    for (final option in options)
      // An ancestor's option that something nearer has taken the name of is not reachable
      // here, and one whose short form was taken is reachable by its long form only.
      if (_findOption(option.name) == option)
        (
          '${option.abbr != null && _findAbbr(option.abbr!) == option ? '-${option.abbr}, ' : '    '}'
              '--${option.name}${option._takesValue ? ' ${option._hint}' : ''}',
          // A flag's fallback is `false`, which is what absence already means; saying so is noise.
          _describe(option, fallback: option._takesValue),
        ),
  ];

  /// The help line for one declared value: what it is for, what it may be, what it is when
  /// it is absent. One renderer, so an argument and an option read alike.
  static String _describe(CliValue<Object?> value, {bool fallback = true}) {
    var desc = value.description;
    if (value._choices case final allowed? when allowed.isNotEmpty) {
      final list = '(${allowed.map(_label).join('|')})';
      desc = desc.isEmpty ? list : '$desc $list';
    }
    final repeatable = switch (value) {
      Arg(:final _join) || CliOption(:final _join) => _join != null,
    };
    // A repeatable value's fallback is `[]`, which is what absence already means.
    if (fallback && !repeatable) {
      if (value._or case final given?) desc = '$desc [default: ${_label(given)}]';
    }
    // An argument says it repeats by its own `...`.
    if (repeatable && value is! Arg) desc = '$desc [repeatable]';
    if (value case CliOption(_env: final env?)) desc = '$desc [env: $env]';
    // An argument says it is required by its own `<>`; an option has nowhere else to say so.
    if (value._isRequired && value is! Arg) desc = '$desc [required]';
    return desc.trimLeft();
  }

  /// Binds the positionals to the arguments this command declared, in order.
  ///
  /// A command that declares none keeps the old behaviour exactly: [CliContext.rest] is
  /// whatever was typed and nothing is checked. Declaring them is what buys the checking.
  void _bind(List<String> rest, Map<CliValue<Object?>, Object?> values) {
    if (_args.isEmpty) return;
    var at = 0;
    for (final arg in _args) {
      if (arg._join case final join?) {
        final taken = rest.sublist(at.clamp(0, rest.length));
        at = rest.length;
        if (taken.isNotEmpty) {
          values[arg] = taken.map(arg._parse).reduce(join);
        } else if (arg._isRequired) {
          throw UsageException('Missing argument: ${arg._placeholder}');
        }
        continue;
      }
      if (at < rest.length) {
        values[arg] = arg._parse(rest[at++]);
      } else if (arg._isRequired) {
        throw UsageException('Missing argument: ${arg._placeholder}');
      }
    }
    if (at < rest.length) {
      throw UsageException('Unexpected argument "${rest[at]}".');
    }
  }

  String get _fullName => _parent == null ? name : '${_parent!._fullName} $name';

  CliCommand get _root => _parent == null ? this : _parent!._root;

  String? get _version => switch (_root) {
    Cli(:final version) => version,
    _ => null,
  };

  /// Parses [args] and runs this command, or a matching subcommand.
  ///
  /// Options may precede the subcommand (`app -v fetch`); short flags combine (`-vd`)
  /// and a short option may attach its value (`-j4`, `-j=4`). Usage errors throw
  /// [UsageException]; [Cli.run] turns them into a message and exit code 64.
  Future<void> run(List<String> args) {
    final cancel = CancelToken();
    return Cancel.scope(() => _run(args, {}, cancel), token: cancel);
  }

  /// Stores [value] for [option]: a repeatable one adds to what is there, any other
  /// replaces it.
  static void _set(Map<CliValue<Object?>, Object?> values, CliOption<Object?> option, Object? value) {
    final join = option._join;
    values[option] = join != null && values.containsKey(option) ? join(values[option], value) : value;
  }

  Future<void> _run(List<String> args, Map<CliValue<Object?>, Object?> values, CancelToken cancel) async {
    try {
      await _execute(args, values, cancel);
    } on UsageException catch (e) {
      if (e.command == null) throw UsageException(e.message, _fullName);
      rethrow;
    }
  }

  Future<void> _execute(List<String> args, Map<CliValue<Object?>, Object?> values, CancelToken cancel) async {
    final rest = <String>[];
    // Taking `-h` for something of your own takes `-h` and nothing else: a command that has a
    // `--host` should still answer `--help`, and one that declares a `help` option owns the
    // long form alone. Conflating the two lost `--help` to any command with an `h` abbr.
    final ownsLong = _findOption('help') != null;
    final ownsShort = _findAbbr('h') != null;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];

      if (arg == '--') {
        rest.addAll(args.sublist(i + 1));
        break;
      }

      final isLong = arg.startsWith('--');
      // `-5` is a number, not an option, unless something here answers to `-5`.
      final isNumber =
          !isLong && arg.startsWith('-') && arg.length > 1 && num.tryParse(arg) != null && _findAbbr(arg[1]) == null;
      if (isNumber || (!isLong && (!arg.startsWith('-') || arg.length <= 1))) {
        if (rest.isEmpty && _subcommands.isNotEmpty) {
          // The first positional naming a subcommand dispatches to it, carrying what is parsed so far.
          if (_subcommands[arg] case final sub?) return sub._run(args.sublist(i + 1), values, cancel);
          // One that names none is a typo unless this command takes positionals of its own:
          // printing usage and exiting 0, or running the parent with it, both hid the mistake.
          if (_args.isEmpty) {
            final guess = _closest(arg, _subcommands.keys);
            throw UsageException('Unknown command "$arg".${guess == null ? '' : ' Did you mean "$guess"?'}');
          }
        }
        rest.add(arg);
        continue;
      }

      final raw = arg.substring(isLong ? 2 : 1);
      final eq = raw.indexOf('=');
      final key = eq == -1 ? raw : raw.substring(0, eq);
      final inline = eq == -1 ? null : raw.substring(eq + 1);

      if (isLong ? key == 'help' && !ownsLong : key == 'h' && !ownsShort) {
        _printUsage();
        return;
      }
      if (isLong && key == 'version' && _parent == null && _version != null && _findOption('version') == null) {
        Io.out.writeln('${_root.name} $_version');
        return;
      }
      if (isLong && key == 'completion' && _parent == null && _root is Cli && _findOption('completion') == null) {
        final shell = inline ?? (i + 1 < args.length ? args[++i] : null);
        Io.out.write(_completion(_root, shell));
        return;
      }

      final option = isLong ? _findOption(key) : _findAbbr(key);

      if (option == null && !isLong && key.length > 1) {
        // `-vd` is two flags; `-j4` and `-j=4` are `-j 4`; `-vj4` is both.
        for (var k = 0; k < raw.length; k++) {
          final each = _findAbbr(raw[k]);
          if (each == null && raw[k] == 'h') {
            _printUsage();
            return;
          }
          if (each == null) throw UsageException('Unknown option in "-$raw": -${raw[k]}');
          if (!each._takesValue) {
            // `-vd=false`: the value after `=` belongs to the flag it follows.
            if (k + 1 < raw.length && raw[k + 1] == '=') {
              _set(values, each, each._parse(raw.substring(k + 2)));
              break;
            }
            _set(values, each, true);
            continue;
          }
          var attached = raw.substring(k + 1);
          if (attached.startsWith('=')) attached = attached.substring(1);
          if (attached.isNotEmpty) {
            _set(values, each, each._parse(attached));
          } else if (i + 1 < args.length) {
            _set(values, each, each._parse(args[++i]));
          } else {
            throw UsageException('Option "-${raw[k]}" requires a value.');
          }
          break;
        }
        continue;
      }

      if (option == null) {
        // `--no-dry` is `--dry=false`, for a flag and nothing else.
        if (isLong && key.startsWith('no-') && inline == null) {
          if (_findOption(key.substring(3)) case final flag? when !flag._takesValue) {
            values[flag] = false;
            continue;
          }
        }
        final guess = isLong ? _closest(key, [for (final cmd in _chain) ...cmd._options.map((o) => o.name)]) : null;
        throw UsageException(
          'Unknown option: ${isLong ? '--' : '-'}$key${guess == null ? '' : '. Did you mean "--$guess"?'}',
        );
      }

      if (!option._takesValue) {
        _set(values, option, inline == null ? true : option._parse(inline));
      } else if (inline != null) {
        _set(values, option, option._parse(inline));
      } else if (i + 1 < args.length) {
        _set(values, option, option._parse(args[++i]));
      } else {
        throw UsageException('Option "${isLong ? '--' : '-'}$key" requires a value.');
      }
    }

    // What the command line left unsaid, the environment may say; then required checks,
    // for this command and every ancestor. Defaults live on the option.
    for (final cmd in _chain) {
      for (final option in cmd._options) {
        if (values.containsKey(option)) continue;
        if (option._env case final variable?) {
          if (Env.get(variable) case final raw? when raw.isNotEmpty) {
            values[option] = option._parse(raw);
            continue;
          }
        }
        if (option._isRequired) {
          final hint = option._env == null ? '' : ' (or set ${option._env})';
          throw UsageException('Missing required option "--${option.name}"$hint.');
        }
      }
    }

    _bind(rest, values);

    if (_root case final Cli cli) cli._applyLevel(values);

    if (handler != null) {
      await handler!(CliContext(rest, values, this, cancel: cancel));
    } else if (_subcommands.isNotEmpty) {
      // A program of subcommands run with none was not asked for help: the usage is the
      // answer to a mistake, on stderr, and the exit code says so.
      _printUsage(Io.err);
      throw const _NoCommand();
    } else {
      _printUsage();
    }
  }
}

/// No command was named where one had to be. The usage already said what there is, so
/// [Cli.run] adds nothing to it and exits 64.
final class _NoCommand extends UsageException {
  const _NoCommand() : super('No command given.');
}

/// The root command: a program's name, version and entry point.
///
/// Every program gets `-v`/`--verbose` (debug logging) and `-q`/`--quiet` (warnings and
/// errors only), mapped onto [Console.level] before the handler runs, and `--completion
/// bash|zsh|fish`, which prints a completion script for the declared tree. A program that
/// declares an option of the same name or short form keeps its own.
///
/// {@category CLI}
class Cli extends CliCommand {
  /// Printed by `--version` when set.
  final String? version;

  final CliOption<bool>? _verbose;
  final CliOption<bool>? _quiet;

  Cli({
    String name = 'app',
    String description = '',
    String? version,
    Iterable<CliValue<Object?>> values = const [],
    Iterable<CliCommand> commands = const [],
    CommandHandler? handler,
  }) : this._(
         name,
         description,
         version,
         values,
         commands,
         handler,
         _builtIn(values, 'verbose', 'v', 'Show debug output'),
         _builtIn(values, 'quiet', 'q', 'Show only warnings and errors'),
       );

  Cli._(
    super.name,
    String description,
    this.version,
    Iterable<CliValue<Object?>> values,
    Iterable<CliCommand> commands,
    CommandHandler? handler,
    this._verbose,
    this._quiet,
  ) : super(description: description, values: [...values, ?_verbose, ?_quiet], commands: commands, handler: handler);

  /// A built-in flag, unless [declared] already has one by that name; without its short
  /// form when that is taken.
  static CliOption<bool>? _builtIn(Iterable<CliValue<Object?>> declared, String long, String short, String help) {
    final options = declared.whereType<CliOption<Object?>>();
    return options.any((o) => o.name == long)
        ? null
        : Opt.flag(long, abbr: options.any((o) => o.abbr == short) ? null : short, description: help);
  }

  void _applyLevel(Map<CliValue<Object?>, Object?> values) {
    if (values[_verbose] == true) {
      Console.level = LogLevel.debug;
    } else if (values[_quiet] == true) {
      Console.level = LogLevel.warn;
    }
  }

  /// Parses [args], runs the matching command, then runs the exit hooks and releases
  /// the signal handlers so the process can end — whether the action returned or threw.
  ///
  /// A usage error — unknown option or command, bad choice, missing required option — is
  /// printed to stderr and exits with code 64. Anything else the action throws is printed
  /// as `✖ error` and exits with code 1, its stack trace shown under `--verbose`: no script
  /// needs a try/catch of its own to fail readably. [CliCommand.run] throws instead; use it
  /// to test. `ctx.cancel` is cancelled first on a signal, on [Lifecycle.exit], and when the
  /// action ends.
  ///
  /// The action runs inside a [Cancel.scope] holding that token, so everything under it
  /// — downloads, crawls, `retry`, `run` — stops with it and takes no token of its own.
  @override
  Future<void> run(List<String> args) async {
    final cancel = CancelToken();
    Lifecycle.onExit(cancel.cancel);
    try {
      await Cancel.scope(() => _run(args, {}, cancel), token: cancel);
    } on _NoCommand {
      await Lifecycle.exit(null, 64);
    } on UsageException catch (e) {
      final cmd = e.command ?? _fullName;
      await Lifecycle.exit('${e.message}\n  Run "$cmd --help" for usage.', 64);
    } catch (e, trace) {
      // A signal is already on its way out through the exit hooks; what the action threw
      // on being cancelled is not news.
      if (_exiting) await Completer<Never>().future;
      Console.debug('$trace');
      await Lifecycle.exit('$e', 1);
    } finally {
      await _runExitHooks();
      Lifecycle.onExit(null);
    }
  }
}
