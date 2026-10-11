import 'dart:math' as math;

/// Declarative terminal UI: build a frame with [box], [text], [bar] and [list], then print it.
///
/// ```dart
/// final ui = Ui();
/// ui.box(title: 'Overview');
/// ui.text('System operational');
/// ui.bar(val: 75, max: 100, label: 'RAM');
/// ui.list(['Option 1', 'Option 2'], sel: 0);
/// print(ui);
/// ```
final class Ui {
  final List<String> _lines = [];

  /// A titled box frame, opened by [end] or automatically at the next block.
  Ui box({String? title, int? width}) {
    final w = width ?? 40;
    final inner = w - 2;
    if (title == null) {
      _lines.add('┌${'─' * inner}┐');
    } else {
      final label = ' $title ';
      final pad = math.max(0, inner - label.length);
      _lines.add('┌─$label${'─' * pad}┐');
    }
    return this;
  }

  /// Closes the most recent [box].
  Ui end({int? width}) {
    final w = width ?? 40;
    _lines.add('└${'─' * (w - 2)}┘');
    return this;
  }

  /// A line of [content].
  Ui text(Object content, {int? width}) {
    _lines.add(content.toString());
    return this;
  }

  /// A horizontal progress bar from `0` to [max], optionally [label]led.
  Ui bar({required num val, required num max, String? label, int width = 30, String? unit}) {
    final ratio = max <= 0 ? 1.0 : (val / max).clamp(0.0, 1.0);
    final filled = (ratio * width).round();
    final glyphs = '${'█' * filled}${'░' * (width - filled)}';
    final pct = '${(ratio * 100).toStringAsFixed(0)}%';
    final prefix = label == null ? '' : '$label ';
    final suffix = unit == null ? '' : ' $val/$max $unit';
    _lines.add('$prefix[$glyphs] $pct$suffix');
    return this;
  }

  /// A bullet list with the entry at [sel] highlighted.
  Ui list(List<String> items, {int sel = 0}) {
    for (var i = 0; i < items.length; i++) {
      final marker = i == sel ? '▸' : ' ';
      _lines.add('$marker ${items[i]}');
    }
    return this;
  }

  /// A blank line.
  Ui gap() {
    _lines.add('');
    return this;
  }

  /// The built frame as a string.
  String render() => _lines.join('\n');

  @override
  String toString() => render();
}
