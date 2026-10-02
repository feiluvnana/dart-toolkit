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

/// What runs a [CliCommand].
typedef CommandHandler = FutureOr<void> Function(CliContext ctx);

/// Something a [CliCommand] declares and a handler reads back through [CliContext.call]:
/// an [Opt], written `--name`, or an [Arg], written by its position.
///
/// The declaration is the key, so a name is written once and its type comes back:
///
/// ```dart
/// final top = Opt.number('top', 'How many to show').abbr('n').or(10);
/// final id  = Arg.text('id').required();
/// …
/// ctx(top)  // an int, statically
/// ctx(id)   // a String, statically
/// ```
///
/// Both are nullable until `or` gives a default or `required` insists on one; a flag is
/// always a `bool`.
///
/// {@category CLI}
sealed class CliValue<T> {
  /// What it is called: in `--name` for an option, in `<name>` for an argument.
  final String name;

  /// Help text shown by `--help`.
  final String description;

  const CliValue(this.name, {this.description = ''});

  /// The value of [raw], or a [UsageException].
  T _parse(String raw);

  T? get _or;

  bool get _isRequired;

  List<Object?>? get _choices => null;

  /// What help writes after the name: `<int>`, `<a|b>`.
  String get _hint;
}

/// An option declared on a [CliCommand], written `--name` or `-n`. See [Opt].
///
/// {@category CLI}
sealed class CliOption<T> extends CliValue<T> {
  final String? _abbr;

  /// Read when the option is not on the command line.
  final String? _env;

  const CliOption(super.name, {super.description, String? abbr, String? env})
    : _abbr = abbr,
      _env = env,
      assert(abbr == null || abbr.length == 1, 'abbr is one character');

  bool get _takesValue => true;

  /// How a second occurrence combines with the first, or `null` when the last one wins.
  _Join? get _join => null;

  /// The same option, falling back to the environment variable [name] when it is not on
  /// the command line: `Opt.text('token').env('GITHUB_TOKEN').required()`.
  ///
  /// A set variable satisfies `required()`, and `--help` shows it as `[env: NAME]`. An
  /// empty one is treated as unset.
  CliOption<T> env(String name);

  /// The same option, also written as `-` and [letter]: `Opt.number('top').abbr('n')` takes
  /// `-n 5`. A chain step like [env], so the description can be the second positional.
  CliOption<T> abbr(String letter);
}

