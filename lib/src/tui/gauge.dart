part of '../../tui.dart';

/// A moment of a task's progress, as a [Gauge] `bar:` builder sees it: counts, bytes, timing,
/// and [bar] to draw it.
///
/// ```dart
/// Gauge.of(Progress(name: 'sdk.zip', bytes: got, bytesTotal: size, elapsed: clock.elapsed),
///     bar: (p, w) => Label('${p.name} ${p.bar(w - 20)} ${p.speed?.round() ?? 0} B/s'))
/// ```
///
/// {@category CLI}
final class Progress {
  /// Which task of [count] this is.
  final int index, count;
  final String name;
  final TaskState state;

  /// Units done, of [total] (`null`: unknown).
  final int current;
  final int? total;

  /// Bytes done, of [bytesTotal], for a transfer.
  final int? bytes, bytesTotal;
  final Duration elapsed;

  /// The theme of the widget drawing it.
  final TuiTheme theme;

  const Progress({
    this.current = 0,
    this.total,
    this.bytes,
    this.bytesTotal,
    this.elapsed = Duration.zero,
    this.name = '',
    this.index = 0,
    this.count = 1,
    this.state = TaskState.running,
    this.theme = const TuiTheme(),
  });

  /// Done so far, 0–1, from [current]/[total] else [bytes]/[bytesTotal]; `null` when unknown.
  double? get fraction {
    final (done, of) = total != null ? (current, total!) : (bytes ?? 0, bytesTotal ?? 0);
    if (state == TaskState.done) return 1;
    return of > 0 ? (done / of).clamp(0.0, 1.0) : null;
  }

  int? get percent => fraction == null ? null : (fraction! * 100).floor();

  double get _seconds => elapsed.inMicroseconds / 1e6;

  /// Units per second.
  double get rate => _seconds > 0 ? current / _seconds : 0;

  /// Bytes per second, for a transfer.
  double? get speed => bytes == null || _seconds <= 0 ? null : bytes! / _seconds;

  /// Time left at the pace so far.
  Duration? get eta {
    final f = fraction;
    if (f == null || f <= 0 || _seconds <= 0) return null;
    return Duration(microseconds: (elapsed.inMicroseconds * (1 - f) / f).round());
  }

  /// A bar [width] columns wide: [fill] for the done part, [head] at its edge, [empty] after.
  /// Glyphs default to the theme's.
  String bar(int width, {String? fill, String? empty, String? head}) {
    if (width <= 0) return '';
    final (f, e, h) = (fill ?? theme.fill, empty ?? theme.empty, head ?? theme.head);
    final done = ((fraction ?? 0) * width).floor();
    final tip = h.isNotEmpty && done < width ? 1 : 0;
    return f * done + h * tip + e * (width - done - tip);
  }

  Progress _themed(TuiTheme t) => Progress(
    current: current,
    total: total,
    bytes: bytes,
    bytesTotal: bytesTotal,
    elapsed: elapsed,
    name: name,
    index: index,
    count: count,
    state: state,
    theme: t,
  );
}

/// A progress bar with its percentage.
///
/// ```dart
/// Gauge(done / total)
/// Gauge.of(progress, bar: (p, w) => Label('${p.bar(w - 6, fill: '=', head: '>', empty: ' ')} ${p.percent}%'))
/// ```
///
/// {@category CLI}
final class Gauge extends Widget {
  final Progress progress;

  /// Replaces how it is drawn, given the snapshot and the width to fill.
  final Widget Function(Progress progress, int width)? bar;
  final Style? style;

  Gauge(double fraction, {this.style, this.bar})
    : progress = Progress(current: (fraction.clamp(0, 1) * 10000).round(), total: 10000);

  const Gauge.of(this.progress, {this.bar, this.style});

  @override
  int get width => 20;

  @override
  void paint(Canvas canvas) {
    final p = progress._themed(canvas.theme);
    if (bar != null) return canvas.draw(bar!(p, canvas.width));
    final label = p.percent == null ? '' : ' ${'${p.percent}'.padLeft(3)}%';
    final x = canvas.text(0, 0, p.bar(canvas.width - label.length), canvas.theme.accent + style);
    canvas.text(x, 0, label, canvas.theme.text);
  }
}

/// What a [Spin] builder is given.
///
/// {@category CLI}
final class SpinContext {
  /// The glyph for this moment.
  final String frame;
  final String label;
  final Duration elapsed;
  final TuiTheme theme;

  const SpinContext._(this.frame, this.label, this.elapsed, this.theme);
}

/// A spinner and its [label]. It animates itself: an app showing one redraws every [interval].
///
/// ```dart
/// if (s.loading) Spin('Fetching…'),
/// ```
///
/// {@category CLI}
final class Spin extends Widget {
  final String label;
  final List<String>? frames;
  final Duration interval;
  final Style? style;
  final Widget Function(SpinContext spin)? builder;

  const Spin(this.label, {this.frames, this.interval = const Duration(milliseconds: 80), this.style, this.builder});

  @override
  int get width => 2 + Io.width(label);

  @override
  void paint(Canvas canvas) {
    canvas._animate(interval);
    final t = canvas.theme;
    final fs = frames ?? t.frames;
    final elapsed = canvas._frame.elapsed;
    final frame = fs[elapsed.inMicroseconds ~/ interval.inMicroseconds % fs.length];
    if (builder != null) return canvas.draw(builder!(SpinContext._(frame, label, elapsed, t)));
    canvas.text(canvas.text(0, 0, frame, t.accent + style) + 1, 0, label, t.text);
  }
}
