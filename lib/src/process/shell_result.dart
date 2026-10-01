part of '../../process.dart';

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
  bool get isOk => exitCode == 0;

  /// Concise trimmed stdout text.
  String get text => stdout.trim();

  const ShellResult({required this.command, required this.exitCode, required this.stdout, required this.stderr});

  /// Non-empty lines extracted from [stdout], with trailing whitespace trimmed.
  List<String> get lines =>
      stdout.split(_newline).map((line) => line.trimRight()).where((line) => line.isNotEmpty).toList();

  @override
  String toString() => text.isNotEmpty ? text : stderr.trim();
}

/// Exception thrown when a command fails and `strict` is on.
///
/// {@category System}
class ShellException implements Exception {
  final ShellResult result;

  const ShellException(this.result);

  @override
  String toString() {
    final last = result.stderr.trim().split(_newline).lastOrNull?.trim();
    final tail = (last != null && last.isNotEmpty) ? ': $last' : '';
    return '"${result.command}" exited with code ${result.exitCode}$tail';
  }
}

/// Thrown when a command outlives its `timeout`, after it and its children are stopped.
///
/// A [TimeoutException], so a caller that catches that still does; [result] is what the
/// command printed until then, with an exit code of -1.
///
/// {@category System}
class ShellTimeoutException extends TimeoutException {
  final ShellResult result;

  ShellTimeoutException(this.result, [super.message, super.duration]);
}
