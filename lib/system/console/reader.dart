/// # Console Reader (`system.console.reader.*`)
///
/// Interactive prompts. Input is read from a single non-blocking stdin
/// subscription, so a [Spinner] or [Progress] bar keeps animating while a
/// prompt waits for an answer.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'ansi.dart';

// ============================================================================
// CONSOLE READER (system.console.reader.*)
// ============================================================================

/// Interactive prompts, reachable as `system.console.reader`.
///
/// ```dart
/// final name = await system.console.reader.ask('Project name');
/// final go = await system.console.reader.confirm('Continue?');
/// final env = await system.console.reader.pick('Target', options: ['dev', 'prod']);
/// ```
class ConsoleReader {
  StreamSubscription<String>? _subscription;
  final Queue<String> _buffered = Queue<String>();
  final Queue<Completer<String?>> _waiting = Queue<Completer<String?>>();
  bool _closed = false;

  /// Reads one line from stdin, or `null` at end of input.
  ///
  /// Does not block the event loop: timers and spinners continue to run while
  /// this future is pending.
  Future<String?> line() {
    if (_buffered.isNotEmpty) return Future.value(_buffered.removeFirst());
    if (_closed) return Future.value(null);
    _listen();
    final completer = Completer<String?>();
    _waiting.add(completer);
    return completer.future;
  }

  void _listen() {
    if (_subscription != null) return;
    _subscription = stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (_waiting.isNotEmpty) {
              _waiting.removeFirst().complete(line);
            } else {
              _buffered.add(line);
            }
          },
          onDone: () {
            _closed = true;
            while (_waiting.isNotEmpty) {
              _waiting.removeFirst().complete(null);
            }
          },
        );
  }

  /// Releases the stdin subscription so the process can exit.
  ///
  /// Only needed if you have prompted and then want to keep running without
  /// further input; the subscription otherwise ends with the program. Any
  /// prompt still waiting is completed with `null` — cancelling the
  /// subscription silently would leave it pending forever.
  Future<void> close() async {
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete(null);
    }
  }

  /// Asks [question] and returns the answer, re-prompting until [validator]
  /// accepts it.
  ///
  /// An empty answer falls back to [fallback] when given. Throws [StateError]
  /// if input ends while [validator] is still rejecting what it is handed.
  Future<String> ask(
    String question, {
    String? fallback,
    bool Function(String answer)? validator,
  }) async {
    while (true) {
      final hint = fallback != null ? ' (${fallback.dim()})' : '';
      stdout.write('$question$hint: ');
      final read = await line();
      final raw = read?.trim();
      final answer = (raw == null || raw.isEmpty) ? (fallback ?? '') : raw;
      if (validator == null || validator(answer)) return answer;
      // Nothing more is coming, so re-prompting would spin forever.
      if (read == null) throw _exhausted('ask');
      stderr.writeln('${'✖'.brightred()} Invalid input, please try again.');
    }
  }

  /// Asks [question] as a yes/no prompt, defaulting to [fallback] on Enter.
  Future<bool> confirm(String question, {bool fallback = true}) async {
    stdout.write('$question ${(fallback ? '[Y/n]' : '[y/N]').dim()} ');
    final answer = (await line())?.trim().toLowerCase();
    if (answer == null || answer.isEmpty) return fallback;
    return answer == 'y' || answer == 'yes' || answer == '1';
  }

  /// Asks [question] and returns the single chosen entry of [options].
  ///
  /// [label] renders each option; without it `toString` is used. Throws
  /// [ArgumentError] when [options] is empty, and [StateError] when stdin
  /// reaches end of input before a valid choice arrives — an unattended run
  /// would otherwise re-prompt forever.
  Future<O> pick<O>(
    String question, {
    required List<O> options,
    String Function(O item)? label,
  }) async {
    _menu(question, options, label);
    while (true) {
      stdout.write('Select (1-${options.length}): ');
      final read = await line();
      if (read == null) throw _exhausted('pick');
      final choice = int.tryParse(read.trim());
      if (choice != null && choice >= 1 && choice <= options.length) {
        return options[choice - 1];
      }
      stderr.writeln('${'✖'.brightred()} Please enter 1-${options.length}.');
    }
  }

  /// Asks [question] and returns every chosen entry of [options].
  ///
  /// Accepts a comma- or space-separated list, `all` for everything, or an
  /// empty answer for nothing. Throws [StateError] at end of input.
  Future<List<O>> picks<O>(
    String question, {
    required List<O> options,
    String Function(O item)? label,
  }) async {
    _menu(question, options, label);
    while (true) {
      stdout.write('Select (e.g. 1, 3 or all): ');
      final read = await line();
      if (read == null) throw _exhausted('picks');
      final answer = read.trim().toLowerCase();
      if (answer.isEmpty) return [];
      if (answer == 'all' || answer == '*') return List.of(options);

      final indices = <int>{};
      var valid = true;
      for (final token in answer.split(RegExp(r'[\s,]+'))) {
        if (token.isEmpty) continue;
        final n = int.tryParse(token);
        if (n == null || n < 1 || n > options.length) {
          valid = false;
          break;
        }
        indices.add(n - 1);
      }
      if (valid && indices.isNotEmpty) {
        return indices.map((i) => options[i]).toList();
      }
      stderr.writeln(
        '${'✖'.brightred()} Please enter numbers between 1 and '
        '${options.length}.',
      );
    }
  }

  /// Asks [question] without echoing what is typed.
  ///
  /// Echo is restored even if reading fails.
  Future<String> secret(String question) async {
    stdout.write('$question: ');
    // Both the read and the write throw when stdin is not a terminal — a
    // piped run should still be able to answer the prompt, just without echo
    // control to restore.
    bool? wasEchoing;
    try {
      wasEchoing = stdin.echoMode;
      stdin.echoMode = false;
    } catch (_) {}
    try {
      final answer = (await line()) ?? '';
      stdout.writeln();
      return answer;
    } finally {
      if (wasEchoing != null) {
        try {
          stdin.echoMode = wasEchoing;
        } catch (_) {}
      }
    }
  }

  /// The error raised when a prompt needs an answer and input has ended.
  StateError _exhausted(String prompt) => StateError(
    'system.console.reader.$prompt needs an answer, but stdin is at end of '
    'input. Guard interactive prompts with stdin.hasTerminal, or supply the '
    'value as an argument when the script runs unattended.',
  );

  void _menu<O>(
    String question,
    List<O> options,
    String Function(O item)? label,
  ) {
    if (options.isEmpty) throw ArgumentError.value(options, 'options', 'empty');
    stdout.writeln(question.bold());
    for (var i = 0; i < options.length; i++) {
      final text = label != null ? label(options[i]) : options[i].toString();
      stdout.writeln('  ${'${i + 1})'.cyan()} $text');
    }
  }
}