/// A positional argument: typed, defaulted and required like an option, and shown in the
/// usage line.
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

  /// Set for a variadic argument: at most one per command, and last.
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
  static Arg<String?> text(String name, [String description = '']) =>
      Arg<String?>._(name, parse: (raw) => raw, hint: '<text>', description: description);

  /// An integer argument, rejected during parsing when it is not one.
  static Arg<int?> number(String name, [String description = '']) =>
      Arg<int?>._(name, parse: (raw) => _int('argument <$name>', raw), hint: '<int>', description: description);

  /// An argument restricted to [values], matched by [Enum.name] or `toString()`.
  static Arg<V?> among<V>(String name, List<V> values, [String description = '']) => Arg<V?>._(
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
  static Arg<V?> by<V>(String name, V Function(String raw) parse, [String description = '']) => Arg<V?>._(
    name,
    parse: (raw) => _guard('argument <$name>', parse, raw),
    hint: '<value>',
    description: description,
  );

  @override
  T _parse(String raw) => _parseValue(raw);

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

/// What makes an [Arg]'s value guaranteed, so [CliContext.call] is non-nullable; as [OptionalOpt].
///
/// {@category CLI}
extension OptionalArg<T extends Object> on Arg<T?> {
  /// The same argument with [value] when it is absent.
  Arg<T> or(T value) => _as(or: _allowed(_choices, value));

  /// The same argument, but parsing fails when it is absent — for a variadic one, when
  /// nothing at all was given.
  Arg<T> required() => _as(required: true);

  /// The same argument, taking everything that is left: `tk hash <paths>...`. None is `[]`;
  /// `.many().required()` insists on one. At most one per command, declared last.
  Arg<List<T>> many() => _as(
    parse: (raw) => [_parse(raw) as T],
    or: List<T>.unmodifiable(const []),
    join: (previous, next) => <T>[...previous! as List<T>, ...next! as List<T>],
  );
}

/// A boolean option; `--dry=false` and `--no-dry` say false, and any other `=value` is a
/// usage error, never a silent `true`.
final class _Flag extends CliOption<bool> {
  const _Flag(super.name, {super.description, super.abbr, super.env, bool or = false}) : _or = or;

  @override
  final bool _or;

  @override
  bool _parse(String raw) => switch (raw.toLowerCase()) {
    'true' || '1' || 'yes' => true,
    'false' || '0' || 'no' => false,
    _ => throw UsageException('Option "--$name" is a flag: it takes true or false, not "$raw".'),
  };

  @override
  bool get _isRequired => false;

  @override
  bool get _takesValue => false;

  @override
  String get _hint => '';

  @override
  CliOption<bool> env(String name) => _Flag(this.name, description: description, abbr: _abbr, env: name, or: _or);

  @override
  CliOption<bool> abbr(String letter) => _Flag(name, description: description, abbr: letter, env: _env, or: _or);
}

/// An option: a flag, a string, an integer, one of a fixed set, or what a function returns.
///
/// All but [flag] are nullable until [OptionalOpt.or] or [OptionalOpt.required];
/// [OptionalOpt.many] repeats it, [env] reads it from the environment.
///
/// ```dart
/// final dry     = Opt.flag('dry-run', 'Print, do not write').abbr('d'); // bool
/// final out     = Opt.text('out').abbr('o');                       // String?
/// final to      = Opt.text('to').abbr('t').required();             // String
/// final top     = Opt.number('top', 'How many to show').or(10);    // int
/// final algo    = Opt.among('algo', Hash.values).or(Hash.sha256);  // Hash
/// final since   = Opt.by('since', DateTime.parse);                 // DateTime?
/// final headers = Opt.text('header').abbr('H').many();             // List<String>
/// final token   = Opt.text('token').env('GITHUB_TOKEN').required(); // String
/// ```
///
/// The second positional is the help text; [abbr] adds the short form.
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
  static CliOption<bool> flag(String name, [String description = '']) => _Flag(name, description: description);

  /// A string option.
  static Opt<String?> text(String name, [String description = '']) =>
      Opt<String?>._(name, parse: (raw) => raw, hint: '<text>', description: description);

  /// An integer option, rejected during parsing when it is not one.
  static Opt<int?> number(String name, [String description = '']) =>
      Opt<int?>._(name, parse: (raw) => _int('option "--$name"', raw), hint: '<int>', description: description);

  /// An option restricted to [values], matched by [Enum.name] or `toString()`.
  static Opt<V?> among<V>(String name, List<V> values, [String description = '']) => Opt<V?>._(
    name,
    parse: (raw) => _among('option "--$name"', values, raw),
    hint: _choiceHint(values),
    description: description,
    choices: values,
  );

  /// An option parsed by [parse]; anything it throws becomes a [UsageException].
  static Opt<V?> by<V>(String name, V Function(String raw) parse, [String description = '']) => Opt<V?>._(
    name,
    parse: (raw) => _guard('option "--$name"', parse, raw),
    hint: '<value>',
    description: description,
  );

  @override
  T _parse(String raw) => _parseValue(raw);

  @override
  Opt<T> env(String name) => _as(parse: _parseValue, env: name, or: _or, required: _isRequired, join: _join);

  @override
  Opt<T> abbr(String letter) => _as(parse: _parseValue, abbr: letter, or: _or, required: _isRequired, join: _join);

  /// The same option as an [Opt] of [U]: everything carried over but what is given here.
  Opt<U> _as<U>({
    U Function(String raw)? parse,
    String? env,
    String? abbr,
    U? or,
    bool required = false,
    _Join? join,
  }) => Opt<U>._(
    name,
    parse: parse ?? (raw) => _parse(raw) as U,
    hint: _hint,
    description: description,
    abbr: abbr ?? _abbr,
    env: env ?? _env,
    choices: _choices,
    or: or,
    required: required,
    join: join,
  );
}

/// A flag's default.
///
/// {@category CLI}
extension FlagOr on CliOption<bool> {
  /// The same flag, [value] when absent: `Opt.flag('color', 'Colour output').or(true)` is on
  /// until `--no-color`, and `--help` shows it as `--[no-]color`.
  CliOption<bool> or(bool value) => switch (this) {
    final _Flag f => _Flag(f.name, description: f.description, abbr: f._abbr, env: f._env, or: value),
    final Opt<bool> o => o._as(or: value),
  };
}

/// What makes an [Opt]'s value guaranteed, so [CliContext.call] is non-nullable.
///
/// {@category CLI}
extension OptionalOpt<T extends Object> on Opt<T?> {
  /// The same option with [value] when it is absent; [ArgumentError] when [value] is not
  /// among its choices.
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

/// Folds a repeated value into the first. Untyped: a generic function type would not survive
/// being read through a `CliOption<Object?>`.
typedef _Join = Object? Function(Object? previous, Object? next);

/// [value], when [choices] allows it: a default the parser would reject is a declaration bug.
T _allowed<T>(List<Object?>? choices, T value) {
  if (choices != null && !choices.contains(value)) {
    throw ArgumentError.value(value, 'value', 'Not one of ${choices.map(_label).join(', ')}');
  }
  return value;
}

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
  /// Positional arguments as typed, plus everything after `--`; the [Arg]s are bound from it.
  final List<String> rest;

