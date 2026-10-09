part of '../cli.dart';

/// A command line the program cannot act on: an unknown option, a bad value, a missing argument.
/// `Cli.run` prints it in one line, with where to find the usage, and exits 64; a handler throws
/// one for a mistake only it can see.
///
/// ```dart
/// if (matches.isEmpty) throw UsageException('No files match ${ctx(pattern)}');
/// ```
///
/// {@category CLI}
final class UsageException implements Exception {
  final String message;
  final String? _command;

  const UsageException(this.message) : _command = null;

  const UsageException._(this.message, this._command);

  @override
  String toString() => message;
}

/// What a value is: an option or an argument, its names, and how its text is read.
final class _Spec {
  final bool option;
  final String name, help;
  final String? short, env;

  /// The value of a raw string, or a [UsageException].
  final Object? Function(String raw) parse;

  /// What help writes after the name: `<int>`, `<a|b>`; `''` for a flag.
  final String hint;
  final List<Object?>? choices;
  final bool flag;

  /// The values of a repeated one, as the list its declaration's type names.
  final List<Object?> Function(Iterable<Object?> values) list;

  const _Spec(
    this.option,
    this.name,
    this.help,
    this.parse,
    this.hint, {
    this.short,
    this.env,
    this.choices,
    this.flag = false,
    this.list = _untyped,
  });

  /// This spec, its repeated values a `List<T>`.
  _Spec listOf<T>() => _Spec(
    option,
    name,
    help,
    parse,
    hint,
    short: short,
    env: env,
    choices: choices,
    flag: flag,
    list: (values) => List<T>.unmodifiable(values.cast<T>()),
  );

  static List<Object?> _untyped(Iterable<Object?> values) => List.unmodifiable(values);

  /// How errors and help name it: `--top`, `<files>`.
  String get shown => option ? '--$name' : '<$name>';

  String get what => option ? 'option "--$name"' : 'argument <$name>';
}

/// Something a command declares and its handler reads back with `ctx(value)`: an [Option],
/// written `--name`, or an [Arg], written by its position. The declaration is the key, so its
/// type comes back:
///
/// ```dart
/// final top   = Option.of<int>('top', 'How many to show', short: 'n').or(10);   // int
/// final files = Arg.of<String>('files', 'Inputs').many().required();            // List<String>
/// … ctx(top) … ctx(files) …
/// ```
///
/// An [Option] or [Arg] is nullable until a step makes it more: [Option.or] → [Defaulted],
/// [Option.required] → [Required], [Option.many] → [Many]; each type offers only the steps that
/// still make sense.
///
/// {@category CLI}
sealed class CliValue<T> {
  final _Spec _spec;
  final Object? _or;
  final bool _hasOr, _isRequired, _isMany;

  const CliValue._(this._spec, {Object? or, bool hasOr = false, bool required = false, bool many = false})
    : _or = or,
      _hasOr = hasOr,
      _isRequired = required,
      _isMany = many;

  /// What it is called: `--name` for an option, `<name>` for an argument.
  String get name => _spec.name;

  /// What `--help` says it is for.
  String get help => _spec.help;

  String? get _short => _spec.short;
  String? get _env => _spec.env;
  String get _hint => _spec.hint;
  List<Object?>? get _choices => _spec.choices;
  bool get _takesValue => !_spec.flag;
  bool get _variadic => _isMany && !_spec.option;

  /// The value when it was not given: its default, `[]` for many, `false` for a flag, else `null`.
  Object? get _absent => _hasOr ? _or : (_isMany ? const <Never>[] : (_spec.flag ? false : null));

  /// How the usage line writes an argument: `<id>`, `[id]`, `<paths>...`, `[paths...]`.
  String get _placeholder => switch ((_isRequired, _isMany)) {
    (true, true) => '<$name>...',
    (true, false) => '<$name>',
    (false, true) => '[$name...]',
    (false, false) => '[$name]',
  };
}

/// An option, `--name value` or `-n value`: typed ([of]), one of a set ([among]), read by a
/// function ([by]), or a [flag]. The help text is always the second argument.
///
/// ```dart
/// final dry  = Option.flag('dry-run', 'Print, do not write', short: 'd');      // bool
/// final out  = Option.of<String>('out', 'Write here', short: 'o');             // String?
/// final top  = Option.of<int>('top', 'How many to show').or(10);               // int
/// final env  = Option.among('env', 'Where to deploy', values: Target.values);  // Target?
/// final port = Option.by('port', 'A port', parse: Port.parse).required();      // Port
/// final tags = Option.of<String>('tag', 'A tag', short: 't').many();           // List<String>
/// ```
///
/// [short] is the one-letter form; [env] names a variable read when the option is not on the
/// command line (a set one satisfies [required]; `--help` shows it).
///
/// {@category CLI}
final class Option<T extends Object> extends CliValue<T?> {
  const Option._(super._spec) : super._();

