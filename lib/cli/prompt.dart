import 'dart:convert';
import 'dart:io';

import 'ansi.dart';

/// Helper for interactive terminal input and user prompts.
class Prompt {
  /// Prompts the user for text input.
  ///
  /// If [defaultTo] is provided, it is displayed in brackets and returned when the user presses Enter without typing.
  ///
  /// Example:
  /// ```dart
  /// final name = Prompt.ask('Project name', 'my_app');
  /// ```
  static String ask(String message, [String? defaultTo, bool required = false]) {
    while (true) {
      final defaultHint = defaultTo != null ? ' ($defaultTo)'.dim : '';
      stdout.write('$message$defaultHint: ');
      final input = stdin.readLineSync(encoding: utf8)?.trim() ?? '';

      if (input.isNotEmpty) return input;
      if (defaultTo != null) return defaultTo;
      if (!required) return '';

      stdout.writeln('  Value cannot be empty.'.red);
    }
  }

  /// Prompts the user for a yes/no boolean confirmation.
  ///
  /// Example:
  /// ```dart
  /// if (Prompt.confirm('Deploy to production?', false)) {
  ///   ...
  /// }
  /// ```
  static bool confirm(String message, [bool defaultTo = true]) {
    final hint = defaultTo ? '[Y/n]'.dim : '[y/N]'.dim;
    stdout.write('$message $hint: ');
    final input = stdin.readLineSync(encoding: utf8)?.trim().toLowerCase() ?? '';

    if (input.isEmpty) return defaultTo;
    return input == 'y' || input == 'yes' || input == 'true' || input == '1';
  }

  /// Prompts the user for sensitive input (password, API keys) hiding typed characters.
  ///
  /// Example:
  /// ```dart
  /// final token = Prompt.secret('Enter API Token:');
  /// ```
  static String secret(String message) {
    stdout.write('$message: ');
    var isEchoModeAvailable = false;
    try {
      if (stdin.hasTerminal) {
        stdin.echoMode = false;
        isEchoModeAvailable = true;
      }
    } catch (_) {}

    try {
      final line = stdin.readLineSync(encoding: utf8) ?? '';
      stdout.writeln();
      return line.trim();
    } finally {
      if (isEchoModeAvailable) {
        try {
          stdin.echoMode = true;
        } catch (_) {}
      }
    }
  }

  /// Prompts the user to pick an option from a list of choices.
  ///
  /// Example:
  /// ```dart
  /// final env = Prompt.select('Target environment:', ['staging', 'production']);
  /// ```
  static T select<T>(String message, List<T> options, [int defaultIndex = 0, String Function(T item)? display]) {
    if (options.isEmpty) {
      throw ArgumentError('Options list cannot be empty');
    }

    stdout.writeln(message.bold);
    for (var i = 0; i < options.length; i++) {
      final label = display != null ? display(options[i]) : options[i].toString();
      final num = '${i + 1}'.cyan;
      stdout.writeln('  $num) $label');
    }

    while (true) {
      stdout.write('Choose an option [1-${options.length}] (default: ${defaultIndex + 1}): ');
      final input = stdin.readLineSync(encoding: utf8)?.trim() ?? '';

      if (input.isEmpty) {
        return options[defaultIndex.clamp(0, options.length - 1)];
      }

      final parsed = int.tryParse(input);
      if (parsed != null && parsed >= 1 && parsed <= options.length) {
        return options[parsed - 1];
      }

      stdout.writeln('  Invalid choice. Please enter a number between 1 and ${options.length}.'.red);
    }
  }
}
