import 'dart:convert';
import 'dart:io';

import '../util/stdio.dart';
import 'ansi.dart';

/// Interactive terminal prompts.
///
/// At end of input — piped stdin, CI — a prompt falls back to its default
/// rather than looping forever, or throws [StateError] when it has none.
///
/// {@category CLI}
class Prompt {
  /// Reads one line, returning `null` at end of input.
  static String? _read() => ConsoleIo.readLine(encoding: utf8)?.trim();

  /// Prompts for text input, returning [defaultTo] on an empty answer.
  ///
  /// [validate] returns an error message to re-prompt, or `null` to accept.
  /// At end of input the default is used, or a [StateError] is thrown when a
  /// [required] value has none.
  ///
  /// ```dart
  /// final port = Prompt.ask('Port', defaultTo: '8080',
  ///     validate: (v) => int.tryParse(v) == null ? 'Must be a number' : null);
  /// ```
  static String ask(
    String message, {
    String? defaultTo,
    bool required = false,
    String? Function(String value)? validate,
  }) {
    assert(!(required && defaultTo != null), 'A required prompt cannot also have a default.');
    while (true) {
      final defaultHint = defaultTo != null ? ' ($defaultTo)'.dim : '';
      ConsoleIo.out.write('$message$defaultHint: ');
      final input = _read();

      if (input == null) {
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

  /// Prompts for a yes/no confirmation.
  static bool confirm(String message, [bool defaultTo = true]) {
    final hint = defaultTo ? '[Y/n]'.dim : '[y/N]'.dim;
    ConsoleIo.out.write('$message $hint: ');
    final input = _read()?.toLowerCase();

    if (input == null || input.isEmpty) return defaultTo;
    return input == 'y' || input == 'yes' || input == 'true' || input == '1';
  }

  /// Prompts for sensitive input, hiding typed characters.
  static String secret(String message) {
    ConsoleIo.out.write('$message: ');
    var isEchoModeAvailable = false;
    try {
      if (ConsoleIo.input == null && stdin.hasTerminal) {
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

  /// Prompts for one of [choices], of any element type.
  ///
  /// [display] renders each choice, which keeps records and domain objects usable:
  /// `Prompt.select('Target', servers, display: (s) => s.name)`.
  static T select<T>(String message, List<T> choices, {T? defaultTo, String Function(T choice)? display}) {
    if (choices.isEmpty) {
      throw ArgumentError('Choices cannot be empty');
    }

    String label(T choice) => display?.call(choice) ?? '$choice';

    final defaultIndex = defaultTo != null ? choices.indexOf(defaultTo) : -1;

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
