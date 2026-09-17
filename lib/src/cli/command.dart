import 'dart:async';

import '../util/stdio.dart';
import 'ansi.dart';

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

  const CliOption(this.name, {this.description = '', this.abbr});

  /// The default as it appears in help text, or `null` when there is none.
  String? get defaultLabel;
}

/// A boolean option. Present means true; it never consumes a value.
///
/// {@category CLI}
final class CliFlag extends CliOption {
  const CliFlag(super.name, {super.description, super.abbr});

  @override
  String? get defaultLabel => null;
}

/// An option taking an arbitrary string value.
///
/// {@category CLI}
final class CliValue extends CliOption {
  /// Used when the option is absent.
  final String? defaultTo;

  const CliValue(super.name, {super.description, super.abbr, this.defaultTo});

  @override
  String? get defaultLabel => defaultTo;
}

/// An option taking an integer value, validated during parsing.
///
/// {@category CLI}
final class CliNumber extends CliOption {
  /// Used when the option is absent.
  final int? defaultTo;

  const CliNumber(super.name, {super.description, super.abbr, this.defaultTo});

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

  const CliChoice(super.name, this.choices, {super.description, super.abbr, this.defaultTo});

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

  /// The string value of [name], or [defaultTo].
  String? option(String name, {String? defaultTo}) => values[name]?.toString() ?? defaultTo;

  /// The integer value of [name], or [defaultTo].
  int? number(String name, {int? defaultTo}) => switch (values[name]) {
    final int value => value,
    final String value => int.tryParse(value) ?? defaultTo,
    _ => defaultTo,
  };
}

/// A command, or a whole command-line application.
///
/// Every builder method returns the receiver, so a chain always configures one
/// command; nested commands are built through [subcommand]'s `build` callback.
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

  /// Declares [option] on this command.
  CliCommand declare(CliOption option) {
    options[option.name] = option;
    return this;
  }

  /// Declares a string option.
  CliCommand option(String name, {String description = '', String? abbr, String? defaultTo}) =>
      declare(CliValue(name, description: description, abbr: abbr, defaultTo: defaultTo));

  /// Declares a boolean flag.
  CliCommand flag(String name, {String description = '', String? abbr}) =>
      declare(CliFlag(name, description: description, abbr: abbr));

  /// Declares an option restricted to [choices].
  CliCommand choice(String name, List<String> choices, {String description = '', String? abbr, String? defaultTo}) =>
      declare(CliChoice(name, choices, description: description, abbr: abbr, defaultTo: defaultTo));

  /// Declares an integer option, validated during parsing.
  CliCommand number(String name, {String description = '', String? abbr, int? defaultTo}) =>
      declare(CliNumber(name, description: description, abbr: abbr, defaultTo: defaultTo));

  /// Declares a nested subcommand, configured through [build].
  ///
  /// Returns this command, not the child, so a chain stays on one receiver.
  CliCommand subcommand(
    String name, {
    String description = '',
    CommandHandler? handler,
    void Function(CliCommand sub)? build,
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
    ConsoleIo.out.writeln('${'Usage:'.bold} $name [options] [command]');
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
        ConsoleIo.out.writeln('  ${prefix.padRight(20)} $desc');
      }
    }
    ConsoleIo.out.writeln('  -h, --help           Print this help message');
  }

  /// Parses [args] and runs this command, or a matching subcommand.
  Future<void> run(List<String> args) async {
    if (args.contains('--help') || args.contains('-h')) {
      if (findOption('help') == null && findAbbr('h') == null) {
        printUsage();
        return;
      }
    }

    if (args.isNotEmpty && subcommands.containsKey(args.first)) {
      await subcommands[args.first]!.run(args.sublist(1));
      return;
    }

    final parsedFlags = <String>{};
    final parsedValues = <String, Object?>{};
    final rest = <String>[];

    // Defaults come from this command and every ancestor, nearest first.
    for (var cur = this; ; cur = cur.parent!) {
      for (final option in cur.options.values) {
        final fallback = switch (option) {
          CliValue(:final defaultTo) => defaultTo,
          CliNumber(:final defaultTo) => defaultTo,
          CliChoice(:final defaultTo) => defaultTo,
          CliFlag() => null,
        };
        if (fallback != null) parsedValues.putIfAbsent(option.name, () => fallback);
      }
      if (cur.parent == null) break;
    }

    void assign(CliOption option, String raw) {
      switch (option) {
        case CliFlag():
          parsedFlags.add(option.name);
        case CliNumber():
          final value = int.tryParse(raw);
          if (value == null) {
            throw ArgumentError('Invalid numeric value "$raw" for option "${option.name}". Expected an integer.');
          }
          parsedValues[option.name] = value;
        case CliChoice(:final choices):
          if (!choices.contains(raw)) {
            throw ArgumentError(
              'Invalid value "$raw" for option "${option.name}". Allowed choices: ${choices.join(', ')}',
            );
          }
          parsedValues[option.name] = raw;
        case CliValue():
          parsedValues[option.name] = raw;
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
        rest.add(arg);
        continue;
      }

      final raw = arg.substring(isLong ? 2 : 1);
      final eq = raw.indexOf('=');
      final key = eq == -1 ? raw : raw.substring(0, eq);
      final inline = eq == -1 ? null : raw.substring(eq + 1);

      final option = isLong ? findOption(key) : findAbbr(key);
      if (option == null) throw ArgumentError('Unknown option: ${isLong ? '--' : '-'}$key');

      if (option is CliFlag) {
        parsedFlags.add(option.name);
      } else if (inline != null) {
        assign(option, inline);
      } else if (i + 1 < args.length) {
        assign(option, args[++i]);
      } else {
        throw ArgumentError('Option "${isLong ? '--' : '-'}$key" requires a value.');
      }
    }

    // Defaults bypass assign(), so validate them here.
    for (final entry in parsedValues.entries) {
      final option = findOption(entry.key);
      if (option is CliChoice && !option.choices.contains(entry.value)) {
        throw ArgumentError(
          'Invalid value "${entry.value}" for option "${option.name}". '
          'Allowed choices: ${option.choices.join(', ')}',
        );
      }
    }

    if (handler != null) {
      await handler!(CliContext(rest, parsedValues, parsedFlags, this));
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

  /// Declares a top-level command, configured through [build].
  CliCommand command(
    String name, {
    String description = '',
    CommandHandler? handler,
    void Function(CliCommand)? build,
  }) => subcommand(name, description: description, handler: handler, build: build);
}
