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
  final String? abbr;
  final String? defaultTo;
  final List<String>? choices;

  CliOption(
    this.name, {
    this.description = '',
    this.flag = false,
    this.numeric = false,
    this.abbr,
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
  final CliCommand? parent;
  CommandHandler? handler;

  CliCommand(this.name, {this.description = '', this.handler, this.parent});

  /// Finds an option definition by full name in this command or its parent hierarchy.
  CliOption? findOption(String name) => options[name] ?? parent?.findOption(name);

  /// Finds an option definition by abbreviation in this command or its parent hierarchy.
  CliOption? findAbbr(String abbr) {
    for (final opt in options.values) {
      if (opt.abbr == abbr) return opt;
    }
    return parent?.findAbbr(abbr);
  }

  /// Defines an option or flag on this command.
  CliCommand option(
    String name, {
    String description = '',
    bool flag = false,
    bool numeric = false,
    String? abbr,
    String? defaultTo,
    List<String>? choices,
  }) {
    options[name] = CliOption(
      name,
      description: description,
      flag: flag,
      numeric: numeric,
      abbr: abbr,
      defaultTo: defaultTo,
      choices: choices,
    );
    return this;
  }

  /// Defines a boolean flag on this command.
  CliCommand flag(
    String name, {
    String description = '',
    String? abbr,
  }) {
    return option(
      name,
      description: description,
      flag: true,
      abbr: abbr,
    );
  }

  /// Defines an option with a constrained list of valid [choices].
  CliCommand choice(
    String name,
    List<String> choices, {
    String description = '',
    String? abbr,
    String? defaultTo,
  }) {
    return option(
      name,
      description: description,
      abbr: abbr,
      defaultTo: defaultTo,
      choices: choices,
    );
  }

  /// Defines an integer numeric option on this command with automatic number validation.
  CliCommand number(
    String name, {
    String description = '',
    String? abbr,
    int? defaultTo,
  }) {
    return option(
      name,
      description: description,
      numeric: true,
      abbr: abbr,
      defaultTo: defaultTo?.toString(),
    );
  }

  /// Defines a nested subcommand.
  CliCommand subcommand(
    String name, {
    String description = '',
    CommandHandler? handler,
    void Function(CliCommand sub)? build,
  }) {
    final sub = CliCommand(name, description: description, handler: handler, parent: this);
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
        stdout.writeln('  ${sub.name.padRight(20)} ${sub.description}');
      }
    }
    if (options.isNotEmpty) {
      stdout.writeln('\n${'Options:'.bold}');
      for (final opt in options.values) {
        final optName = '--${opt.name}';
        final optPrefix = opt.abbr != null ? '-${opt.abbr}, $optName' : '    $optName';
        var desc = opt.description;
        if (opt.choices != null && opt.choices!.isNotEmpty) {
          final choiceList = '(${opt.choices!.join('|')})';
          desc = desc.isEmpty ? choiceList : '$desc $choiceList';
        }
        if (opt.defaultTo != null) {
          desc = '$desc [default: ${opt.defaultTo}]';
        }
        stdout.writeln('  ${optPrefix.padRight(20)} $desc');
      }
    }
    stdout.writeln('  -h, --help           Print this help message');
  }

  /// Dispatches and runs this command with [args].
  Future<void> run(List<String> args) async {
    if (args.contains('--help') || args.contains('-h')) {
      if (findOption('help') == null && findAbbr('h') == null) {
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

        final optDef = findOption(name);
        if (optDef == null) {
          throw ArgumentError('Unknown option: --$name');
        }

        if (optDef.flag) {
          parsedFlags.add(optDef.name);
        } else if (val != null) {
          parsedOptions[optDef.name] = val;
        } else if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
          parsedOptions[optDef.name] = args[++i];
        } else {
          parsedFlags.add(optDef.name);
        }
      } else if (arg.startsWith('-') && arg.length > 1) {
        final raw = arg.substring(1);
        final eq = raw.indexOf('=');
        final key = eq == -1 ? raw : raw.substring(0, eq);
        final val = eq == -1 ? null : raw.substring(eq + 1);

        final optDef = findAbbr(key);
        if (optDef == null) {
          throw ArgumentError('Unknown option: -$key');
        }

        if (optDef.flag) {
          parsedFlags.add(optDef.name);
        } else if (val != null) {
          parsedOptions[optDef.name] = val;
        } else if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
          parsedOptions[optDef.name] = args[++i];
        } else {
          parsedFlags.add(optDef.name);
        }
      } else {
        rest.add(arg);
      }
    }

    // Validate choices and numeric options
    for (final entry in parsedOptions.entries) {
      final optDef = findOption(entry.key);
      if (optDef != null && entry.value != null) {
        if (optDef.choices != null && !optDef.choices!.contains(entry.value)) {
          throw ArgumentError(
            'Invalid value "${entry.value}" for option "${optDef.name}". Allowed choices: ${optDef.choices!.join(', ')}',
          );
        }
        if (optDef.numeric && int.tryParse(entry.value!) == null) {
          throw ArgumentError(
            'Invalid numeric value "${entry.value}" for option "${optDef.name}". Expected an integer.',
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
