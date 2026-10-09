part of '../../tui.dart';

/// A bar with its percentage, of a [fraction] from 0.0 to 1.0: `█████░░░░░  50%`. Work that
/// reports its own progress draws as a [Board].
///
/// {@category CLI}
final class Gauge extends Widget {
  final double fraction;

  // `done / total` with nothing to do is NaN, which clamps to NaN and draws full.
  Gauge(double fraction) : fraction = fraction.isNaN ? 0 : fraction.clamp(0.0, 1.0);

  @override
  int get width => 20;

  @override
  void paint(Canvas canvas) {
    final p = canvas.palette;
    final label = ' ${'${(fraction * 100 + 1e-9).floor()}'.padLeft(3)}%';
    canvas.text(canvas.text(0, 0, p.bar.draw(fraction, canvas.width - label.length), p.accent), 0, label, p.text);
  }
}

/// A spinner and its [label], in the palette's frames: an app showing one redraws every
/// interval.
///
/// ```dart
/// if (s.loading) Spin('Fetching…'),
/// ```
///
/// {@category CLI}
final class Spin extends Widget {
  final String label;

  const Spin(this.label);

  @override
  int get width => 2 + Style.width(label);

  @override
  void paint(Canvas canvas) {
    final p = canvas.palette;
    canvas.animate(p.interval);
    canvas.text(canvas.text(0, 0, p.frameAt(canvas._frame.elapsed), p.accent) + 1, 0, label, p.text);
  }
}

/// Work drawn from its [Tally], as the console's `show()` draws it: one task as one line, a batch
/// or a `Bar` as a header with a row per running item (`+N more` past [rows]), and the last [log]
/// warnings and failures under them. The tally is the work's, so building a board in `view`
/// each frame never listens again; the app redraws as the tally changes.
///
/// ```dart
/// final work = Tally.batch(urls.parallelize(fetch));
/// await Tui.run(0, view: (_) => VStack([Board(work, title: 'Fetching'), if (work.isOver) Label('done')]), update: …);
/// ```
///
/// {@category CLI}
final class Board extends Widget {
  final Tally tally;

  /// Drawn in the header, or as a single task's name.
  final String title;

  /// The most rows of running items.
  final int rows;

  /// How many warning and failure lines to keep under the rows.
  final int log;

  /// Draw a row and the header in place of the theme's.
  final Widget Function(TaskView view)? task;
  final Widget Function(BatchView view)? batch;

  Board(this.tally, {this.title = '', this.rows = 8, this.log = 3, this.task, this.batch}) {
    if (rows < 1) throw ArgumentError.value(rows, 'rows', 'Invalid rows, expected at least 1');
    if (log < 0) throw ArgumentError.value(log, 'log', 'Invalid log, expected at least 0');
  }

  List<Status<Object?, Object?>> get _notes {
    final notes = tally.notes;
    return notes.length <= log ? notes : notes.sublist(notes.length - log);
  }

  @override
  int heightAt(int width) {
    if (tally.isTask) return 1 + _notes.length;
    final (:rows, :more) = tally.rows(this.rows);
    return 1 + rows.length + (more > 0 ? 1 : 0) + _notes.length;
  }

  @override
  void paint(Canvas canvas) {
    canvas._watch(tally);
    tally.sample();
    final t = canvas.theme, p = canvas.palette;
    if (!tally.isOver) canvas.animate(p.interval);
    var y = 0;
    void line(Widget w) {
      final h = w.heightAt(canvas.width);
      canvas.area(0, y, canvas.width, h).draw(w);
      y += h;
    }

    if (tally.isTask) {
      final item = tally.items.firstOrNull;
      final view = item == null
          ? TaskView(
              label: title,
              status: const Running(null),
              elapsed: tally.elapsed,
              columns: canvas.width,
              palette: p,
            )
          : TaskView.of(item, label: title, columns: canvas.width, palette: p);
      line((task ?? t.task)(view));
    } else {
      final (:rows, :more) = tally.rows(this.rows);
      line((batch ?? t.batch)(BatchView.of(tally, title: title, more: more, columns: canvas.width, palette: p)));
      for (final row in rows) {
        line((task ?? t.task)(TaskView.of(row, isRow: true, columns: canvas.width, palette: p)));
      }
      if (more > 0) line(Label('  +$more more', style: p.muted));
    }
    for (final note in _notes) {
      final level = note is Failed ? LogLevel.error : LogLevel.warn;
      line(t.log(LogView(level, '$note', palette: p)));
    }
  }
}

/// [head] (a label, kept), then a bar of [fraction] in what is left, then [tail].
Widget _fitted(String head, double? fraction, String tail, Style headStyle) => Paint((c) {
  final p = c.palette;
  final tailWidth = tail.isEmpty ? 0 : Style.width(tail) + 2;
  final keep = c.width * 2 ~/ 5 > c.width - tailWidth - (fraction == null ? 0 : 8)
      ? c.width * 2 ~/ 5
      : c.width - tailWidth - (fraction == null ? 0 : 8);
  var x = c.text(0, 0, Style.truncate(head, keep < 1 ? 1 : keep, ellipsis: p.ellipsis), headStyle);
  final room = c.width - x - tailWidth - 2;
  if (fraction != null && room >= 4) x = c.text(x + 2, 0, p.bar.draw(fraction, room < 20 ? room : 20), p.accent);
  if (tail.isNotEmpty) c.text(x + 2, 0, tail, p.muted);
});

String _joinedParts(Iterable<String> parts) => parts.where((p) => p.isNotEmpty).join('  ');

/// `name  ██████░░░░  60%  1.2/2.0 MB  3.1 MB/s`, or `✓ name` once it ended.
Widget _taskRow(TaskView t) {
  final p = t.palette;
  final status = t.status;
  final indent = t.isRow ? '  ' : '';
  if (status.isFinal) {
    final (mark, style) = switch (status) {
      Done() => (p.marks.ok, p.success),
      Failed() => (p.marks.error, p.danger),
      _ => (p.marks.warn, p.warning),
    };
    return Label.spans([Span('$indent$mark ', style), Span(t.label, p.muted)], wrap: false);
  }
  final eta = t.eta == null ? '' : 'eta ${t.eta!.humanized}';
  final tail = _joinedParts([t.percent == null ? '' : '${t.percent}%', t.amounts, t.pace, eta, t.step ?? '']);
  return _fitted(t.isRow ? '$indent${t.label}' : '${t.frame} ${t.label}', t.fraction, tail, p.text);
}

/// `⠋ Fetching  ████░░░░  3/8  1 failed`.
Widget _batchRow(BatchView b) {
  final p = b.palette;
  final eta = b.eta == null ? '' : 'eta ${b.eta!.humanized}';
  final counts = b.count == null ? '${b.ended} done' : '${b.ended}/${b.count}';
  final tail = _joinedParts([
    counts,
    if (b.total != null) b.amounts,
    b.pace,
    eta,
    if (b.failed > 0) '${b.failed} failed',
  ]);
  final head = b.isLive && b.ended < (b.count ?? b.ended + 1) ? '${b.frame} ${b.title}' : b.title;
  return _fitted(head, b.fraction, tail, b.failed > 0 ? p.danger : p.text);
}

/// `⚠ name: retry 1/2 in 1s: …` in the level's colour.
Widget _logRow(LogView l) => Label('${l.mark} ${l.message}', style: l.style, wrap: false);
