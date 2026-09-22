part of '../../cli.dart';

/// A command line the program cannot act on: an unknown option, a bad value, a missing
/// required option. [Cli.run] prints it and exits 64; [CliCommand.run] throws it.
///
/// {@category CLI}
final class UsageException implements Exception {
  final String message;

  const UsageException(this.message);

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
  /// is not one. Never called for a flag, which takes no value.
  T _parse(String raw);

  /// Used when it is absent, or `null` when there is none.
  T? get _or;

  /// Whether parsing fails when it is absent. Never true for a flag.
  bool get _isRequired;

  /// The values it is restricted to, shown in help, or `null` when it is not.
  List<T>? get _choices => null;
}

/// An option declared on a [CliCommand], written `--name` or `-n`. See [Opt].
///
/// {@category CLI}
sealed class CliOption<T> extends CliValue<T> {
  /// The single-character short form, used as `-a`.
  final String? abbr;

  const CliOption(super.name, {super.description, this.abbr})
    : assert(abbr == null || abbr.length == 1, 'abbr is one character');

  /// Whether this option takes a value of its own on the command line.
  bool get _takesValue => true;
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
  final List<T>? _choices;

  @override
  final T? _or;

  @override
  final bool _isRequired;

  /// Whether this one takes everything that is left. At most one, and last.
  final bool _variadic;

  const Arg._(
    super.name, {
    required T Function(String raw) parse,
    super.description,
    List<T>? choices,
    T? or,
    bool required = false,
    bool variadic = false,
  }) : _parseValue = parse,
       _choices = choices,
       _or = or,
       _isRequired = required,
       _variadic = variadic;

  /// A string argument.
  static Arg<String?> text(String name, {String description = ''}) =>
      Arg<String?>._(name, parse: (raw) => raw, description: description);

  /// An integer argument, rejected during parsing when it is not one.
  static Arg<int?> number(String name, {String description = ''}) =>
      Arg<int?>._(name, parse: _int, description: description);

  /// An argument restricted to [values], matched by [Enum.name] or `toString()`.
  static Arg<V?> among<V>(String name, List<V> values, {String description = ''}) =>
      Arg<V?>._(name, parse: (raw) => _among(name, values, raw), description: description, choices: values);

  /// An argument parsed by [parse]; anything it throws becomes a [UsageException].
  static Arg<V?> by<V>(String name, V Function(String raw) parse, {String description = ''}) =>
      Arg<V?>._(name, parse: (raw) => _guard(name, parse, raw), description: description);

  /// Everything that is left, as it was typed: `tk hash <path>...`.
  ///
  /// At most one per command and it must be declared last. `required()` on it means at
  /// least one, and `or(const [])` means none is fine.
  static Arg<List<String>?> rest(String name, {String description = ''}) =>
      Arg<List<String>?>._(name, parse: (raw) => [raw], description: description, variadic: true);

  @override
  T _parse(String raw) => _parseValue(raw);

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
  Arg<T> or(T value) {
    if (_choices case final allowed? when !allowed.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Not one of ${allowed.map(_label).join(', ')}');
    }
    return Arg<T>._(
      name,
      parse: (raw) => _parse(raw) as T,
      description: description,
      choices: _choices?.cast<T>(),
      or: value,
      variadic: _variadic,
    );
  }

  /// The same argument, but parsing fails when it is absent — for a variadic one, when
  /// nothing at all was given.
  Arg<T> required() => Arg<T>._(
    name,
    parse: (raw) => _parse(raw) as T,
    description: description,
    choices: _choices?.cast<T>(),
    required: true,
    variadic: _variadic,
  );
}

/// A boolean option: present means true, and it never consumes a value. See [Opt.flag].
final class _Flag extends CliOption<bool> {
  const _Flag(super.name, {super.description, super.abbr});

  @override
  bool _parse(String raw) => true;

  @override
  bool get _or => false;

  @override
  bool get _isRequired => false;

  @override
  bool get _takesValue => false;
}

