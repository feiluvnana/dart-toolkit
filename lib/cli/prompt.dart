import 'dart:convert';
import 'dart:io';

import 'ansi.dart';
import 'stdio.dart';

/// Helper for interactive terminal input and user prompts.
///
/// Every prompt degrades gracefully when no input is available (EOF, piped
/// stdin, or CI): instead of looping forever it falls back to the supplied
/// default, or throws a [StateError] when no default can be applied.
///
/// {@category CLI}
class Prompt {
  /// Reads one line, returning `null` at end of input.
  static String? _read() => ConsoleIo.readLine(encoding: utf8)?.trim();

  /// Prompts the user for text input.
  ///
  /// If [defaultTo] is provided, it is displayed in brackets and returned when the user presses Enter without typing.
  /// Pass [validate] to reject input: return an error message to re-prompt, or `null` to accept.
  ///
  /// Example:
  /// ```dart
  /// final name = Prompt.ask('Project name', 'my_app');
  /// final port = Prompt.ask('Port', '8080', validate: (v) => int.tryParse(v) == null ? 'Must be a number' : null);
  /// ```
  static String ask(String message, [String? defaultTo, bool required = false]) =>
      askWith(message, defaultTo: defaultTo, required: required);

  /// Prompts the user for text input with an optional [validate] callback.
  ///
  /// Separated from [ask] so the concise positional form stays unchanged.
  static String askWith(
    String message, {
    String? defaultTo,
    bool required = false,
    String? Function(String value)? validate,
  }) {
    while (true) {
      final defaultHint = defaultTo != null ? ' ($defaultTo)'.dim : '';
      ConsoleIo.out.write('$message$defaultHint: ');
      final input = _read();

      if (input == null) {
        // End of input: fall back rather than spinning forever.
        if (defaultTo != null) return defaultTo;
        if (!required) return '';
        throw StateError('No input available for required prompt: $message');
      }

      final value = input.isEmpty ? (defaultTo ?? '') : input;

      if (value.isEmpty && required) {
        ConsoleIo.out.writeln('  Value cannot be empty.'.red);
        continue;
      }

      final error = validate?.call(value);
      if (error != null) {
        ConsoleIo.out.writeln('  $error'.red);
        continue;
      }

      return value;
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
    final input = _read()?.toLowerCase();

    if (input == null || input.isEmpty) return defaultTo;
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
      final input = _read() ?? '';
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
  /// Works with any element type. Pass [display] to control how each choice is
  /// rendered, which keeps the prompt usable for records and domain objects.
  ///
  /// Example:
  /// ```dart
  /// final env = Prompt.select('Environment', ['dev', 'staging', 'prod']);
  ///
  /// final target = Prompt.select(
  ///   'Deploy target',
  ///   servers,
  ///   display: (s) => '${s.name} (${s.region})',
  /// );
  /// ```
  static T select<T>(String message, List<T> choices, {T? defaultTo, String Function(T choice)? display}) {
    if (choices.isEmpty) {
      throw ArgumentError('Choices cannot be empty');
    }

    String label(T choice) => display?.call(choice) ?? '$choice';

    final defaultIndex = defaultTo != null ? choices.indexOf(defaultTo as T) : -1;

    ConsoleIo.out.writeln('$message:');
    for (var i = 0; i < choices.length; i++) {
      final marker = i == defaultIndex ? ' (default)'.dim : '';
      ConsoleIo.out.writeln('  ${i + 1}) ${label(choices[i])}$marker');
    }

    while (true) {
      final defaultHint = defaultIndex >= 0 ? ' [${defaultIndex + 1}]' : '';
      ConsoleIo.out.write('Select [1-${choices.length}]$defaultHint: ');
      final input = _read();

      if (input == null) {
        if (defaultIndex >= 0) return choices[defaultIndex];
        throw StateError('No input available for required prompt: $message');
      }

      if (input.isEmpty && defaultIndex >= 0) return choices[defaultIndex];

      final index = int.tryParse(input);
      if (index != null && index >= 1 && index <= choices.length) {
        return choices[index - 1];
      }

      final match = choices.where((c) => label(c) == input);
      if (match.isNotEmpty) return match.first;

      ConsoleIo.out.writeln('  Invalid choice, please enter a number from 1 to ${choices.length}.'.red);
    }
  }
}
