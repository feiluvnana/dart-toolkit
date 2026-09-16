import 'dart:async';
import 'dart:io';

import 'ansi.dart';

export 'ansi.dart';
export 'console.dart';
export 'lifecycle.dart';
export 'logger.dart';
export 'prompt.dart';

/// Handler for executing a CLI command action.
typedef CommandHandler = FutureOr<void> Function(CliContext ctx);

/// Represents a CLI option or flag definition.
class CliOption {
  final String name;
  final String description;
  final bool flag;
  final bool numeric;
  final bool abbreviated;
  final String? defaultTo;
  final List<String>? choices;

  CliOption(
    this.name, {
    this.description = '',
    this.flag = false,
    this.numeric = false,
    this.abbreviated = false,
    this.defaultTo,
    this.choices,
  });
}

/// Execution context provided to a command action containing parsed arguments.
class CliContext {
  final List<String> rest;
  final Map<String, String?> options;
  final Set<String> flags;
  final CliCommand command;

  CliContext(this.rest, this.options, this.flags, this.command);

  /// Checks if a boolean flag was supplied.
  bool flag(String name) => flags.contains(name);

  /// Retrieves an option string value or fallback [defaultTo].
  String? option(String name, {String? defaultTo}) => options[name] ?? defaultTo;

  /// Retrieves an integer option or fallback [defaultTo].
  int? number(String name, {int? defaultTo}) {
    final val = options[name];
    return val != null ? int.tryParse(val) ?? defaultTo : defaultTo;
  }
}

/// Represents a CLI command or application.
class CliCommand {
  final String name;
  final String description;
  final Map<String, CliOption> options = {};
  final Map<String, CliCommand> subcommands = {};
  CommandHandler? handler;

  CliCommand(this.name, {this.description = '', this.handler});

  /// Defines an option or flag on this command.
  CliCommand option(
    String name, {
    String description = '',
    bool flag = false,
    bool numeric = false,
    bool abbreviated = false,
    String? defaultTo,
    List<String>? choices,
  }) {
    options[name] = CliOption(
      name,
      description: description,
      flag: flag,
      numeric: numeric,
      abbreviated: abbreviated,
      defaultTo: defaultTo,
      choices: choices,
    );
    return this;
  }

  /// Defines an option with a constrained list of valid [choices].
  CliCommand choice(
    String name,
    List<String> choices, {
    String description = '',
    bool abbreviated = false,
    String? defaultTo,
  }) {
    return option(
      name,
      description: description,
      abbreviated: abbreviated,
      defaultTo: defaultTo,
      choices: choices,
    );
  }

  /// Defines a nested subcommand.
  CliCommand subcommand(
    String name, {
    String description = '',
    CommandHandler? handler,
    void Function(CliCommand sub)? build,
  }) {
    final sub = CliCommand(name, description: description, handler: handler);
    build?.call(sub);
    subcommands[name] = sub;
    return sub;
  }

  /// Sets the handler action for this command.
  CliCommand action(CommandHandler actionHandler) {
    handler = actionHandler;
    return this;
  }

  /// Prints usage help for this command.
  void printUsage() {
    stdout.writeln('${'Usage:'.bold} $name [options] [command]');
    if (description.isNotEmpty) stdout.writeln('\n$description');
    if (subcommands.isNotEmpty) {
      stdout.writeln('\n${'Commands:'.bold}');
      for (final sub in subcommands.values) {
        stdout.writeln('  ${sub.name.padRight(16)} ${sub.description}');
      }
    }
    if (options.isNotEmpty) {
      stdout.writeln('\n${'Options:'.bold}');
      for (final opt in options.values) {
        final prefix = opt.abbreviated ? '-${opt.name}' : '--${opt.name}';
        var desc = opt.description;
        if (opt.choices != null && opt.choices!.isNotEmpty) {
          final choiceList = '(${opt.choices!.join('|')})';
          desc = desc.isEmpty ? choiceList : '$desc $choiceList';
        }
        if (opt.defaultTo != null) {
          desc = '$desc [default: ${opt.defaultTo}]';
        }
        stdout.writeln('  ${prefix.padRight(16)} $desc');
      }
    }
    stdout.writeln('  --help, -h       Print this help message');
  }

  /// Dispatches and runs this command with [args].
  Future<void> run(List<String> args) async {
    if (args.contains('--help') || args.contains('-h')) {
      if (!options.containsKey('help') && !options.containsKey('h')) {
        printUsage();
        return;
      }
    }

    if (args.isNotEmpty && subcommands.containsKey(args.first)) {
      final sub = subcommands[args.first]!;
      await sub.run(args.sublist(1));
      return;
    }

    final parsedFlags = <String>{};
    final parsedOptions = <String, String?>{
      for (final opt in options.values)
        if (opt.defaultTo != null) opt.name: opt.defaultTo,
    };
    final rest = <String>[];

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg.startsWith('--')) {
        final raw = arg.substring(2);
        final eq = raw.indexOf('=');
        final name = eq == -1 ? raw : raw.substring(0, eq);
        final val = eq == -1 ? null : raw.substring(eq + 1);

        final optDef = options[name];
        if (optDef?.flag == true) {
          parsedFlags.add(name);
        } else if (val != null) {
          parsedOptions[name] = val;
        } else if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
          parsedOptions[name] = args[++i];
        } else {
          parsedFlags.add(name);
        }
      } else if (arg.startsWith('-') && arg.length > 1) {
        final name = arg.substring(1);
        final optDef = options[name];
        if (optDef?.flag == true) {
          parsedFlags.add(name);
        } else if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
          parsedOptions[name] = args[++i];
        } else {
          parsedFlags.add(name);
        }
      } else {
        rest.add(arg);
      }
    }

    // Validate choices
    for (final entry in parsedOptions.entries) {
      final optDef = options[entry.key];
      if (optDef != null && optDef.choices != null && entry.value != null) {
        if (!optDef.choices!.contains(entry.value)) {
          throw ArgumentError(
            'Invalid value "${entry.value}" for option "${optDef.name}". Allowed choices: ${optDef.choices!.join(', ')}',
          );
        }
      }
    }

    if (handler != null) {
      await handler!(CliContext(rest, parsedOptions, parsedFlags, this));
    } else {
      printUsage();
    }
  }
}

/// Root builder for command-line applications.
class Cli extends CliCommand {
  Cli({String name = '', String description = '', CommandHandler? defaultHandler})
    : super(name, description: description, handler: defaultHandler);

  /// Defines a command on this CLI application.
  CliCommand command(
    String name, {
    String description = '',
    CommandHandler? handler,
    void Function(CliCommand cmd)? build,
  }) => subcommand(name, description: description, handler: handler, build: build);
}