  /// A [T] option: `String`, `int`, `double`, `num`, `Duration`, `DateTime`, `Uri`, `Path` or
  /// `Secret`, read as `'…'.to<T>()` reads text. A `bool` is a [flag].
  static Option<T> of<T extends Object>(String name, String help, {String? short, String? env}) {
    if (T == bool) {
      throw ArgumentError.value(name, 'name', 'Invalid Option.of<bool>: a yes-or-no option is Option.flag');
    }
    return Option._(_typedSpec<T>(true, name, help, short: short, env: env));
  }

  /// An option that is one of [values], matched by an enum's `name` or `toString()`.
  static Option<V> among<V extends Object>(
    String name,
    String help, {
    required List<V> values,
    String? short,
    String? env,
  }) => Option._(_among(true, name, help, values, short: short, env: env));

  /// An option read by [parse]; what it throws is a usage error naming the option.
  static Option<V> by<V extends Object>(
    String name,
    String help, {
    required V Function(String raw) parse,
    String? short,
    String? env,
  }) => Option._(_by(true, name, help, parse, short: short, env: env));

  /// A yes-or-no option: present means true, absent false, and `.or(true)` makes it on until
  /// `--no-name`. `--name=false` says false; any other value is a usage error.
  static Flag flag(String name, String help, {String? short, String? env}) =>
      Flag._(_check(_Spec(true, name, help, (raw) => _flag(name, raw), '', short: short, env: env, flag: true)));

  /// [value] when it is not given.
  Defaulted<T> or(T value) => Defaulted._(_spec, _allowed(_spec, value));

  /// A usage error when it is not given.
  Required<T> required() => Required._(_spec);

  /// Taken any number of times: `-t a -t b` is `['a', 'b']`; none is `[]`.
  Many<T> many() => Many._(_spec.listOf<T>());
}

/// A positional argument, bound in the order declared: typed, one of a set or read by a
/// function, as an [Option] is. A [many] argument takes what is left and comes last; an optional
/// one comes after every required one.
///
/// ```dart
/// final id    = Arg.of<String>('id', 'The build to ship').required();   // String
/// final count = Arg.of<int>('count', 'How many').or(1);                  // int
/// final files = Arg.of<Path>('files', 'Inputs').many().required();      // List<Path>, ≥ 1
/// ```
///
/// {@category CLI}
final class Arg<T extends Object> extends CliValue<T?> {
  const Arg._(super._spec) : super._();

  /// A [T] argument, as [Option.of] reads one (`bool` included).
  static Arg<T> of<T extends Object>(String name, String help) => Arg._(_typedSpec<T>(false, name, help));

  /// An argument that is one of [values].
  static Arg<V> among<V extends Object>(String name, String help, {required List<V> values}) =>
      Arg._(_among(false, name, help, values));

  /// An argument read by [parse]; what it throws is a usage error naming the argument.
  static Arg<V> by<V extends Object>(String name, String help, {required V Function(String raw) parse}) =>
      Arg._(_by(false, name, help, parse));

  /// [value] when it is not given.
  Defaulted<T> or(T value) => Defaulted._(_spec, _allowed(_spec, value));

  /// A usage error when it is not given.
  Required<T> required() => Required._(_spec);

  /// Everything left on the command line; none is `[]`.
  Many<T> many() => Many._(_spec.listOf<T>());
}

/// A yes-or-no [Option]: `false` unless given, or [or]'s default.
///
/// {@category CLI}
final class Flag extends CliValue<bool> {
  const Flag._(super._spec) : super._();

  /// On by default: `--no-name` turns it off, and `--help` shows `--[no-]name`.
  Defaulted<bool> or(bool value) => Defaulted._(_spec, value);
}

/// A value with a default: never `null`.
///
/// {@category CLI}
final class Defaulted<T> extends CliValue<T> {
  const Defaulted._(super._spec, T value, {super.many}) : super._(or: value, hasOr: true);
}

/// A value that must be given: a usage error when it is not.
///
/// {@category CLI}
final class Required<T> extends CliValue<T> {
  const Required._(super._spec, {super.many}) : super._(required: true);
}

/// A value given any number of times, as a list in the order given.
///
/// {@category CLI}
final class Many<T> extends CliValue<List<T>> {
  const Many._(super._spec) : super._(many: true);

  /// [values] when none is given.
  Defaulted<List<T>> or(List<T> values) =>
      Defaulted._(_spec, List.unmodifiable([for (final v in values) _allowed(_spec, v)]), many: true);

  /// A usage error when none is given.
  Required<List<T>> required() => Required._(_spec, many: true);
}

