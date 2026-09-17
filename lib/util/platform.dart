import 'dart:io';

/// Operating-system detection.
///
/// Separate from [Env], which owns environment *variables*.
///
/// {@category System}
abstract final class Os {
  /// Whether the current operating system is macOS.
  static bool get isMacOS => Platform.isMacOS;

  /// Whether the current operating system is Windows.
  static bool get isWindows => Platform.isWindows;

  /// Whether the current operating system is Linux.
  static bool get isLinux => Platform.isLinux;
}
