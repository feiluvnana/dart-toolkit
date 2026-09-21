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

  /// Help text shown by [CliCommand.printUsage].
  final String description;

  /// The single-character short form, used as `-a`.
  final String? abbr;

  const CliOption(this.name, {this.description = '', this.abbr})
    : assert(abbr == null || abbr.length == 1, 'abbr is one character');

  /// Turns the text on the command line into the value, throwing [UsageException] when it
  /// is not one. Never called for a [Flag], which takes no value.
  T parse(String raw);

  /// Used when the option is absent, or `null` when there is none.
  T? get fallback;

  /// Whether parsing fails when this option is absent. Never true for a [Flag].
  bool get isRequired;

  /// The values the option is restricted to, shown in help, or `null` when it is not.
  List<T>? get choices => null;

  /// Whether this option takes a value of its own on the command line.
  bool get takesValue => true;
}

/// A boolean option. Present means true; it never consumes a value.
///
/// {@category CLI}
final class Flag extends CliOption<bool> {
  const Flag(super.name, {super.description, super.abbr});

  @override
  bool parse(String raw) => true;

  @override
  bool get fallback => false;

  @override
  bool get isRequired => false;

  @override
  bool get takesValue => false;
}

/// An option taking a value: a string, an integer, one of a fixed set, or whatever a
/// function of your own returns.
///
/// The constructors all produce a nullable option; [OptionalOpt.or] and
/// [OptionalOpt.required] are what guarantee a value, and they are what make
/// [CliContext.call] return a non-nullable [T].
///
/// ```dart
/// final out   = Opt.text('out', abbr: 'o');                     // String?
/// final to    = Opt.text('to', abbr: 't').required();           // String
/// final top   = Opt.number('top', abbr: 'n').or(10);            // int
/// final algo  = Opt.among('algo', Hash.values).or(Hash.sha256); // Hash
/// final since = Opt.by('since', DateTime.parse);                // DateTime?
/// ```
///
/// {@category CLI}
final class Opt<T> extends CliOption<T> {
  final T Function(String raw) _parse;

  @override
  final List<T>? choices;

  @override
  final T? fallback;

  @override
  final bool isRequired;

  const Opt._(
    super.name, {
    required T Function(String raw) parse,
    super.description,
    super.abbr,
    this.choices,
    this.fallback,
    this.isRequired = false,
  }) : _parse = parse;

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
  T parse(String raw) => _parse(raw);
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
    if (choices case final allowed? when !allowed.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Not one of ${allowed.map(_label).join(', ')}');
    }
    return Opt<T>._(
      name,
      parse: (raw) => _parse(raw) as T,
      description: description,
      abbr: abbr,
      choices: choices?.cast<T>(),
      fallback: value,
    );
  }

  /// The same option, but parsing fails when it is absent.
  Opt<T> required() => Opt<T>._(
    name,
    parse: (raw) => _parse(raw) as T,
    description: description,
    abbr: abbr,
    choices: choices?.cast<T>(),
    isRequired: true,
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

  /// Cancelled on SIGINT, SIGTERM and [die], before the other exit hooks run. Pass it to
  /// `downloadAll`, `parallelize`, `cancelWith`; a script needs no token of its own.
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
    if (option.fallback case final value?) return value;
    if (null is T) return null as T;
    throw StateError('Option "--${option.name}" was not given and has no default.');
  }

  /// Whether [option] was given on the command line, default or not.
  bool given(CliOption<Object?> option) => _values.containsKey(option);
}

/// A command: a name, options, subcommands and the handler that runs it.
///
/// {@category CLI}
class CliCommand {
  final String name;
  final String description;
  final List<CliOption<Object?>> options = [];
  final Map<String, CliCommand> subcommands = {};
  final CliCommand? parent;
  CommandHandler? handler;

  CliCommand(
    this.name, {
    this.description = '',
    this.handler,
    this.parent,
    Iterable<CliOption<Object?>> options = const [],
  }) {
    this.options.addAll(options);
  }

  /// Looks up an option by name, walking up to the root command.
  CliOption<Object?>? findOption(String name) {
    for (final option in options) {
      if (option.name == name) return option;
    }
    return parent?.findOption(name);
  }

  /// Looks up an option by short form, walking up to the root command.
  CliOption<Object?>? findAbbr(String abbr) {
    for (final option in options) {
      if (option.abbr == abbr) return option;
    }
    return parent?.findAbbr(abbr);
  }

  /// Declares [option] on this command.
  CliCommand declare(CliOption<Object?> option) {
    options.add(option);
    return this;
  }

  /// Declares a nested command with its [options] and [handler]; [build] is for one that
  /// nests further.
  ///
  /// Returns this command, not the child, so a chain stays on one receiver.
  CliCommand command(
    String name, {
    String description = '',
    CommandHandler? handler,
    Iterable<CliOption<Object?>> options = const [],
    void Function(CliCommand)? build,
  }) {
    final sub = CliCommand(name, description: description, handler: handler, parent: this, options: options);
    build?.call(sub);
    subcommands[name] = sub;
    return this;
  }

  /// Sets the action this command runs.
  CliCommand action(CommandHandler actionHandler) {
    handler = actionHandler;
    return this;
  }

