import 'dart:async';

import '../util/stdio.dart';
import 'ansi.dart';
import 'lifecycle.dart';

/// Callback action executed when a CLI command is triggered.
typedef CommandHandler = FutureOr<void> Function(CliContext ctx);

/// An option declared on a [CliCommand].
///
/// The four kinds are mutually exclusive, so an option cannot be both a flag
/// and numeric.
///
/// {@category CLI}
sealed class CliOption {
  /// The long name, used as `--name`.
  final String name;

  /// Help text shown by [CliCommand.printUsage].
  final String description;

  /// The single-character short form, used as `-a`.
  final String? abbr;

  const CliOption(this.name, {this.description = '', this.abbr})
    : assert(abbr == null || abbr.length == 1, 'abbr is one character');

  /// The default as it appears in help text, or `null` when there is none.
  String? get defaultLabel;

  /// Whether parsing fails when this option is absent. Never true for a [CliFlag].
  bool get required;
}

/// A boolean option. Present means true; it never consumes a value.
///
/// {@category CLI}
final class CliFlag extends CliOption {
  const CliFlag(super.name, {super.description, super.abbr});

  @override
  String? get defaultLabel => null;

  /// Always false: an absent flag is simply false.
  @override
  bool get required => false;
}

/// An option taking an arbitrary string value.
///
/// {@category CLI}
final class CliValue extends CliOption {
  /// Used when the option is absent.
  final String? defaultTo;

  @override
  final bool required;

  const CliValue(super.name, {super.description, super.abbr, this.defaultTo, this.required = false})
    : assert(!(required && defaultTo != null), 'A required option cannot also have a default.');

  @override
  String? get defaultLabel => defaultTo;
}

/// An option taking an integer value, validated during parsing.
///
/// {@category CLI}
final class CliNumber extends CliOption {
  /// Used when the option is absent.
  final int? defaultTo;

  @override
  final bool required;

  const CliNumber(super.name, {super.description, super.abbr, this.defaultTo, this.required = false})
    : assert(!(required && defaultTo != null), 'A required option cannot also have a default.');

  @override
  String? get defaultLabel => defaultTo?.toString();
}

/// An option restricted to [choices], validated during parsing.
///
/// {@category CLI}
final class CliChoice extends CliOption {
  /// The permitted values.
  final List<String> choices;

  /// Used when the option is absent.
  final String? defaultTo;

  @override
  final bool required;

  const CliChoice(super.name, this.choices, {super.description, super.abbr, this.defaultTo, this.required = false})
    : assert(!(required && defaultTo != null), 'A required option cannot also have a default.');

  @override
  String? get defaultLabel => defaultTo;
}

/// Parsed arguments passed to a [CommandHandler].
///
/// {@category CLI}
class CliContext {
  /// Positional arguments, plus everything after a `--` terminator.
  final List<String> rest;

  /// Parsed option values. A [CliNumber] is stored as an `int`, parsed once.
  final Map<String, Object?> values;

  /// Flags that were present.
  final Set<String> flags;

  /// The command that was dispatched.
  final CliCommand command;

  CliContext(this.rest, this.values, this.flags, this.command);

  /// Whether [name] was set.
  bool flag(String name) => flags.contains(name);

  /// The string value of [name], or `null` when it was neither given nor defaulted.
  String? optionOrNull(String name) => values[name]?.toString();

  /// The integer value of [name], or `null` when it was neither given nor defaulted.
  int? numberOrNull(String name) => values[name] as int?;

  /// The string value of [name]. A declared default or `required: true` guarantees one.
  ///
  /// Throws [StateError] when the option is absent; use [optionOrNull] for one that may be.
  String option(String name) => optionOrNull(name) ?? _missing(name);

  /// The integer value of [name]. A declared default or `required: true` guarantees one.
  ///
  /// Throws [StateError] when the option is absent; use [numberOrNull] for one that may be.
  int number(String name) => numberOrNull(name) ?? _missing(name);

