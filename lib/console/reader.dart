import 'dart:convert';
import 'dart:io';

import 'ansi.dart';

// ============================================================================
// CONSOLE READER (INTERACTIVE PROMPTS & USER INPUT)
// ============================================================================

/// Dedicated console input reader for interactive CLI prompts.
class ConsoleReader {
  /// Read a raw line from standard input.
  Future<String?> line() async {
    return stdin.readLineSync(encoding: utf8);
  }

  /// Prompt user for a text response with optional default and validator (1-word).
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

  /// Prompt user with a Yes/No boolean confirmation question (1-word).
  Future<bool> confirm(
    String question, {
    bool defaultVal = true,
  }) async {
    final hint = defaultVal ? '[Y/n]' : '[y/N]';
    stdout.write('$question ${hint.dim()} ');
    final l = (await line())?.trim().toLowerCase();
    if (l == null || l.isEmpty) return defaultVal;
    return l == 'y' || l == 'yes' || l == '1' || l == 'true';
  }

  /// Present a numbered selection list for the user to choose an option (1-word).
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

  /// Read sensitive input (like password or token) masking echo if possible (1-word).
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