_Spec _check(_Spec spec) {
  if (spec.name.isEmpty || spec.name.startsWith('-') || spec.name.contains(RegExp(r'[\s=]'))) {
    throw ArgumentError.value(spec.name, 'name', 'Invalid name, expected a word without dashes in front');
  }
  if (spec.short case final s? when s.length != 1 || s == '-') {
    throw ArgumentError.value(s, 'short', 'Invalid short, expected one character');
  }
  return spec;
}

/// A [T] read as every typed reading reads text; a type with no reading is an [ArgumentError].
_Spec _typedSpec<T extends Object>(bool option, String name, String help, {String? short, String? env}) {
  final (hint, expected) = switch (T) {
    const (String) => ('<text>', 'text'),
    const (int) => ('<int>', 'an integer'),
    const (double) || const (num) => ('<number>', 'a number'),
    const (bool) => ('<bool>', 'true or false'),
    const (Duration) => ('<duration>', 'a duration such as 90s or 1h30m'),
    const (DateTime) => ('<date>', 'a date such as 2026-10-08'),
    const (Uri) => ('<url>', 'a URL'),
    const (Secret) => ('<secret>', 'a secret'),
    _ => throw ArgumentError.value(
      T,
      'T',
      'Unsupported type for ${option ? '--' : '<'}$name: use String, int, double, num, Duration, DateTime, Uri, '
          'Path or Secret, or by(parse:)',
    ),
  };
  late final _Spec spec;
  Object? parse(String raw) =>
      CoerceBridge.coerce<T>(raw) ??
      (throw UsageException('Invalid value "$raw" for ${spec.what}: expected $expected'));
  return spec = _check(_Spec(option, name, help, parse, hint, short: short, env: env));
}

/// One of [values], matched by an enum's `name` or `toString()`.
_Spec _among<V>(bool option, String name, String help, List<V> values, {String? short, String? env}) {
  if (values.isEmpty) throw ArgumentError.value(values, 'values', 'Invalid values: none to choose from');
  late final _Spec spec;
  Object? parse(String raw) => values.firstWhere(
    (v) => _label(v) == raw,
    orElse: () =>
        throw UsageException('Invalid value "$raw" for ${spec.what}: expected ${values.map(_label).join(', ')}'),
  );
  return spec = _check(_Spec(option, name, help, parse, _choiceHint(values), short: short, env: env, choices: values));
}

/// What [read] returns; anything it throws is a [UsageException] naming the value.
_Spec _by<V>(bool option, String name, String help, V Function(String raw) read, {String? short, String? env}) {
  late final _Spec spec;
  Object? parse(String raw) {
    try {
      return read(raw);
    } on UsageException {
      rethrow;
    } catch (e) {
      throw UsageException('Invalid value "$raw" for ${spec.what}: ${e is FormatException ? e.message : e}');
    }
  }

  return spec = _check(_Spec(option, name, help, parse, '<value>', short: short, env: env));
}

bool _flag(String name, String raw) => switch (raw.toLowerCase()) {
  'true' || '1' || 'yes' => true,
  'false' || '0' || 'no' => false,
  _ => throw UsageException('Invalid value "$raw" for option "--$name": a flag takes true or false'),
};

/// [value], when [spec]'s choices allow it: a default the parser would refuse is a mistake.
T _allowed<T>(_Spec spec, T value) {
  if (spec.choices case final choices? when !choices.contains(value)) {
    throw ArgumentError.value(
      value,
      'value',
      'Invalid default for ${spec.shown}: not one of ${choices.map(_label).join(', ')}',
    );
  }
  return value;
}

