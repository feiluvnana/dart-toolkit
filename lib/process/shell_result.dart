import 'dart:convert';

/// The result of executing a system command.
class ShellResult {
  /// The command string that was executed.
  final String command;

  /// The process exit code (0 indicates success).
  final int exitcode;

  /// Standard output captured as a string.
  final String stdout;

  /// Standard error captured as a string.
  final String stderr;

  /// Whether the process exited successfully with code 0.
  bool get ok => exitcode == 0;

  /// Whether the process failed with a non-zero exit code.
  bool get failed => !ok;

  /// Shorthand alias for [failed].
  bool get isFailed => failed;

  /// Concise trimmed stdout text.
  String get text => stdout.trim();

  const ShellResult({required this.command, required this.exitcode, required this.stdout, required this.stderr});

  /// Non-empty, trimmed lines extracted from [stdout].
  List<String> get lines =>
      stdout.split(RegExp(r'\r?\n')).map((line) => line.trim()).where((line) => line.isNotEmpty).toList();

  /// Parses [stdout] as a JSON document or structure (`Map` / `List`).
  dynamic get json => jsonDecode(text);

  @override
  String toString() => text.isNotEmpty ? text : stderr.trim();
}

/// Exception thrown when a command fails and `throwOnError` is enabled.
class ShellException implements Exception {
  final ShellResult result;

  const ShellException(this.result);

  @override
  String toString() =>
      'ShellException: Command "${result.command}" exited with code ${result.exitcode}.\nStderr:\n${result.stderr.trim()}';
}