  Never _missing(String name) => throw StateError('Option "--$name" was not given and has no default.');
}

/// A command, or a whole command-line application.
///
/// Every builder method returns the receiver, so a chain always configures one
/// command; nested commands are built through [command]'s `build` callback.
///
/// {@category CLI}
class CliCommand {
  final String name;
  final String description;
  final Map<String, CliOption> options = {};
  final Map<String, CliCommand> subcommands = {};
  final CliCommand? parent;
  CommandHandler? handler;

  CliCommand(this.name, {this.description = '', this.handler, this.parent});

  /// Looks up an option by name, walking up to the root command.
  CliOption? findOption(String name) => options[name] ?? parent?.findOption(name);

  /// Looks up an option by short form, walking up to the root command.
  CliOption? findAbbr(String abbr) {
    for (final option in options.values) {
      if (option.abbr == abbr) return option;
    }
    return parent?.findAbbr(abbr);
  }

  /// Declares [option] on this command. A [CliChoice] default must be one of its choices.
  CliCommand declare(CliOption option) {
    if (option case CliChoice(:final defaultTo?, :final choices) when !choices.contains(defaultTo)) {
      throw ArgumentError.value(defaultTo, 'defaultTo', 'Not one of ${choices.join(', ')}');
    }
    options[option.name] = option;
    return this;
  }

  /// Declares a string option.
  CliCommand option(String name, {String description = '', String? abbr, String? defaultTo, bool required = false}) =>
      declare(CliValue(name, description: description, abbr: abbr, defaultTo: defaultTo, required: required));

  /// Declares a boolean flag.
  CliCommand flag(String name, {String description = '', String? abbr}) =>
      declare(CliFlag(name, description: description, abbr: abbr));

  /// Declares an option restricted to [choices].
  CliCommand choice(
    String name,
    List<String> choices, {
    String description = '',
    String? abbr,
    String? defaultTo,
    bool required = false,
  }) =>
      declare(CliChoice(name, choices, description: description, abbr: abbr, defaultTo: defaultTo, required: required));

  /// Declares an integer option, validated during parsing.
  CliCommand number(String name, {String description = '', String? abbr, int? defaultTo, bool required = false}) =>
      declare(CliNumber(name, description: description, abbr: abbr, defaultTo: defaultTo, required: required));

  /// Declares a nested command, configured through [build].
  ///
  /// Returns this command, not the child, so a chain stays on one receiver.
  CliCommand command(
    String name, {
    String description = '',
    CommandHandler? handler,
    void Function(CliCommand)? build,
  }) {
    final sub = CliCommand(name, description: description, handler: handler, parent: this);
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
    ConsoleIo.out.writeln('${'Usage:'.bold} $_fullName [options] [command]');
    if (description.isNotEmpty) ConsoleIo.out.writeln('\n$description');
    if (subcommands.isNotEmpty) {
      ConsoleIo.out.writeln('\n${'Commands:'.bold}');
      for (final sub in subcommands.values) {
        ConsoleIo.out.writeln('  ${sub.name.padRight(20)} ${sub.description}');
      }
    }
    if (options.isNotEmpty) {
      ConsoleIo.out.writeln('\n${'Options:'.bold}');
      for (final option in options.values) {
        final optName = '--${option.name}';
        final prefix = option.abbr != null ? '-${option.abbr}, $optName' : '    $optName';
        var desc = option.description;
        if (option is CliChoice && option.choices.isNotEmpty) {
          final list = '(${option.choices.join('|')})';
          desc = desc.isEmpty ? list : '$desc $list';
        }
        final fallback = option.defaultLabel;
        if (fallback != null) desc = '$desc [default: $fallback]';
        if (option.required) desc = '$desc [required]';
        ConsoleIo.out.writeln('  ${prefix.padRight(20)} $desc');
      }
    }
    ConsoleIo.out.writeln('  -h, --help           Print this help message');
  }

  String get _fullName => parent == null ? name : '${parent!._fullName} $name';