/// `<a|b|c>`, or `<choice>` when spelling every one out would crowd the help line.
String _choiceHint(List<Object?> values) {
  final all = values.map(_label).join('|');
  return all.length <= 24 ? '<$all>' : '<choice>';
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
      (previous, current) = (current, previous);
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

// ---- the context -----------------------------------------------------------------------------

/// What a handler is handed: the values it declared, `ctx(value)`, and the [Work] of the run, so
/// `ctx.defer(cleanup)` runs when the run ends, however it ends. [store] is the program's own.
///
/// ```dart
/// handler: (ctx) async {
///   final chrome = await Chrome.launch();
///   ctx.defer(chrome.close);
///   final seen = await ctx.store.read(seenKey);
///   for (final f in ctx(files)) …
/// }
/// ```
///
/// {@category CLI}
final class CliContext implements Work {
  final CliCommand _command;
  final Map<CliValue<Object?>, Object?> _values;
  final Work _work;
  final String _program;
  final _cleanups = <FutureOr<void> Function()>[];
  Status<Object?, Object?>? _ended;

  CliContext._(this._command, this._values, this._work, this._program);

  /// The program's own store, `Store.app(<program name>)`: for its keys and sub-stores.
  late final Store store = Store.app(_program);

  /// The value of [value], typed by its declaration. One this command does not declare (nor an
  /// ancestor, for an option) is a [StateError].
  T call<T>(CliValue<T> value) {
    if (!_command._declares(value)) {
      throw StateError('Cannot read ${value._spec.shown}: it is not declared on "${_command._fullName}"');
    }
    if (_values.containsKey(value)) return _values[value] as T;
    return value._absent as T;
  }

  /// Whether [value] was given, on the command line or by its option's `env:`, not defaulted.
  bool given(CliValue<Object?> value) => _values.containsKey(value);

  @override
  void amount(int received, {int? total, Unit unit = Unit.bytes}) => _work.amount(received, total: total, unit: unit);

  @override
  void step(String phrase) => _work.step(phrase);

  @override
  void warn(String note) => _work.warn(note);

  /// Runs [cleanup] when the run ends, however it ends (done, failed, ^C), last deferred first,
  /// within ten seconds in all.
  @override
  void defer(FutureOr<void> Function() cleanup) {
    if (_ended != null) throw StateError('Cannot defer a cleanup: the run has ended');
    _cleanups.add(cleanup);
  }

  @override
  Status<Object?, Object?>? get ended => _ended;

  @override
  bool get isStopped => _work.isStopped;
}

// ---- commands --------------------------------------------------------------------------------

/// A command: a name, a line of [help], the values it takes, its subcommands, and the handler
/// that runs it. [aliases] are other names it answers to.
///
/// ```dart
/// final build = CliCommand('build', 'Builds the site.', values: [out], handler: (ctx) async { … });
/// ```
///
/// {@category CLI}
class CliCommand {
  final String name;

  /// The line `--help` shows for it, here and in its parent's list.
  final String help;
  final List<String> aliases;

  /// What runs when this command is named; `null` prints its usage.
  final FutureOr<void> Function(CliContext ctx)? handler;

  final List<CliValue<Object?>> _args;
  final List<CliValue<Object?>> _options;
  final Map<String, CliCommand> _subcommands;
  final Map<String, CliCommand> _named;
  CliCommand? _parent;

  CliCommand(
    this.name,
    this.help, {
    this.handler,
    Iterable<CliValue<Object?>> values = const [],
    Iterable<CliCommand> commands = const [],
    Iterable<String> aliases = const [],
  }) : aliases = List.unmodifiable(aliases),
       _args = List.unmodifiable(values.where((v) => !v._spec.option)),
       _options = List.unmodifiable(values.where((v) => v._spec.option)),
       _subcommands = {for (final c in commands) c.name: c},
       _named = {
         for (final c in commands) ...{c.name: c, for (final a in c.aliases) a: c},
       } {
    _checkValues();
    for (final c in _subcommands.values) {
      if (c._parent != null) throw ArgumentError.value(c.name, 'commands', 'Invalid command: it already has a parent');
      c._parent = this;
    }
  }

  /// Positional order and names, checked as it is built: in release builds too.
  void _checkValues() {
    final names = <String>{};
    final shorts = <String>{};
    for (final v in [..._args, ..._options]) {
      if (!names.add('${v._spec.option}${v.name}')) {
        throw ArgumentError.value(v.name, 'values', 'Invalid values: declared twice');
      }
      if (v._short case final s? when !shorts.add(s)) {
        throw ArgumentError.value(s, 'values', 'Invalid values: -$s twice');
      }
    }
    var optional = false;
    for (final (i, arg) in _args.indexed) {
      if (arg._isMany && i != _args.length - 1) {
        throw ArgumentError.value(
          arg.name,
          'values',
          'Invalid arguments: <${arg.name}> takes the rest, so it comes last',
        );
      }
      if (optional && arg._isRequired) {
        throw ArgumentError.value(
          arg.name,
          'values',
          'Invalid arguments: required <${arg.name}> after an optional one',
        );
      }
      optional |= !arg._isRequired;
    }
  }

  /// Whether [value] is this command's, or an ancestor's option.
  bool _declares(CliValue<Object?> value) => _args.contains(value) || _chain.any((c) => c._options.contains(value));

  /// The nearest option named [name], here or in an ancestor.
  CliValue<Object?>? _findOption(String name) =>
      _options.where((o) => o.name == name).firstOrNull ?? _parent?._findOption(name);

  /// The nearest option with short form [short], here or in an ancestor.
  CliValue<Object?>? _findShort(String short) =>
      _options.where((o) => o._short == short).firstOrNull ?? _parent?._findShort(short);

  /// This command, then each ancestor up to the root.
  Iterable<CliCommand> get _chain sync* {
    for (CliCommand? cur = this; cur != null; cur = cur._parent) {
      yield cur;
    }
  }

  String get _fullName => _parent == null ? name : '${_parent!._fullName} $name';

  CliCommand get _root => _parent == null ? this : _parent!._root;

  String? get _version => switch (_root) {
    Cli(:final version) => version,
    _ => null,
  };

  /// The built-ins the root offers: each yields to a declared name.
  List<(String long, String? short, String help)> get _builtIns => [
    ('help', 'h', 'Print this help'),
    if (_root is Cli) ...[
      ('verbose', 'v', 'Show debug output'),
      ('quiet', 'q', 'Show only warnings and errors'),
      if (_version != null) ('version', null, 'Print the version'),
      ('completion', null, 'Print a completion script (bash, zsh, fish, powershell)'),
    ],
  ];

  /// Usage to [out]: stdout for `--help`, stderr as the answer to a mistake.
  void _printUsage(StringSink out, int? columns) {
    final shape = [for (final arg in _args) arg._placeholder, '[options]', if (_subcommands.isNotEmpty) '[command]'];
    out.writeln('${'Usage:'.bold} $_fullName ${shape.join(' ')}');
    if (help.isNotEmpty) out.writeln('\n${columns == null ? help : Style.wrap(help, columns - 1).join('\n')}');

    final args = [for (final arg in _args) (arg._placeholder, _describe(arg))];
    final commands = [
      for (final sub in _subcommands.values) ([sub.name, ...sub.aliases].join(', '), sub.help),
    ];
    final options = [
      ..._optionRows(_options),
      for (final (long, short, text) in _builtIns)
        if (_findOption(long) == null)
          (
            '${short != null && _findShort(short) == null ? '-$short, ' : '    '}--$long${long == 'completion' ? ' <shell>' : ''}',
            short != null && _findShort(short) != null ? '$text (-$short is --${_findShort(short)!.name} here)' : text,
          ),
    ];
    final global = _optionRows([for (final cmd in _chain.skip(1)) ...cmd._options]);
    final width = [
      for (final (left, _) in [...args, ...commands, ...options, ...global]) left.length,
    ].fold(18, max);
    final room = columns == null ? null : columns - width - 5;
    final hang = ' ' * (width + 4);

    void section(String title, List<(String, String)> rows) {
      if (rows.isEmpty) return;
      out.writeln('\n${title.bold}');
      for (final (left, right) in rows) {
        final lines = room == null || room < 20 ? [right] : Style.wrap(right, room);
        out.writeln('  ${Style.pad(left, width)}  ${lines.first}'.trimRight());
        for (final line in lines.skip(1)) {
          out.writeln('$hang$line');
        }
      }
    }

    section('Arguments:', args);
    section('Commands:', commands);
    section('Options:', options);
    section('Global options:', global);
    if (_subcommands.isNotEmpty && _parent == null) {
      out.writeln('\nRun "$name <command> --help" for more on a command.');
    }
  }

  List<(String, String)> _optionRows(Iterable<CliValue<Object?>> options) => [
    for (final option in options)
      // One shadowed by a nearer name is unreachable; one whose short form was taken has its long form only.
      if (_findOption(option.name) == option)
        (
          '${option._short != null && _findShort(option._short!) == option ? '-${option._short}, ' : '    '}'
              '--${option._takesValue || option._or != true ? '' : '[no-]'}${option.name}'
              '${option._takesValue ? ' ${option._hint}' : ''}',
          _describe(option),
        ),
  ];

  /// The help line for a value: what it is for, may be, and defaults to.
  static String _describe(CliValue<Object?> value) {
    var desc = value.help;
    if (value._choices case final allowed? when !value._spec.option || value._hint == '<choice>') {
      final list = '(${allowed.map(_label).join('|')})';
      desc = desc.isEmpty ? list : '$desc $list';
    }
    // A flag's `false` and a repeatable value's `[]` are what absence already means.
    if (value._hasOr && value._takesValue) {
      final given = value._or;
      if (given is! List || given.isNotEmpty) {
        desc = '$desc [default: ${given is List ? given.map(_label).join(', ') : _label(given)}]';
      }
    }
    if (value._isMany && value._spec.option) desc = '$desc [repeatable]';
    if (value._env case final env?) desc = '$desc [env: $env]';
    if (value._isRequired && value._spec.option) desc = '$desc [required]';
    return desc.trimLeft();
  }

  /// Binds the positionals to the declared arguments, in order.
  void _bind(List<String> rest, Map<CliValue<Object?>, Object?> values) {
    var at = 0;
    for (final arg in _args) {
      if (arg._isMany) {
        final taken = rest.sublist(at);
        at = rest.length;
        if (taken.isNotEmpty) {
          values[arg] = arg._spec.list(taken.map(arg._spec.parse));
        } else if (arg._isRequired) {
          throw UsageException('Missing argument ${arg._placeholder}');
        }
      } else if (at < rest.length) {
        values[arg] = arg._spec.parse(rest[at++]);
      } else if (arg._isRequired) {
        throw UsageException('Missing argument ${arg._placeholder}');
      }
    }
    if (at < rest.length) throw UsageException('Unexpected argument "${rest[at]}"');
  }

  /// Stores [value] for [option]: a repeated one adds to what is there.
  static void _set(Map<CliValue<Object?>, Object?> values, CliValue<Object?> option, Object? value) {
    values[option] = option._isMany ? option._spec.list([...?values[option] as List<Object?>?, value]) : value;
  }

  /// What [args] ask of this command or one under it.
  _Ask _parse(List<String> args, Map<CliValue<Object?>, Object?> values, _Built built) {
    try {
      return _parseHere(args, values, built);
    } on UsageException catch (e) {
      if (e._command != null) rethrow;
      throw UsageException._(e.message, _fullName);
    }
  }

  /// Whether `--long` / `-short` here is the built-in, not a declared option.
  bool _isBuiltIn(String long) => _builtIns.any((b) => b.$1 == long) && _findOption(long) == null;

  bool _isBuiltInShort(String short) =>
      _builtIns.any((b) => b.$2 == short && _findOption(b.$1) == null) && _findShort(short) == null;

  _Ask _builtInAsk(String long, _Built built, String? value) => switch (long) {
    'help' => _Print(this, false),
    'version' => _Print(this, true),
    'completion' => _Text(_completion(_root, value)),
    'verbose' => (built.level = LogLevel.debug, _Continue()).$2,
    _ => (built.level = LogLevel.warn, _Continue()).$2,
  };

  _Ask _parseHere(List<String> args, Map<CliValue<Object?>, Object?> values, _Built built) {
    final rest = <String>[];
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--') {
        rest.addAll(args.sublist(i + 1));
        break;
      }
      final isLong = arg.startsWith('--');
      // `-5` is a number, not an option, unless something here answers to `-5`.
      final isNumber =
          !isLong && arg.startsWith('-') && arg.length > 1 && num.tryParse(arg) != null && _findShort(arg[1]) == null;
      if (isNumber || (!isLong && (!arg.startsWith('-') || arg.length <= 1))) {
        if (rest.isEmpty && _subcommands.isNotEmpty) {
          if (arg == 'help' && !_named.containsKey('help')) {
            final target = i + 1 < args.length ? _named[args[i + 1]] : null;
            return _Print(target ?? this, false);
          }
          if (_named[arg] case final sub?) return sub._parse(args.sublist(i + 1), values, built);
          if (_args.isEmpty) {
            final guess = _closest(arg, _named.keys);
            throw UsageException('Unknown command "$arg"${guess == null ? '' : '. Did you mean "$guess"?'}');
          }
        }
        rest.add(arg);
        continue;
      }

      final raw = arg.substring(isLong ? 2 : 1);
      final eq = raw.indexOf('=');
      final key = eq == -1 ? raw : raw.substring(0, eq);
      final inline = eq == -1 ? null : raw.substring(eq + 1);

      if (isLong && _isBuiltIn(key)) {
        final value = key == 'completion' ? inline ?? (i + 1 < args.length ? args[++i] : null) : null;
        if (_builtInAsk(key, built, value) case final ask when ask is! _Continue) return ask;
        continue;
      }
      final option = isLong ? _findOption(key) : _findShort(key);

      if (option == null && !isLong) {
        // `-vd` is two flags; `-j4` and `-j=4` are `-j 4`; `-vj4` is both.
        for (var k = 0; k < raw.length; k++) {
          final c = raw[k];
          final each = _findShort(c);
          if (each == null && _isBuiltInShort(c)) {
            final long = _builtIns.firstWhere((b) => b.$2 == c).$1;
            if (_builtInAsk(long, built, null) case final ask when ask is! _Continue) return ask;
            continue;
          }
          if (each == null) throw UsageException('Unknown option -$c${raw.length > 1 ? ' in "-$raw"' : ''}');
          if (!each._takesValue) {
            if (k + 1 < raw.length && raw[k + 1] == '=') {
              _set(values, each, each._spec.parse(raw.substring(k + 2)));
              break;
            }
            _set(values, each, true);
            continue;
          }
          var attached = raw.substring(k + 1);
          if (attached.startsWith('=')) attached = attached.substring(1);
          if (attached.isNotEmpty) {
            _set(values, each, each._spec.parse(attached));
          } else if (i + 1 < args.length) {
            _set(values, each, each._spec.parse(args[++i]));
          } else {
            throw UsageException('Option -$c needs a value');
          }
          break;
        }
        continue;
      }

      if (option == null) {
        // `--no-dry` is `--dry=false`, for a flag and nothing else.
        if (key.startsWith('no-') && inline == null) {
          if (_findOption(key.substring(3)) case final flag? when !flag._takesValue) {
            values[flag] = false;
            continue;
          }
        }
        final guess = _closest(key, [for (final cmd in _chain) ...cmd._options.map((o) => o.name)]);
        throw UsageException('Unknown option --$key${guess == null ? '' : '. Did you mean "--$guess"?'}');
      }

      if (!option._takesValue) {
        _set(values, option, inline == null ? true : option._spec.parse(inline));
      } else if (inline != null) {
        _set(values, option, option._spec.parse(inline));
      } else if (i + 1 < args.length) {
        _set(values, option, option._spec.parse(args[++i]));
      } else {
        throw UsageException('Option ${isLong ? '--' : '-'}$key needs a value');
      }
    }

    // The environment fills what the command line left out; then the required checks, up the chain.
    for (final cmd in _chain) {
      for (final option in cmd._options) {
        if (values.containsKey(option)) continue;
        if (option._env case final variable?) {
          if (Env.get<String?>(variable) case final raw?) {
            try {
              _set(values, option, option._spec.parse(raw));
            } on UsageException catch (e) {
              throw UsageException('${e.message} (from \$$variable)');
            }
            continue;
          }
        }
        if (option._isRequired) {
          throw UsageException(
            'Missing option --${option.name}${option._env == null ? '' : ' (or set ${option._env})'}',
          );
        }
      }
    }
    _bind(rest, values);
    if (handler != null) return _Run(this, values);
    if (_subcommands.isNotEmpty) return _NoCommand(this);
    return _Print(this, false);
  }
}