  /// Prints usage help for this command.
  void printUsage() {
    Io.out.writeln('${'Usage:'.bold} $_fullName [options] [command]');
    if (description.isNotEmpty) Io.out.writeln('\n$description');

    if (subcommands.isNotEmpty) {
      Io.out.writeln('\n${'Commands:'.bold}');
      for (final sub in subcommands.values) {
        Io.out.writeln('  ${sub.name.padRight(20)} ${sub.description}');
      }
    }

    if (options.isNotEmpty) {
      Io.out.writeln('\n${'Options:'.bold}');
      for (final option in options) {
        final optName = '--${option.name}';
        final prefix = option.abbr != null ? '-${option.abbr}, $optName' : '    $optName';
        var desc = option.description;
        if (option.choices case final allowed? when allowed.isNotEmpty) {
          final list = '(${allowed.map(_label).join('|')})';
          desc = desc.isEmpty ? list : '$desc $list';
        }
        // A flag's fallback is `false`, which is what absence already means; saying so is noise.
        if (option.takesValue) {
          if (option.fallback case final value?) desc = '$desc [default: ${_label(value)}]';
        }
        if (option.isRequired) desc = '$desc [required]';
        Io.out.writeln('  ${prefix.padRight(20)} $desc');
      }
    }

    Io.out.writeln('  -h, --help           Print this help message');
    if (_version != null) Io.out.writeln('      --version        Print the version');
  }

  String get _fullName => parent == null ? name : '${parent!._fullName} $name';

  CliCommand get _root => parent == null ? this : parent!._root;

  String? get _version => switch (_root) {
    Cli(:final version) => version,
    _ => null,
  };

  /// Parses [args] and runs this command, or a matching subcommand.
  ///
  /// Options may precede the subcommand (`app -v fetch`); short flags combine (`-vd`)
  /// and a short option may attach its value (`-j4`). Usage errors throw [UsageException];
  /// [Cli.run] turns them into a message and exit code 64.
  Future<void> run(List<String> args) => _run(args, {}, CancelToken());

  Future<void> _run(List<String> args, Map<CliOption<Object?>, Object?> values, CancelToken cancel) async {
    final rest = <String>[];
    final ownsHelp = findOption('help') != null || findAbbr('h') != null;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];

      if (arg == '--') {
        rest.addAll(args.sublist(i + 1));
        break;
      }

      final isLong = arg.startsWith('--');
      if (!isLong && (!arg.startsWith('-') || arg.length <= 1)) {
        // The first positional naming a subcommand dispatches to it, carrying what is parsed so far.
        if (rest.isEmpty && subcommands.containsKey(arg)) {
          return subcommands[arg]!._run(args.sublist(i + 1), values, cancel);
        }
        rest.add(arg);
        continue;
      }

      final raw = arg.substring(isLong ? 2 : 1);
      final eq = raw.indexOf('=');
      final key = eq == -1 ? raw : raw.substring(0, eq);
      final inline = eq == -1 ? null : raw.substring(eq + 1);

      if (!ownsHelp && (isLong ? key == 'help' : key == 'h')) {
        printUsage();
        return;
      }
      if (isLong && key == 'version' && _version != null && findOption('version') == null) {
        Io.out.writeln('${_root.name} $_version');
        return;
      }

      final option = isLong ? findOption(key) : findAbbr(key);

      if (option == null && !isLong && key.length > 1) {
        // `-vd` is two flags; `-j4` is `-j 4`; `-vj4` is both.
        for (var k = 0; k < key.length; k++) {
          final each = findAbbr(key[k]);
          if (each == null) throw UsageException('Unknown option in "-$key": -${key[k]}');
          if (!each.takesValue) {
            values[each] = true;
            continue;
          }
          final attached = key.substring(k + 1);
          if (attached.isNotEmpty) {
            values[each] = each.parse(attached);
          } else if (i + 1 < args.length) {
            values[each] = each.parse(args[++i]);
          } else {
            throw UsageException('Option "-${key[k]}" requires a value.');
          }
          break;
        }
        continue;
      }

      if (option == null) throw UsageException('Unknown option: ${isLong ? '--' : '-'}$key');

      if (!option.takesValue) {
        values[option] = true;
      } else if (inline != null) {
        values[option] = option.parse(inline);
      } else if (i + 1 < args.length) {
        values[option] = option.parse(args[++i]);
      } else {
        throw UsageException('Option "${isLong ? '--' : '-'}$key" requires a value.');
      }
    }

    // Required checks cover this command and every ancestor; defaults live on the option.
    for (CliCommand? cur = this; cur != null; cur = cur.parent) {
      for (final option in cur.options) {
        if (option.isRequired && !values.containsKey(option)) {
          throw UsageException('Missing required option "--${option.name}".');
        }
      }
    }

    if (handler != null) {
      await handler!(CliContext(rest, values, this, cancel: cancel));
    } else {
      printUsage();
    }
  }
}

/// The root command: a program's name, version and entry point.
///
/// {@category CLI}
class Cli extends CliCommand {
  /// Printed by `--version` when set.
  final String? version;

  Cli({String name = 'app', String description = '', this.version, super.options})
    : super(name, description: description);

  /// Parses [args], runs the matching command, then runs the exit hooks and releases
  /// the signal handlers so the process can end — whether the action returned or threw.
  ///
  /// A usage error — unknown option, bad choice, missing required option — is printed
  /// to stderr and exits with code 64. [CliCommand.run] throws instead; use it to test.
  /// `ctx.cancel` is cancelled first on a signal, on [die], and when the action ends.
  @override
  Future<void> run(List<String> args) async {
    final cancel = CancelToken();
    onExit(cancel.cancel);
    try {
      await _run(args, {}, cancel);
    } on UsageException catch (e) {
      await die('${e.message}\n  Run "$name --help" for usage.', exitCode: 64);
    } finally {
      await runExitHooks();
      clearExitHooks();
    }
  }
}
