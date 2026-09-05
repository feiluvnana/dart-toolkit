import 'dart:convert';
import 'dart:io';

import 'ansi.dart';

// ============================================================================
// CONSOLE READER (INTERACTIVE PROMPTS & USER INPUT)
// ============================================================================

/// Dedicated console input reader for interactive CLI prompts.
class ConsoleReader {
  /// Reads a single raw UTF-8 line from standard input.
  Future<String?> line() async {
    return stdin.readLineSync(encoding: utf8);
  }

  /// Prompts the user for text input with an optional default value and validator.
  ///
  /// ```dart
  /// final name = await console.reader.ask('Enter project name', defaultVal: 'my_app');
  /// final age = await console.reader.ask(
  ///   'Enter age',
  ///   validator: (s) => int.tryParse(s) != null,
  /// );
  /// ```
  Future<String> ask(
    String question, {
    String? defaultVal,
    bool Function(String)? validator,
  }) async {
    while (true) {
      final hint = defaultVal != null ? ' (${defaultVal.dim()})' : '';
      stdout.write('$question$hint: ');
      final l = (await line())?.trim();
      final answer = (l == null || l.isEmpty) ? (defaultVal ?? '') : l;
      if (validator == null || validator(answer)) return answer;
      stderr.writeln('${'✖'.brightRed()} Invalid input, please try again.');
    }
  }

  /// Prompts user with a Yes/No boolean confirmation question.
  ///
  /// ```dart
  /// final proceed = await console.reader.confirm('Deploy to production?', defaultVal: false);
  /// if (proceed) { ... }
  /// ```
  Future<bool> confirm(String question, {bool defaultVal = true}) async {
    final hint = defaultVal ? '[Y/n]' : '[y/N]';
    stdout.write('$question ${hint.dim()} ');
    final l = (await line())?.trim().toLowerCase();
    if (l == null || l.isEmpty) return defaultVal;
    return l == 'y' || l == 'yes' || l == '1' || l == 'true';
  }

  /// Presents an interactive numbered selection list for the user to choose an option.
  ///
  /// ```dart
  /// final region = await console.reader.pick(
  ///   'Select deployment region:',
  ///   options: ['us-east-1', 'eu-west-1', 'ap-south-1'],
  /// );
  /// ```
  Future<O> pick<O>(
    String question, {
    required List<O> options,
    String Function(O item)? label,
  }) async {
    if (options.isEmpty) throw ArgumentError('Options cannot be empty');
    stdout.writeln(question.bold());
    for (var i = 0; i < options.length; i++) {
      final text = label != null ? label(options[i]) : options[i].toString();
      stdout.writeln('  ${'${i + 1})'.cyan()} $text');
    }
    while (true) {
      stdout.write('Select (1-${options.length}): ');
      final l = (await line())?.trim();
      final n = int.tryParse(l ?? '');
      if (n != null && n >= 1 && n <= options.length) {
        return options[n - 1];
      }
      stderr.writeln('${'✖'.brightRed()} Please enter 1-${options.length}.');
    }
  }

  /// Presents an interactive numbered selection list allowing multiple choices.
  ///
  /// Users can enter numbers separated by spaces or commas (e.g. `1, 3` or `all`).
  ///
  /// ```dart
  /// final selected = await console.reader.picks(
  ///   'Select components to install:',
  ///   options: ['CLI', 'Server', 'Docs', 'Examples'],
  /// );
  /// ```
  Future<List<O>> picks<O>(
    String question, {
    required List<O> options,
    String Function(O item)? label,
  }) async {
    if (options.isEmpty) throw ArgumentError('Options cannot be empty');
    stdout.writeln(question.bold());
    for (var i = 0; i < options.length; i++) {
      final text = label != null ? label(options[i]) : options[i].toString();
      stdout.writeln('  ${'${i + 1})'.cyan()} $text');
    }
    while (true) {
      stdout.write('Select (e.g. 1, 3 or all): ');
      final l = (await line())?.trim().toLowerCase();
      if (l == null || l.isEmpty) return [];
      if (l == 'all' || l == '*') return List.of(options);
      final tokens = l.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty);
      final indices = <int>{};
      var valid = true;
      for (final t in tokens) {
        final n = int.tryParse(t);
        if (n != null && n >= 1 && n <= options.length) {
          indices.add(n - 1);
        } else {
          valid = false;
          break;
        }
      }
      if (valid && indices.isNotEmpty) {
        return indices.map((i) => options[i]).toList();
      }
      stderr.writeln(
        '${'✖'.brightRed()} Please enter valid numbers between 1 and ${options.length}.',
      );
    }
  }

  /// Reads sensitive input (e.g. passwords, API tokens) while masking terminal echo.
  ///
  /// ```dart
  /// final token = await console.reader.secret('Enter GitHub Token');
  /// ```
  Future<String> secret(String prompt) async {
    stdout.write('$prompt: ');
    try {
      stdin.echoMode = false;
      final answer = (await line()) ?? '';
      stdout.writeln();
      return answer;
    } finally {
      try {
        stdin.echoMode = true;
      } catch (_) {}
    }
  }
}
