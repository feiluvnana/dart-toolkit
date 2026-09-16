import 'dart:convert';
import 'dart:io';

import 'ansi.dart';
import 'stdio.dart';

/// Helper for interactive terminal input and user prompts.
///
/// {@category CLI}
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
      ConsoleIo.out.write('$message$defaultHint: ');
      final input = ConsoleIo.readLine(encoding: utf8)?.trim() ?? '';

      if (input.isNotEmpty) return input;
      if (defaultTo != null) return defaultTo;
      if (!required) return '';

      ConsoleIo.out.writeln('  Value cannot be empty.'.red);
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
    ConsoleIo.out.write('$message $hint: ');
    final input = ConsoleIo.readLine(encoding: utf8)?.trim().toLowerCase() ?? '';

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
    ConsoleIo.out.write('$message: ');
    var isEchoModeAvailable = false;
    try {
      if (ConsoleIo.stdinLineReader == null && stdin.hasTerminal) {
        stdin.echoMode = false;
        isEchoModeAvailable = true;
      }
    } catch (_) {}

    try {
      final input = ConsoleIo.readLine(encoding: utf8)?.trim() ?? '';
      ConsoleIo.out.writeln();
      return input;
    } finally {
      if (isEchoModeAvailable) {
        try {
          stdin.echoMode = true;
        } catch (_) {}
      }
    }
  }

  /// Prompts the user to select one option from [choices].
  ///
  /// Example:
  /// ```dart
  /// final env = Prompt.select('Environment', ['dev', 'staging', 'prod']);
  /// ```
  static String select(String message, List<String> choices, [String? defaultTo]) {
    if (choices.isEmpty) {
      throw ArgumentError('Choices cannot be empty');
    }

    ConsoleIo.out.writeln('$message:');
    for (var i = 0; i < choices.length; i++) {
      final isDefault = choices[i] == defaultTo;
      final marker = isDefault ? ' (default)'.dim : '';
      ConsoleIo.out.writeln('  ${i + 1}) ${choices[i]}$marker');
    }

    while (true) {
      final defaultIndex = defaultTo != null ? choices.indexOf(defaultTo) + 1 : null;
      final defaultHint = defaultIndex != null && defaultIndex > 0 ? ' [$defaultIndex]' : '';
      ConsoleIo.out.write('Select [1-${choices.length}]$defaultHint: ');
      final input = ConsoleIo.readLine(encoding: utf8)?.trim() ?? '';

      if (input.isEmpty && defaultTo != null) return defaultTo;

      final index = int.tryParse(input);
      if (index != null && index >= 1 && index <= choices.length) {
        return choices[index - 1];
      }

      if (choices.contains(input)) {
        return input;
      }

      ConsoleIo.out.writeln('  Invalid choice, please enter a number from 1 to ${choices.length}.'.red);
    }
  }
}