/// What a command line asks for.
sealed class _Ask {}

/// The handler of [command] with [values].
final class _Run extends _Ask {
  final CliCommand command;
  final Map<CliValue<Object?>, Object?> values;

  _Run(this.command, this.values);
}

/// [command]'s usage, or the version, on stdout.
final class _Print extends _Ask {
  final CliCommand command;
  final bool version;

  _Print(this.command, this.version);
}

/// [text] on stdout: a completion script.
final class _Text extends _Ask {
  final String text;

  _Text(this.text);
}

/// No command named where one had to be: the usage to stderr, exit 64.
final class _NoCommand extends _Ask {
  final CliCommand command;

  _NoCommand(this.command);
}

/// A built-in that set something and lets parsing go on.
final class _Continue extends _Ask {}

/// What the built-ins set while parsing.
final class _Built {
  LogLevel? level;
}

/// What [Cli.test] answers: the exit code and everything written.
typedef CliResult = ({int exitCode, String stdout, String stderr});

/// A program: its description, version, values, commands and handler. [run] parses the command
/// line, runs the handler named, and exits; [test] does the same and answers what happened.
///
/// Every program answers `-h`/`--help`, `-v`/`--verbose` (debug lines, and every warning work
/// gives), `-q`/`--quiet` (warnings and errors only), `--version` when it has one, and
/// `--completion bash|zsh|fish|powershell`; a name or a letter you declare yourself wins, and the
/// help says so.
///
/// ```dart
/// final top = Option.of<int>('top', 'How many to show', short: 'n').or(10);
///
/// Future<void> main(List<String> args) => Cli('Shows the largest files.',
///   version: '1.2.0', values: [top],
///   handler: (ctx) async { … ctx(top) … }).run(args);
/// ```
///
/// A handler fails the run by throwing: a [UsageException] exits 64, anything else 1 with the
/// error on one line (its trace under `-v`); a timeout 124, ^C 130. Work drawn with `show()`
/// that failed has said so already, and exits 1 with no second line.
///
/// {@category CLI}
final class Cli extends CliCommand {
  /// Printed by `--version`.
  final String? version;