/// An option: a flag, a string, an integer, one of a fixed set, or whatever a function
/// of your own returns. Every kind is behind this one name.
///
/// All but [flag] produce a nullable option; [OptionalOpt.or] and [OptionalOpt.required]
/// are what guarantee a value, and they are what make [CliContext.call] return a
/// non-nullable [T].
///
/// ```dart
/// final dry   = Opt.flag('dry-run', abbr: 'd');                 // bool
/// final out   = Opt.text('out', abbr: 'o');                     // String?
/// final to    = Opt.text('to', abbr: 't').required();           // String
/// final top   = Opt.number('top', abbr: 'n').or(10);            // int
/// final algo  = Opt.among('algo', Hash.values).or(Hash.sha256); // Hash
/// final since = Opt.by('since', DateTime.parse);                // DateTime?
/// ```
///
/// {@category CLI}
final class Opt<T> extends CliOption<T> {
  final T Function(String raw) _parseValue;

  @override
  final List<T>? _choices;

  @override
  final T? _or;

  @override
  final bool _isRequired;

  const Opt._(
    super.name, {
    required T Function(String raw) parse,
    super.description,
    super.abbr,
    List<T>? choices,
    T? or,
    bool required = false,
  }) : _parseValue = parse,
       _choices = choices,
       _or = or,
       _isRequired = required;

  /// A boolean option. Present means true; it never consumes a value.
  static CliOption<bool> flag(String name, {String description = '', String? abbr}) =>
      _Flag(name, description: description, abbr: abbr);

  /// A string option.
  static Opt<String?> text(String name, {String description = '', String? abbr}) =>
      Opt<String?>._(name, parse: (raw) => raw, description: description, abbr: abbr);

  /// An integer option, rejected during parsing when it is not one.
  static Opt<int?> number(String name, {String description = '', String? abbr}) =>
      Opt<int?>._(name, parse: _int, description: description, abbr: abbr);

  /// An option restricted to [values], matched by [Enum.name] or `toString()`.
  static Opt<V?> among<V>(String name, List<V> values, {String description = '', String? abbr}) =>
      Opt<V?>._(name, parse: (raw) => _among(name, values, raw), description: description, abbr: abbr, choices: values);

  /// An option parsed by [parse]; anything it throws becomes a [UsageException].
  static Opt<V?> by<V>(String name, V Function(String raw) parse, {String description = '', String? abbr}) =>
      Opt<V?>._(name, parse: (raw) => _guard(name, parse, raw), description: description, abbr: abbr);

  @override
  T _parse(String raw) => _parseValue(raw);
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
  Opt<T> or(T value) {
    if (_choices case final allowed? when !allowed.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Not one of ${allowed.map(_label).join(', ')}');
    }
    return Opt<T>._(
      name,
      parse: (raw) => _parse(raw) as T,
      description: description,
      abbr: abbr,
      choices: _choices?.cast<T>(),
      or: value,
    );
  }

  /// The same option, but parsing fails when it is absent.
  Opt<T> required() => Opt<T>._(
    name,
    parse: (raw) => _parse(raw) as T,
    description: description,
    abbr: abbr,
    choices: _choices?.cast<T>(),
    required: true,
  );
}

/// The label a value is spelled with on the command line and in help text.
String _label(Object? value) => value is Enum ? value.name : '$value';

T _int<T>(String raw) {
  final value = int.tryParse(raw);
  if (value == null) throw UsageException('Invalid numeric value "$raw". Expected an integer.');
  return value as T;
}

T _among<T, V>(String name, List<V> values, String raw) {
  for (final value in values) {
    if (_label(value) == raw) return value as T;
  }
  throw UsageException('Invalid value "$raw" for option "$name". Allowed choices: ${values.map(_label).join(', ')}');
}

T _guard<T, V>(String name, V Function(String raw) parse, String raw) {
  try {
    return parse(raw) as T;
  } on UsageException {
    rethrow;
  } catch (e) {
    throw UsageException('Invalid value "$raw" for option "$name": $e');
  }
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

  /// Cancelled on SIGINT, SIGTERM and [die], before the other exit hooks run.
  ///
  /// [Cli.run] makes it the ambient [Cancel.token] for the whole action, so a download,
  /// a crawl or a `retry` inside it already stops; this is the handle that stops them.
  final CancelToken cancel;

  final Map<CliValue<Object?>, Object?> _values;

  CliContext(this.rest, Map<CliValue<Object?>, Object?> values, this.command, {CancelToken? cancel})
    : _values = values,
      cancel = cancel ?? CancelToken();

  /// The value of [option] — the option itself is the key, so its type is its value's.
  ///
  /// ```dart
  /// if (ctx(verbose)) Console.level = LogLevel.debug;
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

  /// Whether [value] was given on the command line, default or not.
  bool given(CliValue<Object?> value) => _values.containsKey(value);
}

