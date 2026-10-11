import 'dart:async';
import 'dart:io';

/// ANSI colour and weight for terminal text: `'Done!'.green`, `'Error!'.red.bold`.
extension AnsiText on String {
  String get _on => '\x1b[0m';

  /// Foreground colours.
  String get black => '\x1b[30m$this$_on';
  String get red => '\x1b[31m$this$_on';
  String get green => '\x1b[32m$this$_on';
  String get yellow => '\x1b[33m$this$_on';
  String get blue => '\x1b[34m$this$_on';
  String get magenta => '\x1b[35m$this$_on';
  String get cyan => '\x1b[36m$this$_on';
  String get white => '\x1b[37m$this$_on';
  String get grey => '\x1b[90m$this$_on';

  /// Weights and decorations.
  String get bold => '\x1b[1m$this$_on';
  String get dim => '\x1b[2m$this$_on';
  String get italic => '\x1b[3m$this$_on';
  String get underline => '\x1b[4m$this$_on';
}

/// Terminal output, prompts and progress, all one word.
///
/// ```dart
/// Cli.print('Done!'.green);
/// final name = Cli.ask('Your name?');
/// final ok   = Cli.confirm('Proceed?');
/// final bar  = Cli.bar(total: 100);
/// ```
abstract final class Cli {
  /// Writes [msg] and a newline.
  static void print(Object msg) => stdout.writeln(msg);

  /// Writes [msg] without a newline.
  static void out(Object msg) => stdout.write(msg);

  /// Asks a question and answers the line the user types.
  static String ask(String msg) {
    stderr.write('$msg ');
    return stdin.readLineSync() ?? '';
  }

  /// Asks a yes/no question. Answers `true` for `y`/`yes`.
  static bool confirm(String msg, {bool or = false}) {
    stderr.write('$msg [y/n] ');
    final line = stdin.readLineSync()?.trim().toLowerCase();
    if (line == null || line.isEmpty) return or;
    return line == 'y' || line == 'yes';
  }

  /// Asks the user to pick one of [options], by number. Answers the index.
  static int choose(String msg, List<String> options, {int or = 0}) {
    stderr.writeln(msg);
    for (var i = 0; i < options.length; i++) {
      stderr.writeln('  ${i + 1}) ${options[i]}');
    }
    stderr.write('Choice [${or + 1}] ');
    final n = int.tryParse(stdin.readLineSync()?.trim() ?? '');
    if (n == null || n < 1 || n > options.length) return or;
    return n - 1;
  }

  /// A determinate progress [Bar] of [total] units.
  static Bar bar({required int total, String? label, String? unit}) => Bar(total: total, label: label, unit: unit);

  /// Shows [label] while [fn] runs, then clears it.
  static Future<T> spin<T>(String label, Future<T> Function() fn) async {
    final live = stderr.hasTerminal;
    if (live) stderr.write('\r$label ');
    try {
      return await fn();
    } finally {
      if (live) stderr.write('\r\x1b[K');
    }
  }
}

/// A live progress bar; [set] advances it, [done] finishes the line.
final class Bar {
  final int total;
  final String? label;
  final String? unit;
  final Stopwatch _clock = Stopwatch()..start();
  int _value = 0;
  int _drawn = -1;
  bool _live = false;

  Bar({required this.total, this.label, this.unit}) {
    _live = stderr.hasTerminal;
  }

  /// The value shown.
  int get value => _value;

  /// Sets the completed amount to [v] (clamped to `[0, total]`).
  void set(int v) {
    _value = v < 0 ? 0 : (v > total ? total : v);
    _draw();
  }

  /// Adds one unit.
  void tick() => set(_value + 1);

  void _draw() {
    if (!_live) return;
    if (_value == _drawn) return;
    _drawn = _value;
    const width = 24;
    final ratio = total <= 0 ? 1.0 : _value / total;
    final filled = (ratio * width).round();
    final bar = '${'█' * filled}${'░' * (width - filled)}';
    final prefix = label == null ? '' : '$label ';
    final suffix = unit == null ? '' : ' $_value/$total $unit';
    stderr.write('\r$prefix[$bar] ${(ratio * 100).toStringAsFixed(0)}%$suffix');
  }

  /// Finishes the bar, leaving a completion line.
  void done() {
    if (_live) stderr.write('\r\x1b[K');
    final secs = _clock.elapsedMilliseconds / 1000;
    final prefix = label == null ? '' : '$label ';
    if (_live || label != null) stderr.writeln('$prefix done ($_value/$total) in ${secs.toStringAsFixed(1)}s');
  }
}