  /// The pools whose detached jobs (`pool.add(item, detached: true)`) a runner launch serves.
  final List<Detachable> pools;

  /// [name] defaults to the script's: `bin/tk.dart`, a snapshot of it and a compiled `tk.exe` are
  /// all `tk`. [pools] are served, instead of the handler, when this launch is a pool's runner.
  Cli(
    String description, {
    String? name,
    this.version,
    super.values,
    super.commands,
    this.pools = const [],
    super.handler,
  }) : super(name ?? _scriptName(), description);

  static String _scriptName() {
    final script = FileBridge.script();
    final name = script.split(RegExp(r'[/\\]')).last.replaceFirst(_scriptSuffix, '');
    return name.isEmpty ? 'app' : name;
  }

  static final _scriptSuffix = RegExp(
    r'\.dart(-[\w.]+)?\.(snapshot|dill|aot|jit)$|\.(dart|exe|snapshot|dill|aot|jit)$',
  );

  /// Runs the program for [args] and exits with its code: the only thing in the package that
  /// ends the process. ^C cancels the handler's work, runs its cleanups and exits 130; a second
  /// ^C leaves at once.
  Future<Never> run(List<String> args) async {
    await _serveDetached();
    final run = _RunState();
    final unwatch = _watchSignals(run);
    final code = await _execute(args, run);
    unwatch();
    _terminate(code);
  }