  /// Parses [args] and runs this command, or a matching subcommand.
  ///
  /// Options may precede the subcommand (`app -v fetch`); short flags combine (`-vd`)
  /// and a short option may attach its value (`-j4`). Usage errors throw [ArgumentError];
  /// [Cli.run] turns them into a message and exit code 64.
  Future<void> run(List<String> args) => _run(args, {}, {});

  Future<void> _run(List<String> args, Map<String, Object?> values, Set<String> flags) async {
    final rest = <String>[];
    final ownsHelp = findOption('help') != null || findAbbr('h') != null;

    void assign(CliOption option, String raw) {
      switch (option) {
        case CliFlag():
          flags.add(option.name);
        case CliNumber():
          final value = int.tryParse(raw);
          if (value == null) {
            throw ArgumentError('Invalid numeric value "$raw" for option "${option.name}". Expected an integer.');
          }
          values[option.name] = value;
        case CliChoice(:final choices):
          if (!choices.contains(raw)) {
            throw ArgumentError(
              'Invalid value "$raw" for option "${option.name}". Allowed choices: ${choices.join(', ')}',
            );
          }
          values[option.name] = raw;
        case CliValue():
          values[option.name] = raw;
      }
    }

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
          return subcommands[arg]!._run(args.sublist(i + 1), values, flags);
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

      final option = isLong ? findOption(key) : findAbbr(key);
      if (option == null && !isLong && key.length > 1) {
        // `-vd` is two flags; `-j4` is `-j 4`; `-vj4` is both.
        for (var k = 0; k < key.length; k++) {
          final each = findAbbr(key[k]);
          if (each == null) throw ArgumentError('Unknown option in "-$key": -${key[k]}');
          if (each is CliFlag) {
            flags.add(each.name);
            continue;
          }
          final attached = key.substring(k + 1);
          if (attached.isNotEmpty) {
            assign(each, attached);
          } else if (i + 1 < args.length) {
            assign(each, args[++i]);
          } else {
            throw ArgumentError('Option "-${key[k]}" requires a value.');
          }
          break;
        }
        continue;
      }
      if (option == null) throw ArgumentError('Unknown option: ${isLong ? '--' : '-'}$key');

      if (option is CliFlag) {
        flags.add(option.name);
      } else if (inline != null) {
        assign(option, inline);
      } else if (i + 1 < args.length) {
        assign(option, args[++i]);
      } else {
        throw ArgumentError('Option "${isLong ? '--' : '-'}$key" requires a value.');
      }
    }

    // Defaults and required checks cover this command and every ancestor.
    for (CliCommand? cur = this; cur != null; cur = cur.parent) {
      for (final option in cur.options.values) {
        final fallback = switch (option) {
          CliValue(:final defaultTo) => defaultTo,
          CliNumber(:final defaultTo) => defaultTo,
          CliChoice(:final defaultTo) => defaultTo,
          CliFlag() => null,
        };
        if (fallback != null) values.putIfAbsent(option.name, () => fallback);
        if (option.required && !values.containsKey(option.name)) {
          throw ArgumentError('Missing required option "--${option.name}".');
        }
      }
    }

    if (handler != null) {
      await handler!(CliContext(rest, values, flags, this));
    } else {
      printUsage();
    }
  }
}

/// The root of a command-line application.
///
/// {@category CLI}
class Cli extends CliCommand {
  Cli({String name = 'app', String description = ''}) : super(name, description: description);

  /// Parses [args], runs the matching command, then runs the exit hooks and releases
  /// the signal handlers so the process can end.
  ///
  /// A usage error — unknown option, bad choice, missing required option — is printed
  /// to stderr and exits with code 64. [CliCommand.run] throws instead; use it to test.
  @override
  Future<void> run(List<String> args) async {
    try {
      await super.run(args);
    } on ArgumentError catch (e) {
      await die('${e.message}\n  Run "$name --help" for usage.', exitCode: 64);
    }
    await runExitHooks();
    clearExitHooks();
  }
}
