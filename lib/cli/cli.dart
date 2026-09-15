import 'dart:async';
import 'dart:io';

import 'ansi.dart';

export 'ansi.dart';
export 'console.dart';
export 'logger.dart';

/// Handler for executing a CLI command action.
typedef CommandHandler = FutureOr<void> Function(CliContext ctx);

/// Represents a CLI option/flag definition.
class CliOption {
  final String name;
  final String description;
  final List<String>? choice;
  final bool flag;
  final bool numeric;
  final bool text;
  final bool abbreviated;
  final String? defaultTo;

  CliOption(
    this.name, {
    this.description = '',
    this.choice,
    this.flag = false,
    this.numeric = false,
    this.text = false,
    this.abbreviated = false,
    this.defaultTo,
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

  /// Retrieves a double decimal option or fallback [defaultTo].
  double? decimal(String name, {double? defaultTo}) {
    final val = options[name];
    return val != null ? double.tryParse(val) ?? defaultTo : defaultTo;
  }

  /// Retrieves a comma-separated list option.
  List<String> list(String name, {String separator = ','}) {
    final val = options[name];
    if (val == null || val.isEmpty) return const [];
    return val.split(separator).map((s) => s.trim()).toList();
  }
}

/// Represents a CLI command or subcommand.
class CliCommand {
  final String name;
  final String description;
  final Map<String, CliOption> options = {};
  final Map<String, CliCommand> subcommands = {};
  CommandHandler? handler;

  CliCommand(this.name, {this.description = '', this.handler});

  /// Defines an option on this command.
  CliCommand option(
    String name, {
    String description = '',
    List<String>? choice,
    bool flag = false,
    bool numeric = false,
    bool text = false,
    bool abbreviated = false,
    String? defaultTo,
  }) {
    options[name] = CliOption(
      name,
      description: description,
      choice: choice,
      flag: flag,
      numeric: numeric,
      text: text,
      abbreviated: abbreviated,
      defaultTo: defaultTo,
    );
    return this;
  }

  /// Defines a nested subcommand on this command.
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
    if (description.isNotEmpty) {
      stdout.writeln('\n$description');
    }
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
        final choices = opt.choice != null ? ' [${opt.choice!.join(', ')}]' : '';
        stdout.writeln('  ${prefix.padRight(16)} ${opt.description}$choices');
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

    if (handler != null) {
      await handler!(CliContext(rest, parsedOptions, parsedFlags, this));
    } else if (subcommands.isNotEmpty) {
      printUsage();
    }
  }
}

/// Root builder for command-line applications.
class Cli {
  final String name;
  final String description;
  final Map<String, CliOption> globalOptions = {};
  final Map<String, CliCommand> commands = {};
  CommandHandler? defaultHandler;

  Cli({this.name = '', this.description = '', this.defaultHandler});

  /// Defines a command on this CLI application.
  CliCommand command(
    String name, {
    String description = '',
    CommandHandler? handler,
    void Function(CliCommand cmd)? build,
  }) {
    final cmd = CliCommand(name, description: description, handler: handler);
    build?.call(cmd);
    commands[name] = cmd;
    return cmd;
  }

  /// Defines a global option.
  Cli option(
    String name, {
    String description = '',
    List<String>? choice,
    bool flag = false,
    bool numeric = false,
    bool text = false,
    bool abbreviated = false,
    String? defaultTo,
  }) {
    globalOptions[name] = CliOption(
      name,
      description: description,
      choice: choice,
      flag: flag,
      numeric: numeric,
      text: text,
      abbreviated: abbreviated,
      defaultTo: defaultTo,
    );
    return this;
  }

  /// Sets the default action handler.
  Cli action(CommandHandler handler) {
    defaultHandler = handler;
    return this;
  }

  /// Prints CLI usage.
  void printUsage() {
    final appName = name.isNotEmpty ? name : 'app';
    stdout.writeln('${'Usage:'.bold} $appName [command] [options]');
    if (description.isNotEmpty) stdout.writeln('\n$description');
    if (commands.isNotEmpty) {
      stdout.writeln('\n${'Commands:'.bold}');
      for (final cmd in commands.values) {
        stdout.writeln('  ${cmd.name.padRight(16)} ${cmd.description}');
      }
    }
    stdout.writeln('\n${'Options:'.bold}');
    if (globalOptions.isNotEmpty) {
      for (final opt in globalOptions.values) {
        final prefix = opt.abbreviated ? '-${opt.name}' : '--${opt.name}';
        final choices = opt.choice != null ? ' [${opt.choice!.join(', ')}]' : '';
        stdout.writeln('  ${prefix.padRight(16)} ${opt.description}$choices');
      }
    }
    stdout.writeln('  --help, -h       Print this help message');
  }

  /// Dispatches and runs the CLI application with [args].
  Future<void> run(List<String> args) async {
    if (args.contains('--help') || args.contains('-h')) {
      if (!globalOptions.containsKey('help') && !globalOptions.containsKey('h')) {
        printUsage();
        return;
      }
    }

    if (args.isNotEmpty && commands.containsKey(args.first)) {
      await commands[args.first]!.run(args.sublist(1));
      return;
    }

    if (defaultHandler != null) {
      final parsedFlags = <String>{};
      final parsedOptions = <String, String?>{
        for (final opt in globalOptions.values)
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

          final optDef = globalOptions[name];
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
          final optDef = globalOptions[name];
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

      await defaultHandler!(CliContext(rest, parsedOptions, parsedFlags, CliCommand(name)));
    } else {
      printUsage();
    }
  }
}
