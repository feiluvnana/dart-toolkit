part of '../../process.dart';

final _newline = RegExp(r'\r?\n');

/// What a command printed and how it exited.
///
/// {@category System}
class ShellResult {
  /// The command, as written.
  final String command;

  final int exitCode;

  final String stdout;

  final String stderr;

  /// Whether it exited 0.
  bool get isOk => exitCode == 0;

  /// [stdout], trimmed.
  String get text => stdout.trim();

  const ShellResult({required this.command, required this.exitCode, required this.stdout, required this.stderr});

  /// The non-empty lines of [stdout], right-trimmed.
  List<String> get lines =>
      stdout.split(_newline).map((line) => line.trimRight()).where((line) => line.isNotEmpty).toList();

  @override
  String toString() => text.isNotEmpty ? text : stderr.trim();
}

/// A non-zero exit under `strict`.
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
/// A [TimeoutException], so a caller that catches that still does; [result] is what it
/// printed until then, with exit code -1.
///
/// {@category System}
class ShellTimeoutException extends TimeoutException {
  final ShellResult result;

  ShellTimeoutException(this.result, [super.message, super.duration]);
}