  /// The hook for detached pools: `async`'s `Pool.serve(pools)` is called here, before any
  /// parsing, so a launch as a pool's runner (`DART_TOOLKIT_POOL` set) serves its jobs and never
  /// returns; otherwise it returns at once. `cli` reaches it through core, without importing
  /// `async`.
  Future<void> _serveDetached() async {
    if (pools.isEmpty) return;
    await DetachableBridge.serve?.call(pools);
  }

  /// Runs the program for [args] as [run] does, without exiting or watching signals, and
  /// answers its exit code and what it wrote, uncoloured: for tests.
  ///
  /// ```dart
  /// final result = await cli.test(['build', '--top', '3']);
  /// expect(result.exitCode, 0);
  /// ```
  Future<CliResult> test(List<String> args) async {
    final out = StringBuffer(), err = StringBuffer();
    final code = await Io.scope(() => _execute(args, _RunState()), stdout: out, stderr: err, color: false);
    return (exitCode: code, stdout: '$out', stderr: '$err');
  }

  /// Parses and runs; answers the exit code once the cleanups have run.
  Future<int> _execute(List<String> args, _RunState run) async {
    Console._bridge();
    final built = _Built();
    final _Ask ask;
    try {
      ask = _parse(args, {}, built);
    } on UsageException catch (e) {
      Console.error(_oneLine(e.message));
      Io.stderr.writeln('Run "${e._command ?? name} --help" for usage.');
      return 64;
    }
    // `DART_TOOLKIT_DEBUG=1` is `-v` for a run whose arguments a scheduler owns.
    final level = Env.has('DART_TOOLKIT_DEBUG') ? LogLevel.debug : built.level;
    switch (ask) {
      case _Print(:final command, version: true):
        Io.stdout.writeln('${command._root.name} ${command._version}');
        return 0;
      case _Print(:final command):
        command._printUsage(Io.stdout, Io.columns);
        return 0;
      case _Text(:final text):
        Io.stdout.write(text);
        return 0;
      case _NoCommand(:final command):
        command._printUsage(Io.stderr, Io.stderrColumns);
        return 64;
      case _Continue():
        return 0;
      case _Run(:final command, :final values):
        return Console.scope(() => _handle(command, values, run), level: level);
    }
  }

