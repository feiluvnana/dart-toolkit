part of '../cli/cli.dart';

/// Test seams for [Cli]: fake input lines. Never needed by a script.
abstract final class CliFake {
  /// Answers prompts from [lines], in order; an empty answer once drained.
  static void lines(List<String> lines) => Cli._useLines(Stream.fromIterable(lines));
}