  /// Cancelled on SIGINT, SIGTERM and [Lifecycle.exit], before the other exit hooks run.
  /// [Cli.run] makes it the ambient [Cancel.token], so what runs inside already stops with it.
  final CancelToken cancel;

  final Map<CliValue<Object?>, Object?> _values;

  CliContext._(this.rest, Map<CliValue<Object?>, Object?> values, {CancelToken? cancel})
    : _values = values,
      cancel = cancel ?? CancelToken();

  /// The value of [value], typed by its declaration.
  ///
  /// ```dart
  /// if (ctx(dry)) return;
  /// final n = ctx(top); // int, because `top` was declared with `.or(10)`
  /// ```
  T call<T>(CliValue<T> value) {
    if (_values.containsKey(value)) return _values[value] as T;
    if (value._or case final fallback?) return fallback;
    if (null is T) return null as T;
    throw StateError('${value is Arg ? '<${value.name}>' : '--${value.name}'} was not given and has no default.');
  }

  /// Whether [value] was given, on the command line or by its [CliOption.env], not defaulted.
  bool given(CliValue<Object?> value) => _values.containsKey(value);
}

/// A command: a name, the values it takes, subcommands and the handler that runs it.
///
/// `values` holds its [Arg]s and [Opt]s in one list; the [Arg]s bind in the order listed.
///
/// ```dart
/// CliCommand('fetch', 'Fetch a thing', values: [url, verbose], handler: fetch)
/// ```
///
/// {@category CLI}
class CliCommand {
  final String name;
  final String description;

  /// What runs when this command is dispatched; `null` prints usage.
  final CommandHandler? handler;

  final List<Arg<Object?>> _args;
  final List<CliOption<Object?>> _options;
  final Map<String, CliCommand> _subcommands;
  CliCommand? _parent;