  Future<int> _handle(CliCommand command, Map<CliValue<Object?>, Object?> values, _RunState run) async {
    late final CliContext ctx;
    final printing = ZoneSpecification(print: (_, _, _, line) => Console.line(line));
    final task = runZoned(
      () => Task.run(name, (work) {
        ctx = CliContext._(command, values, work, name);
        return command.handler!(ctx);
      }),
      zoneValues: {_runKey: run},
      zoneSpecification: printing,
    );
    run.task = task;
    // Under -v, every warning the work gives that nothing drew.
    final notes = task.statuses.listen((s) {
      if (s case Warned(:final warning) when !_wasSaid(warning)) Console.debug('$s');
    });
    final outcome = await task.settled;
    await notes.cancel();
    ctx._ended = outcome;
    return runZoned(
      () async {
        final code = _codeOf(outcome, run, command);
        await _closeAll(ctx._cleanups);
        return code;
      },
      zoneValues: {_runKey: run},
      zoneSpecification: printing,
    );
  }

  /// The exit code [outcome] of [command]'s handler means, and its one line when nothing said it yet.
  int _codeOf(Status<Object?, Object?> outcome, _RunState run, CliCommand command) {
    switch (outcome) {
      case Done():
        return run.failedWork ? 1 : 0;
      case Stopped(:final reason):
        Console.warn(reason == 'Interrupted' ? 'Interrupted' : 'Cancelled: $reason');
        return 130;
      case Failed(error: final _Exit e):
        if (e.message case final message?) Console.error(message);
        return e.code;
      case Failed(error: final UsageException e):
        Console.error(_oneLine(e.message));
        Io.stderr.writeln('Run "${e._command ?? command._fullName} --help" for usage.');
        return 64;
      case Failed(:final error, :final stackTrace):
        Console.debug('$error');
        Console.debug('$stackTrace');
        if (!_wasSaid(error)) Console.error(_oneLine('$error'));
        return switch (error) {
          TimeoutException() => 124,
          CancelledException() => 130,
          _ => 1,
        };
      case _:
        return 0;
    }
  }
}