/// A command: a name, options, subcommands and the handler that runs it.
///
/// Everything a command is, it is given: [options], [commands] and [handler] are
/// constructor arguments, and nothing sets them afterwards.
///
/// ```dart
/// CliCommand('fetch', description: 'Fetch a thing', options: [verbose], handler: fetch)
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
    Iterable<Arg<Object?>> args = const [],
    Iterable<CliOption<Object?>> options = const [],
    Iterable<CliCommand> commands = const [],
  }) : _args = List.unmodifiable(args),
       _options = List.unmodifiable(options),
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

  /// Prints usage help for this command.
  void _printUsage() {
    // Only what this command actually has. `[command]` on a program with no subcommands is
    // an invitation to type something that cannot work.
    final shape = [for (final arg in _args) arg._placeholder, '[options]', if (_subcommands.isNotEmpty) '[command]'];
    Io.out.writeln('${'Usage:'.bold} $_fullName ${shape.join(' ')}');
    if (description.isNotEmpty) Io.out.writeln('\n$description');

    if (_args.isNotEmpty) {
      Io.out.writeln('\n${'Arguments:'.bold}');
      for (final arg in _args) {
        Io.out.writeln('  ${arg._placeholder.padRight(20)} ${_describe(arg)}');
      }
    }

    if (_subcommands.isNotEmpty) {
      Io.out.writeln('\n${'Commands:'.bold}');
      for (final sub in _subcommands.values) {
        Io.out.writeln('  ${sub.name.padRight(20)} ${sub.description}');
      }
    }

    Io.out.writeln('\n${'Options:'.bold}');
    for (final option in _options) {
      final optName = '--${option.name}';
      final prefix = option.abbr != null ? '-${option.abbr}, $optName' : '    $optName';
      // A flag's fallback is `false`, which is what absence already means; saying so is noise.
      Io.out.writeln('  ${prefix.padRight(20)} ${_describe(option, fallback: option._takesValue)}');
    }
    // Only what this command will actually answer to.
    if (_findOption('help') == null) {
      Io.out.writeln(
        '  ${(_findAbbr('h') == null ? '-h, --help' : '    --help').padRight(20)} Print this help message',
      );
    }
    if (_version != null && _findOption('version') == null) {
      Io.out.writeln('      --version        Print the version');
    }
  }

  /// The help line for one declared value: what it is for, what it may be, what it is when
  /// it is absent. One renderer, so an argument and an option read alike.
  static String _describe(CliValue<Object?> value, {bool fallback = true}) {
    var desc = value.description;
    if (value._choices case final allowed? when allowed.isNotEmpty) {
      final list = '(${allowed.map(_label).join('|')})';
      desc = desc.isEmpty ? list : '$desc $list';
    }
    if (fallback) {
      if (value._or case final given?) desc = '$desc [default: ${_label(given)}]';
    }
    // An argument says it is required by its own `<>`; an option has nowhere else to say so.
    if (value._isRequired && value is! Arg) desc = '$desc [required]';
    return desc;
  }

  /// Binds the positionals to the arguments this command declared, in order.
  ///
  /// A command that declares none keeps the old behaviour exactly: [CliContext.rest] is
  /// whatever was typed and nothing is checked. Declaring them is what buys the checking.
  void _bind(List<String> rest, Map<CliValue<Object?>, Object?> values) {
    if (_args.isEmpty) return;
    var at = 0;
    for (final arg in _args) {
      if (arg._variadic) {
        final taken = rest.sublist(at.clamp(0, rest.length));
        at = rest.length;
        if (taken.isNotEmpty) {
          values[arg] = taken;
        } else if (arg._isRequired) {
          throw UsageException('Missing argument ${arg._placeholder}.');
        }
        continue;
      }
      if (at < rest.length) {
        values[arg] = arg._parse(rest[at++]);
      } else if (arg._isRequired) {
        throw UsageException('Missing argument ${arg._placeholder}.');
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
  /// and a short option may attach its value (`-j4`). Usage errors throw [UsageException];
  /// [Cli.run] turns them into a message and exit code 64.
  Future<void> run(List<String> args) {
    final cancel = CancelToken();
    return Cancel.scope(() => _run(args, {}, cancel), token: cancel);
  }

  Future<void> _run(List<String> args, Map<CliValue<Object?>, Object?> values, CancelToken cancel) async {
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
      if (!isLong && (!arg.startsWith('-') || arg.length <= 1)) {
        // The first positional naming a subcommand dispatches to it, carrying what is parsed so far.
        if (rest.isEmpty && _subcommands.containsKey(arg)) {
          return _subcommands[arg]!._run(args.sublist(i + 1), values, cancel);
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
      if (isLong && key == 'version' && _version != null && _findOption('version') == null) {
        Io.out.writeln('${_root.name} $_version');
        return;
      }

      final option = isLong ? _findOption(key) : _findAbbr(key);

      if (option == null && !isLong && key.length > 1) {
        // `-vd` is two flags; `-j4` is `-j 4`; `-vj4` is both.
        for (var k = 0; k < key.length; k++) {
          final each = _findAbbr(key[k]);
          if (each == null) throw UsageException('Unknown option in "-$key": -${key[k]}');
          if (!each._takesValue) {
            values[each] = true;
            continue;
          }
          final attached = key.substring(k + 1);
          if (attached.isNotEmpty) {
            values[each] = each._parse(attached);
          } else if (i + 1 < args.length) {
            values[each] = each._parse(args[++i]);
          } else {
            throw UsageException('Option "-${key[k]}" requires a value.');
          }
          break;
        }
        continue;
      }

      if (option == null) throw UsageException('Unknown option: ${isLong ? '--' : '-'}$key');

      if (!option._takesValue) {
        values[option] = true;
      } else if (inline != null) {
        values[option] = option._parse(inline);
      } else if (i + 1 < args.length) {
        values[option] = option._parse(args[++i]);
      } else {
        throw UsageException('Option "${isLong ? '--' : '-'}$key" requires a value.');
      }
    }

    // Required checks cover this command and every ancestor; defaults live on the option.
    for (CliCommand? cur = this; cur != null; cur = cur._parent) {
      for (final option in cur._options) {
        if (option._isRequired && !values.containsKey(option)) {
          throw UsageException('Missing required option "--${option.name}".');
        }
      }
    }

    _bind(rest, values);

    if (handler != null) {
      await handler!(CliContext(rest, values, this, cancel: cancel));
    } else {
      _printUsage();
    }
  }
}

/// The root command: a program's name, version and entry point.
///
/// {@category CLI}
class Cli extends CliCommand {
  /// Printed by `--version` when set.
  final String? version;

  Cli({
    String name = 'app',
    String description = '',
    this.version,
    super.args,
    super.options,
    super.commands,
    super.handler,
  }) : super(name, description: description);

  /// Parses [args], runs the matching command, then runs the exit hooks and releases
  /// the signal handlers so the process can end — whether the action returned or threw.
  ///
  /// A usage error — unknown option, bad choice, missing required option — is printed
  /// to stderr and exits with code 64. [CliCommand.run] throws instead; use it to test.
  /// `ctx.cancel` is cancelled first on a signal, on [die], and when the action ends.
  ///
  /// The action runs inside a [Cancel.scope] holding that token, so everything under it
  /// — downloads, crawls, `retry` — stops with it and takes no token of its own.
  @override
  Future<void> run(List<String> args) async {
    final cancel = CancelToken();
    Lifecycle.onExit(cancel.cancel);
    try {
      await Cancel.scope(() => _run(args, {}, cancel), token: cancel);
    } on UsageException catch (e) {
      await Lifecycle.exit('${e.message}\n  Run "$name --help" for usage.', 64);
    } finally {
      await _runExitHooks();
      Lifecycle.onExit(null);
    }
  }
}