  /// [description] is the line `--help` shows for it, here and in its parent's list.
  CliCommand(
    this.name,
    this.description, {
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

  /// The nearest option named [name], here or in an ancestor.
  CliOption<Object?>? _findOption(String name) =>
      _options.where((o) => o.name == name).firstOrNull ?? _parent?._findOption(name);

  /// The nearest option with short form [abbr], here or in an ancestor.
  CliOption<Object?>? _findAbbr(String abbr) =>
      _options.where((o) => o._abbr == abbr).firstOrNull ?? _parent?._findAbbr(abbr);

  /// This command, then each ancestor up to the root.
  Iterable<CliCommand> get _chain sync* {
    for (CliCommand? cur = this; cur != null; cur = cur._parent) {
      yield cur;
    }
  }

  /// Prints usage to [sink]: stdout for `--help`, stderr as the answer to a mistake.
  void _printUsage([StringSink? sink]) {
    final out = sink ?? Io.out;
    final shape = [for (final arg in _args) arg._placeholder, '[options]', if (_subcommands.isNotEmpty) '[command]'];
    out.writeln('${'Usage:'.bold} $_fullName ${shape.join(' ')}');
    if (description.isNotEmpty) out.writeln('\n$description');

    // One column as wide as the widest left side: `-a, --algo <md5|sha1>` overflows a fixed 20.
    final inherited = [for (final cmd in _chain.skip(1)) ...cmd._options];
    final args = [for (final arg in _args) (arg._placeholder, _describe(arg))];
    final commands = [for (final sub in _subcommands.values) (sub.name, sub.description)];
    final options = [
      ..._optionRows(_options),
      if (_findOption('help') == null)
        (_findAbbr('h') == null ? '-h, --help' : '    --help', 'Print this help message'),
      if (_parent == null && _version != null && _findOption('version') == null) ('    --version', 'Print the version'),
      if (_parent == null && this is Cli && _findOption('completion') == null)
        ('    --completion <shell>', 'Print a completion script (bash, zsh, fish)'),
    ];
    // An ancestor's options are accepted here too, shown apart.
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
      // One shadowed by a nearer name is unreachable; one whose short form was taken has its long form only.
      if (_findOption(option.name) == option)
        (
          '${option._abbr != null && _findAbbr(option._abbr) == option ? '-${option._abbr}, ' : '    '}'
              '--${option._takesValue || option._or != true ? '' : '[no-]'}${option.name}'
              '${option._takesValue ? ' ${option._hint}' : ''}',
          // A flag's `false` default is what absence means; saying so is noise.
          _describe(option, fallback: option._takesValue || option._or == true),
        ),
  ];

  /// The help line for an argument or an option: what it is for, may be, and defaults to.
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

  /// Binds the positionals to the declared arguments, in order; with none declared, nothing
  /// is checked.
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

  /// Stores [value] for [option]: a repeatable one adds to what is there.
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
    // Taking `-h` takes `-h` only: a command with `--host -h` still answers `--help`.
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
          if (_subcommands[arg] case final sub?) return sub._run(args.sublist(i + 1), values, cancel);
          // Naming none is a typo, unless this command takes positionals of its own.
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

    // The environment fills what the command line left out; then required checks, up the chain.
    for (final cmd in _chain) {
      for (final option in cmd._options) {
        if (values.containsKey(option)) continue;
        if (option._env case final variable?) {
          if (Env.getOrNull(variable) case final raw?) {
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
      await handler!(CliContext._(rest, values, cancel: cancel));
    } else if (_subcommands.isNotEmpty) {
      // Run with no subcommand: a mistake, so usage goes to stderr and the exit is 64.
      _printUsage(Io.err);
      throw const _NoCommand();
    } else {
      _printUsage();
    }
  }
}

/// No command was named where one had to be; the usage already said so, and [Cli.run] exits 64.
final class _NoCommand extends UsageException {
  const _NoCommand() : super('No command given.');
}

/// The root command: a program's name, version and entry point.
///
/// Every program gets `-v`/`--verbose` and `-q`/`--quiet` (onto [Console.level]) and
/// `--completion bash|zsh|fish`; one that declares the same name or short form keeps its own.
///
/// {@category CLI}
class Cli extends CliCommand {
  /// Printed by `--version` when set.
  final String? version;

  final CliOption<bool>? _verbose;
  final CliOption<bool>? _quiet;

  /// [name] defaults to the script's: `bin/tk.dart`, pub's `tk.dart-3.x.snapshot` and a
  /// compiled `tk.exe` are all `tk`.
  Cli({
    String? name,
    String description = '',
    String? version,
    Iterable<CliValue<Object?>> values = const [],
    Iterable<CliCommand> commands = const [],
    CommandHandler? handler,
  }) : this._(
         name ?? _scriptName(),
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
    super.description,
    this.version,
    Iterable<CliValue<Object?>> values,
    Iterable<CliCommand> commands,
    CommandHandler? handler,
    this._verbose,
    this._quiet,
  ) : super(values: [...values, ?_verbose, ?_quiet], commands: commands, handler: handler);

  /// The script's file name, less what `dart run`, pub and `dart compile` put after it.
  static String _scriptName() {
    final script = Platform.script;
    if (script.scheme != 'file' || script.pathSegments.isEmpty) return 'app';
    final name = script.pathSegments.last.replaceFirst(_scriptSuffix, '');
    return name.isEmpty ? 'app' : name;
  }

  static final _scriptSuffix = RegExp(r'(\.dart)?(-[\w.]+)?\.(snapshot|dill|aot|jit)$|\.dart$|\.exe$');

  /// A built-in flag, unless [declared] has the name; without [short] when that is taken.
  static CliOption<bool>? _builtIn(Iterable<CliValue<Object?>> declared, String long, String short, String help) {
    final options = declared.whereType<CliOption<Object?>>();
    return options.any((o) => o.name == long)
        ? null
        : switch (Opt.flag(long, help)) {
            final flag when options.any((o) => o._abbr == short) => flag,
            final flag => flag.abbr(short),
          };
  }

  void _applyLevel(Map<CliValue<Object?>, Object?> values) {
    if (values[_verbose] == true) {
      Console.level = LogLevel.debug;
    } else if (values[_quiet] == true) {
      Console.level = LogLevel.warn;
    }
  }

  /// Parses [args], runs the matching command inside a [Cancel.scope], then runs the exit
  /// hooks and releases the signal handlers, whether the action returned or threw.
  ///
  /// To fail, `throw`: `throw 'no URL given'` prints `✖ no URL given` and exits 1 (stack
  /// trace under `--verbose`). A usage error exits 64. [CliCommand.run] throws instead; use
  /// it to test. A `print` in the action lands above a live spinner, as [Console.writeln].
  @override
  Future<void> run(List<String> args) async {
    final cancel = CancelToken();
    Lifecycle.onExit(cancel.cancel);
    try {
      await runZoned(
        () => Cancel.scope(() => _run(args, {}, cancel), token: cancel),
        zoneSpecification: ZoneSpecification(print: (_, _, _, line) => Console.writeln(line)),
      );
    } on _NoCommand {
      await Lifecycle.exit(null, 64);
    } on UsageException catch (e) {
      final cmd = e.command ?? _fullName;
      await Lifecycle.exit('${e.message}\n  Run "$cmd --help" for usage.', 64);
    } catch (e, trace) {
      // A signal is already leaving through the exit hooks; a throw from being cancelled is not news.
      if (_exiting) await Completer<Never>().future;
      Console.debug('$trace');
      await Lifecycle.exit(e, 1);
    } finally {
      await _runExitHooks();
      Lifecycle.onExit(null);
    }
  }
}
