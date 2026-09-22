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

/// An option declared on a [CliCommand] and read back through [CliContext.call].
///
/// The option itself is the key, so a name is written once:
///
/// ```dart
/// final top = Opt.number('top', abbr: 'n').or(10);
/// …
/// ctx(top) // an int, statically
/// ```
///
/// [T] carries whether a value is guaranteed: [Opt] is nullable until [Opt.or] gives it a
/// default or [Opt.required] insists on one, and a [Flag] is always a `bool`.
///
/// {@category CLI}
sealed class CliOption<T> {
  /// The long name, used as `--name`.
  final String name;

  /// Help text shown by `--help`.
  final String description;

  /// The single-character short form, used as `-a`.
  final String? abbr;

  const CliOption(this.name, {this.description = '', this.abbr})
    : assert(abbr == null || abbr.length == 1, 'abbr is one character');

  /// Turns the text on the command line into the value, throwing [UsageException] when it
  /// is not one. Never called for a flag, which takes no value.
  T _parse(String raw);

  /// Used when the option is absent, or `null` when there is none.
  T? get _or;

  /// Whether parsing fails when this option is absent. Never true for a flag.
  bool get _isRequired;

  /// The values the option is restricted to, shown in help, or `null` when it is not.
  List<T>? get _choices => null;

  /// Whether this option takes a value of its own on the command line.
  bool get _takesValue => true;
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
  /// Positional arguments, plus everything after a `--` terminator.
  final List<String> rest;

  /// The command that was dispatched.
  final CliCommand command;

  /// Cancelled on SIGINT, SIGTERM and [die], before the other exit hooks run.
  ///
  /// [Cli.run] makes it the ambient [Cancel.token] for the whole action, so a download,
  /// a crawl or a `retry` inside it already stops; this is the handle that stops them.
  final CancelToken cancel;

  final Map<CliOption<Object?>, Object?> _values;

  CliContext(this.rest, Map<CliOption<Object?>, Object?> values, this.command, {CancelToken? cancel})
    : _values = values,
      cancel = cancel ?? CancelToken();

  /// The value of [option] — the option itself is the key, so its type is its value's.
  ///
  /// ```dart
  /// if (ctx(verbose)) Logger.level = LogLevel.debug;
  /// final n = ctx(top); // int, because `top` was declared with `.or(10)`
  /// ```
  ///
  /// Throws [StateError] only when a non-nullable option somehow reaches a handler
  /// unset — a declared default or `required()` is what rules that out.
  T call<T>(CliOption<T> option) {
    if (_values.containsKey(option)) return _values[option] as T;
    if (option._or case final value?) return value;
    if (null is T) return null as T;
    throw StateError('Option "--${option.name}" was not given and has no default.');
  }

  /// Whether [option] was given on the command line, default or not.
  bool given(CliOption<Object?> option) => _values.containsKey(option);
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

  final List<CliOption<Object?>> _options;
  final Map<String, CliCommand> _subcommands;
  CliCommand? _parent;

  CliCommand(
    this.name, {
    this.description = '',
    this.handler,
    Iterable<CliOption<Object?>> options = const [],
    Iterable<CliCommand> commands = const [],
  }) : _options = List.unmodifiable(options),
       _subcommands = {for (final c in commands) c.name: c} {
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
    Io.out.writeln('${'Usage:'.bold} $_fullName [options] [command]');
    if (description.isNotEmpty) Io.out.writeln('\n$description');

    if (_subcommands.isNotEmpty) {
      Io.out.writeln('\n${'Commands:'.bold}');
      for (final sub in _subcommands.values) {
        Io.out.writeln('  ${sub.name.padRight(20)} ${sub.description}');
      }
    }

    if (_options.isNotEmpty) {
      Io.out.writeln('\n${'Options:'.bold}');
      for (final option in _options) {
        final optName = '--${option.name}';
        final prefix = option.abbr != null ? '-${option.abbr}, $optName' : '    $optName';
        var desc = option.description;
        if (option._choices case final allowed? when allowed.isNotEmpty) {
          final list = '(${allowed.map(_label).join('|')})';
          desc = desc.isEmpty ? list : '$desc $list';
        }
        // A flag's fallback is `false`, which is what absence already means; saying so is noise.
        if (option._takesValue) {
          if (option._or case final value?) desc = '$desc [default: ${_label(value)}]';
        }
        if (option._isRequired) desc = '$desc [required]';
        Io.out.writeln('  ${prefix.padRight(20)} $desc');
      }
    }

    Io.out.writeln('  -h, --help           Print this help message');
    if (_version != null) Io.out.writeln('      --version        Print the version');
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
    return Cancel.session(() => _run(args, {}, cancel), token: cancel);
  }

  Future<void> _run(List<String> args, Map<CliOption<Object?>, Object?> values, CancelToken cancel) async {
    final rest = <String>[];
    final ownsHelp = _findOption('help') != null || _findAbbr('h') != null;

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

      if (!ownsHelp && (isLong ? key == 'help' : key == 'h')) {
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

  Cli({String name = 'app', String description = '', this.version, super.options, super.commands, super.handler})
    : super(name, description: description);

  /// Parses [args], runs the matching command, then runs the exit hooks and releases
  /// the signal handlers so the process can end — whether the action returned or threw.
  ///
  /// A usage error — unknown option, bad choice, missing required option — is printed
  /// to stderr and exits with code 64. [CliCommand.run] throws instead; use it to test.
  /// `ctx.cancel` is cancelled first on a signal, on [die], and when the action ends.
  ///
  /// The action runs inside a [Cancel.session] holding that token, so everything under it
  /// — downloads, crawls, `retry` — stops with it and takes no token of its own.
  @override
  Future<void> run(List<String> args) async {
    final cancel = CancelToken();
    onExit(cancel.cancel);
    try {
      await Cancel.session(() => _run(args, {}, cancel), token: cancel);
    } on UsageException catch (e) {
      await die('${e.message}\n  Run "$name --help" for usage.', exitCode: 64);
    } finally {
      await runExitHooks();
      clearExitHooks();
    }
  }
}
