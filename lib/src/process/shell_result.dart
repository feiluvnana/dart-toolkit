import 'dart:convert';

final _newline = RegExp(r'\r?\n');

/// The result of executing a system command.
///
/// {@category System}
class ShellResult {
  /// The command string that was executed.
  final String command;

  /// The process exit code (0 indicates success).
  final int exitCode;

  /// Standard output captured as a string.
  final String stdout;

  /// Standard error captured as a string.
  final String stderr;

  /// Whether the process exited successfully with code 0.
  bool get ok => exitCode == 0;

  /// Concise trimmed stdout text.
  String get text => stdout.trim();

  const ShellResult({required this.command, required this.exitCode, required this.stdout, required this.stderr});

  /// Non-empty, trimmed lines extracted from [stdout].
  List<String> get lines => stdout.split(_newline).map((line) => line.trim()).where((line) => line.isNotEmpty).toList();

  /// Parses [stdout] as a JSON document or structure (`Map` / `List`).
  dynamic get json => jsonDecode(text);

  @override
  String toString() => text.isNotEmpty ? text : stderr.trim();
}

/// Exception thrown when a command fails and `throwOnError` is enabled.
///
/// {@category System}
class ShellException implements Exception {
  final ShellResult result;

  const ShellException(this.result);

  @override
  String toString() =>
      'ShellException: Command "${result.command}" exited with code ${result.exitCode}.\nStderr:\n${result.stderr.trim()}';
}
