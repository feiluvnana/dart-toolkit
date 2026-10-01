part of '../../cli.dart';

// ---- the theme -------------------------------------------------------------------------

/// The tokens every console part draws with: a palette, marks, glyphs and an indent.
///
/// A theme names only what it changes; [Console.theme] sets it for the process,
/// [Console.themed] for one piece of work. What a line *says* is the component's own
/// builder — `line:`, `task:`, `header:`, `cell:` — and a builder reads the theme from
/// its view, so it follows the theme unless it chooses not to.
///
/// ```dart
/// Console.theme = ConsoleTheme(ok: '✔', fill: '█', empty: '░', accent: (s) => s.magenta);
/// ```
///
/// The default is [ascii] where Unicode would not draw: the Linux console, a non-UTF-8
/// locale, the old Windows console.
///
/// {@category Terminal}
final class ConsoleTheme {
  /// Info lines, spinner frames, rule titles, stage banners: cyan.
  final String Function(String text) accent;

  /// Success lines: green.
  final String Function(String text) success;

  /// Warning lines: yellow.
  final String Function(String text) warning;

  /// Error lines and rejected answers: red.
  final String Function(String text) danger;

  /// Debug lines, live indicators, hints: dim.
  final String Function(String text) muted;

  /// Stage banners, over [accent]: bold.
  final String Function(String text) highlight;

  /// The marks of [Console.ok], [Console.info], [Console.warn], [Console.error] and
  /// [Console.debug]; a spinner's and a bar's ending use [ok], [warn] and [error].
  final String ok, info, warn, error, debug;

  /// What every line starts with.
  final String indent;

  /// A spinner's frames, one cell each, [interval] apart.
  final List<String> frames;

  final Duration interval;

  /// A bar's filled and empty glyphs, and the tip a board row's bar ends in.
  final String fill, empty, head;

  /// `Table.show`'s border; [Console.rule] repeats its [Border.top].
  final Border border;

  /// A board row's prefix, and its last row's.
  final (String, String) tree;

  /// What a prompt writes before and after its question: `Name (bob): `.
  final String prompt, promptEnd;

  const ConsoleTheme({
    this.accent = _cyan,
    this.success = _green,
    this.warning = _yellow,
    this.danger = _red,
    this.muted = _dim,
    this.highlight = _bold,
    this.ok = '✓',
    this.info = 'ℹ',
    this.warn = '⚠',
    this.error = '✖',
    this.debug = '·',
    this.indent = '  ',
    this.frames = const ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
    this.interval = const Duration(milliseconds: 80),
    this.fill = '=',
    this.empty = '-',
    this.head = '>',
    this.border = Border.square,
    this.tree = ('├─', '└─'),
    this.prompt = '',
    this.promptEnd = ': ',
  });

  /// Only ASCII, for a terminal that cannot draw Unicode.
  static const ascii = ConsoleTheme(
    ok: '+',
    info: 'i',
    warn: '!',
    error: 'x',
    debug: '.',
    frames: [r'-', r'\', r'|', r'/'],
    border: Border.ascii,
    tree: ('|-', '`-'),
  );

  static String _cyan(String s) => s.cyan;
  static String _green(String s) => s.green;
  static String _yellow(String s) => s.yellow;
  static String _red(String s) => s.red;
  static String _dim(String s) => s.dim;
  static String _bold(String s) => s.bold;

  String _line(String Function(String) colour, String mark, String message) => colour('$indent$mark $message');

  /// Whether this terminal draws Unicode: not the Linux console, a non-UTF-8 locale, or the
  /// Windows console outside Windows Terminal.
  static final bool _unicode = () {
    String? env(String name) => switch (Platform.environment[name]) {
      final v? when v.isNotEmpty => v,
      _ => null,
    };
    final locale = env('LC_ALL') ?? env('LC_CTYPE') ?? env('LANG') ?? 'UTF-8';
    return Platform.isWindows
        ? env('WT_SESSION') != null || env('TERM_PROGRAM') != null
        : env('TERM') != 'linux' && locale.toLowerCase().replaceAll('-', '').contains('utf8');
  }();
}

// ---- views -----------------------------------------------------------------------------

/// What a builder is handed: the theme, a fraction done, and a bar in the theme's glyphs.
///
/// {@category Terminal}
sealed class ConsoleView {
  /// The theme the component was created under.
  final ConsoleTheme theme;

  /// Columns the line may use.
  final int columns;

  /// How long the component has been running.
  final Duration elapsed;

  /// Whether this is a live line, redrawn in place, rather than one a log keeps: what a
  /// component writes without a terminal.
  final bool isLive;

  const ConsoleView._(this.theme, this.columns, this.elapsed, this.isLive);

  /// From 0.0 to 1.0, or `null` when the size is unknown.
  double? get fraction;

  /// [fraction] in whole percent, 0 when unknown.
  int get percent => ((fraction ?? 0) * 100).toInt();

  /// [width] glyphs, [fraction] of them filled; [head] tips the filled part.
  String bar(int width, {String? fill, String? empty, String? head}) {
    final (f, e) = (fill ?? theme.fill, empty ?? theme.empty);
    final filled = ((fraction ?? 0) * width).clamp(0, width).toInt();
    final done = head != null && filled > 0 ? f * (filled - 1) + head : f * filled;
    return done + e * (width - filled);
  }

  static Duration? _remaining(num left, double perSecond) =>
      perSecond > 0 ? Duration(microseconds: (max(0, left) / perSecond * 1e6).round()) : null;
}

/// A [ProgressBar]'s state, for its `line:` builder.
///
/// {@category Terminal}
final class ProgressView extends ConsoleView {
  /// The bar's `message:`, and the latest tick's label.
  final String message;
  final String? label;

  final int current, total;

  /// Steps per second, smoothed over the last second or two.
  final double rate;

  const ProgressView._(
    super.theme,
    super.columns,
    super.elapsed,
    super.isLive,
    this.message,
    this.label,
    this.current,
    this.total,
    this.rate,
  ) : super._();

  @override
  double? get fraction => total > 0 ? (current / total).clamp(0.0, 1.0) : null;

  /// Time left at [rate], or `null` before it is known.
  Duration? get eta => ConsoleView._remaining(total - current, rate);
}

/// A [Spinner]'s state, for its `line:` builder.
///
/// {@category Terminal}
final class SpinnerView extends ConsoleView {
  final String text;

  /// Frames drawn so far; [frame] is the theme's glyph for it.
  final int tick;

  const SpinnerView._(super.theme, super.columns, super.elapsed, super.isLive, this.text, this.tick) : super._();

  String get frame => theme.frames[tick % theme.frames.length];

  @override
  double? get fraction => null;
}

/// Where a task in a [TaskBoard] stands.
///
/// {@category Terminal}
enum TaskState { queued, running, done, failed, skipped }

/// One task of a [TaskBoard], for its `task:` builder.
///
/// [task] is the event itself: a download's is a `DownloadProgress`, with its `url` and
/// `path`.
///
/// {@category Terminal}
final class TaskView extends ConsoleView {
  final TaskProgress task;

  /// The batch as it stands, as the `header:` builder sees it.
  final BatchView batch;

  /// 1-based, in the order the board first heard of each task.
  final int index;

  /// Bytes per second, smoothed over the last second or two; 0 before it is known.
  final double speed;

  const TaskView._(
    super.theme,
    super.columns,
    super.elapsed,
    super.isLive,
    this.task,
    this.batch,
    this.index,
    this.speed,
  ) : super._();

  String get name => task.label;

  /// Tasks in the batch, or `null` while unknown.
  int? get count => batch.total;

  TaskState get state => switch (task.status) {
    'failed' => TaskState.failed,
    'skipped' => TaskState.skipped,
    'queued' => TaskState.queued,
    _ => task.isDone ? TaskState.done : TaskState.running,
  };

  int get bytes => task.received ?? 0;

  int? get bytesTotal => task.total;

  Object? get error => task.error;

  @override
  double? get fraction => task.ratio?.clamp(0.0, 1.0);

  /// Time left at [speed], or `null` before it is known.
  Duration? get eta => switch (bytesTotal) {
    final all? when !task.isDone => ConsoleView._remaining(all - bytes, speed),
    _ => null,
  };
}

/// A [TaskBoard]'s batch, for its `header:` builder.
///
/// {@category Terminal}
final class BatchView extends ConsoleView {
  final String message;

  final int completed, failed;

  /// Tasks in the batch, or `null` while unknown.
  final int? total;

  /// Bytes so far, and in all, when every task's size is known.
  final int bytes;
  final int? bytesTotal;

  /// Bytes and tasks per second, smoothed over the last second or two.
  final double speed, rate;

  const BatchView._(
    super.theme,
    super.columns,
    super.elapsed,
    super.isLive,
    this.message,
    this.completed,
    this.failed,
    this.total,
    this.bytes,
    this.bytesTotal,
    this.speed,
    this.rate,
  ) : super._();

  @override
  double? get fraction => switch (total) {
    final all? when all > 0 => (completed / all).clamp(0.0, 1.0),
    _ => null,
  };

  /// Time left at [speed] when the bytes are known, else at [rate].
  Duration? get eta => switch ((bytesTotal, total)) {
    (final all?, _) when speed > 0 => ConsoleView._remaining(all - bytes, speed),
    (_, final all?) => ConsoleView._remaining(all - completed, rate),
    _ => null,
  };
}

// ---- default builders ------------------------------------------------------------------

String _labelled(String message, String body) => message.isNotEmpty ? '$message: $body' : body;

/// `[bar] pct% (done/total)`; work done against no known total is `--% (n/?)`, not 0%.
String _meter(ConsoleView v, int done, int? total) => (total ?? 0) <= 0 && done > 0
    ? '[${v.bar(20)}] --% ($done/?)'
    : '[${v.bar(20)}] ${v.percent}% ($done/${total ?? 0})';

String _progressLine(ProgressView p) {
  final base = '${p.theme.indent}${_labelled(p.message, _meter(p, p.current, p.total))}';
  // " ($label)" takes three columns of its own.
  final (label, room) = (p.label, p.columns - Io.width(base));
  return label != null && label.isNotEmpty && room > 5 ? '$base (${Io.truncate(label, room - 3)})' : base;
}

String _headerLine(BatchView b) {
  final pace = [if (b.speed > 0) '${b.speed.humanBytes}/s', if (b.eta case final eta?) 'eta ${eta.humanized}'];
  final base = _labelled(b.message, _meter(b, b.completed, b.total));
  return '${b.theme.indent}$base${pace.isEmpty ? '' : ' ${pace.join(', ')}'}';
}

String _taskLine(TaskView t) {
  final status = t.task.status;
  if (!t.isLive) {
    final size = switch (t.bytesTotal) {
      final all? when all > 0 => ' (${all.humanBytes})',
      _ => '',
    };
    return '${t.theme.indent}[${t.batch.completed}/${(t.count ?? 0) > 0 ? t.count : '?'}] ${t.name}$size [${status ?? 'done'}]';
  }
  final percent = t.fraction == null ? ' --%' : '${t.percent}%'.padLeft(4);
  final size = switch ((t.task.received, t.bytesTotal)) {
    (final got?, final all?) when all > 0 => '(${got.humanBytes}/${all.humanBytes}) ',
    (final got?, _) when got > 0 => '(${got.humanBytes}) ',
    _ => '',
  };
  final speed = t.state == TaskState.running && t.speed > 0 ? '${t.speed.humanBytes}/s ' : '';
  final tail = status != null && status.isNotEmpty ? ' [$status]' : '';
  return '[${t.bar(10, head: t.theme.head)}] $percent $size$speed${t.name}$tail';
}

String _spinnerLine(SpinnerView s) {
  final (t, time) = (s.theme, s.elapsed.humanized);
  if (!s.isLive) return '${t.indent}${s.frame} ${s.text}...';
  // The text is cut, never the styled line (that can split an escape); on a narrow terminal
  // the time goes first.
  final room = s.columns - Io.width(s.frame) - Io.width(time) - 4;
  if (room >= 1) return '${t.accent(s.frame)} ${Io.truncate(s.text, room)} (${t.muted(time)})';
  return '${t.accent(s.frame)} ${Io.truncate(s.text, max(0, s.columns - Io.width(s.frame) - 1))}';
}

// ---- the live region -------------------------------------------------------------------

/// Coalesces redraws, so a producer that reports per chunk does not write per chunk;
/// always draws the latest state.
class _FrameGate {
  static const _interval = Duration(milliseconds: 33);
  DateTime? _last;
  Timer? _timer;
  void Function()? _pending;

  void request(void Function() render) {
    final now = DateTime.now();
    if (_last == null || now.difference(_last!) >= _interval) {
      _timer?.cancel();
      _timer = null;
      _pending = null;
      render();
      _last = now;
    } else {
      _pending = render;
      _timer ??= Timer(_interval, flush);
    }
  }

  /// Draws a deferred frame now, so `done()` never leaves the last state unrendered.
  void flush() {
    _timer?.cancel();
    _timer = null;
    final render = _pending;
    _pending = null;
    if (render != null) {
      render();
      _last = DateTime.now();
    }
  }
}

/// A count per second, smoothed exponentially with a time constant of 1.5 s.
final class _Rate {
  double perSecond = 0;
  int _count = 0;
  int _at = -1;

  /// Records [count] so far at [at] microseconds.
  void add(int count, int at) {
    if (at <= _at) return;
    if (_at >= 0) {
      final instant = (count - _count) * 1e6 / (at - _at);
      perSecond = perSecond == 0 ? instant : perSecond + (1 - exp((_at - at) / 1.5e6)) * (instant - perSecond);
    }
    _count = count;
    _at = at;
  }
}

int _columnsOr(int? fixed) => fixed != null && fixed > 0 ? fixed : Io.columns ?? 80;

bool _interactive() => Io.isErrTerminal;

/// `-q` asks for warnings and errors only, and an indicator is neither.
bool _shown() => Console._isEnabled(LogLevel.info);

final _control = RegExp(r'[\x00-\x1a\x1c-\x1f\x7f]');

/// A renderer that owns the bottom rows of the terminal and redraws them in place.
///
/// Only the innermost one is on screen; anything durable — a log line, a rule, a prompt —
/// [_wipe]s it, writes where it stood, and [_paint]s it again underneath.
abstract class _Live {
  /// Rows put on screen last frame.
  int _rows = 0;

  final _gate = _FrameGate();

  /// The theme where this was created, kept for its whole run.
  final ConsoleTheme _theme = Console.theme;

  final _watch = Stopwatch()..start();

  List<String> _lines();

  bool get _running;

  void _stop();

  void _render() {
    if (!_running || !identical(Console._top, this)) return;
    _gate.request(_paint);
  }

  /// Leaves the cursor on the row below the last line, so [_wipe] is the same for all.
  void _paint() {
    if (!_interactive() || !_running) return;
    final lines = _lines();
    final buffer = StringBuffer();
    if (_rows > 0) buffer.write('\x1b[${_rows}A');
    for (final line in lines) {
      buffer.write('\r\x1b[K${line.replaceAll(_control, ' ')}\n');
    }
    // Rows the last frame used and this one does not: a board whose slot count shrank.
    for (var i = lines.length; i < _rows; i++) {
      buffer.write('\r\x1b[K\n');
    }
    if (_rows > lines.length) buffer.write('\x1b[${_rows - lines.length}A');
    Io.err.write(buffer.toString());
    _rows = lines.length;
  }

  /// Clears the rows and leaves the cursor where the first one was.
  void _wipe() {
    _gate.flush();
    if (!_interactive() || _rows == 0) return;
    Io.err.write('\x1b[${_rows}A${'\r\x1b[K\n' * _rows}\x1b[${_rows}A');
    _rows = 0;
  }
}

// ---- spinners --------------------------------------------------------------------------

/// An indeterminate spinner whose message changes as the work moves on.
///
/// [Console.spin] is shorter when the work is one call. Without a terminal it writes one
/// line when it starts and one when it ends, so a CI log reads the same.
///
/// ```dart
/// final spinner = Console.spinner('Connecting');
/// spinner.text = 'Fetching the index';
/// Console.info('found 12 files');        // scrolls above; the spinner keeps spinning
/// spinner.succeed('12 files indexed');
/// ```
///
/// {@category Terminal}
final class Spinner extends _Live {
  final String Function(SpinnerView) _line;
  String _text;
  Timer? _timer;
  int _tick = 0;
  bool _stopped = false;

  Spinner._(this._text, String Function(SpinnerView)? line) : _line = line ?? _spinnerLine;

  /// The message beside the frame. Assigning redraws it without restarting the animation.
  String get text => _text;

  set text(String value) {
    if (_text == value) return;
    _text = value;
    _render();
  }

  @override
  bool get _running => !_stopped;

  @override
  List<String> _lines() => [_draw(live: true)];

  String _draw({required bool live}) {
    final width = _columnsOr(null) - 1;
    return Io.truncate(_line(SpinnerView._(_theme, width, _watch.elapsed, live, _text, _tick)), width);
  }

  void _start() {
    if (!_shown()) return;
    if (_interactive()) {
      Console._push(this);
      _timer = Timer.periodic(_theme.interval, (_) {
        if (_stopped) return;
        _tick++;
        _render();
      });
    } else {
      Io.err.writeln(_draw(live: false));
    }
  }

  /// Ends it with an `ok` line, on stdout.
  void succeed([String? message]) => _finish(_theme.success, _theme.ok, message, LogLevel.info);

  /// Ends it with an `error` line, on stderr.
  void fail([String? message]) => _finish(_theme.danger, _theme.error, message, LogLevel.error);

  /// Ends it with a `warn` line, on stderr.
  void warn([String? message]) => _finish(_theme.warning, _theme.warn, message, LogLevel.warn);

  /// Ends it with no final line.
  void stop() => _finish(null, '', null, LogLevel.info);

  @override
  void _stop() => stop();

  /// The final line is a log line at [severity]: `-q` keeps a failure and drops a success.
  void _finish(String Function(String)? colour, String mark, String? message, LogLevel severity) {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _watch.stop();
    Console._pop(this);
    if (colour == null) return;
    final time = _theme.muted(_watch.elapsed.humanized);
    Console._log(severity, _theme._line(colour, mark, '${message ?? _text} ($time)'));
  }
}

// ---- a bar and a board -----------------------------------------------------------------

/// What a [ProgressBar] and a [TaskBoard] share: a count toward a total, a label, a width,
/// and one way to end.
abstract class _Meter extends _Live {
  /// The label drawn before the bar.
  final String message;

  /// A fixed width, or `null` to follow the terminal.
  final int? columns;

  int _current = 0;
  bool _isDone = false;

  _Meter(this.message, this.columns);

  /// Steps counted so far.
  int get current => _current;

  /// Whether [done] has been called.
  bool get isDone => _isDone;

  @override
  bool get _running => !_isDone;

  /// One short of the terminal, so a line never wraps.
  int get _width => max(1, _columnsOr(columns) - 1);

  int get _now => _watch.elapsedMicroseconds;

  void _show() {
    if (!_shown()) return;
    if (_interactive() && _rows == 0) Console._push(this);
    _render();
  }

  /// Ends it, with an `ok` line when there is a [message].
  void done([String? message]) {
    if (_isDone) return;
    _gate.flush();
    _isDone = true;
    Console._pop(this);
    if (message != null && message.isNotEmpty) {
      Console._log(LogLevel.info, _theme._line(_theme.success, _theme.ok, message));
    }
  }

  @override
  void _stop() => done();
}

/// A single-line progress bar over [total] steps, created by [Console.progress].
///
/// Redraws are coalesced, so a caller may tick per chunk; without a terminal a line is
/// written when a new tenth is reached, not per tick.
///
/// {@category Terminal}
final class ProgressBar extends _Meter {
  /// Steps in the run.
  final int total;

  final String Function(ProgressView) _line;
  final _rate = _Rate();
  int _lastDecile = -1;
  String? _label;

  ProgressBar._(this.total, String message, int? columns, String Function(ProgressView)? line)
    : _line = line ?? _progressLine,
      super(message, columns);

  @override
  List<String> _lines() => [_theme.muted(_draw(_label, live: true))];

  /// The rate is sampled per frame drawn, not per tick: a tick stays a few nanoseconds.
  String _draw(String? label, {required bool live}) {
    _rate.add(_current, _now);
    final view = ProgressView._(_theme, _width, _watch.elapsed, live, message, label, _current, total, _rate.perSecond);
    return Io.truncate(_line(view), _width);
  }

  /// Advances the progress by [count] and optionally displays [label].
  void tick([int count = 1, String? label]) {
    if (_isDone) return;
    _current += count;
    if (label != null) _label = label;
    if (_interactive() || !_shown()) return _show();
    final decile = total > 0 ? (_current * 10 ~/ total).clamp(0, 10) : 0;
    if (decile == _lastDecile) return;
    _lastDecile = decile;
    Io.err.writeln(_draw(label, live: false));
  }
}

/// A task the board has heard of: its number, when it started, and its pace.
final class _Track {
  final int index;
  final int started;
  int? ended;
  int got = 0;
  bool sized = false;
  final rate = _Rate();

  _Track(this.index, this.started);
}

/// One row of a [TaskBoard]: the last update its task sent, and when.
final class _Slot {
  TaskProgress? task;
  _Track? track;
  int seen = 0;
}

/// A header bar and one row per concurrent task, created by [Console.tasks].
///
/// It renders whatever a [BatchProgress] carries, so a batch download or a crawl is shown
/// without either side knowing about the other.
///
/// {@category Terminal}
final class TaskBoard extends _Meter {
  /// Steps in the batch. A stream-sourced batch revises it upward as work is discovered.
  int total;

  /// How many task rows are drawn, or `null` to grow one per task running at once, up to
  /// [_most].
  final int? slots;

  final String Function(TaskView) _task;
  final String Function(BatchView) _header;
  final List<_Slot> _slots;
  final Map<String, _Slot> _slotByTask = {};
  final Map<String, _Track> _tracks = {};
  final _speed = _Rate();
  final _rate = _Rate();
  int _heard = 0;
  int _failed = 0;
  int _bytes = 0;
  int _sizes = 0;
  int _sized = 0;

  /// Past this many rows, the task updated longest ago gives up its row.
  static const _most = 8;

  TaskBoard._(
    this.total,
    this.slots,
    String message,
    int? columns,
    String Function(TaskView)? task,
    String Function(BatchView)? header,
  ) : _task = task ?? _taskLine,
      _header = header ?? _headerLine,
      _slots = List.generate(max(1, slots ?? 1), (_) => _Slot()),
      super(message, columns);

  BatchView get _batch => BatchView._(
    _theme,
    _width,
    _watch.elapsed,
    true,
    message,
    _current,
    _failed,
    total > 0 ? total : null,
    _bytes,
    total > 0 && _sized >= total ? _sizes : null,
    _speed.perSecond,
    _rate.perSecond,
  );

  TaskView _view(TaskProgress task, _Track track, BatchView batch, {bool live = true}) => TaskView._(
    _theme,
    _width,
    Duration(microseconds: (track.ended ?? _now) - track.started),
    live,
    task,
    batch,
    track.index,
    track.rate.perSecond,
  );

  @override
  List<String> _lines() {
    final batch = _batch;
    final (branch, last) = _theme.tree;
    return [
      Io.truncate(_header(batch), _width),
      for (final (i, slot) in _slots.indexed)
        Io.truncate(
          '${_theme.indent}${i == _slots.length - 1 ? last : branch} '
          '${slot.task == null ? '(idle)' : _task(_view(slot.task!, slot.track!, batch))}',
          _width,
        ),
    ].map(_theme.muted).toList();
  }

  /// [taskId]'s slot: its own, a free one, a new one while the board may grow, or the one
  /// updated longest ago.
  _Slot _slotFor(String taskId) => _slotByTask[taskId] ??= () {
    final free = _slots.where((s) => s.task == null || s.task!.isDone).firstOrNull;
    if (free == null && slots == null && _slots.length < _most) return (_slots..add(_Slot())).last;
    final slot = free ?? _slots.reduce((a, b) => b.seen < a.seen ? b : a);
    _slotByTask.remove(slot.task?.taskId);
    return slot;
  }();

  /// Renders one update: the overall count, a revised [total], and the task's row.
  void report(BatchProgress batch) {
    if (_isDone) return;
    if (batch.total case final discovered? when discovered > total) total = discovered;
    _current = batch.completed;
    _failed = batch.failed;
    final now = _now;
    final task = batch.current;
    final track = _tracks[task.taskId] ??= _Track(++_heard, now);
    if (task.received case final got? when got > track.got) {
      _bytes += got - track.got;
      track.got = got;
    }
    track.rate.add(track.got, now);
    if (!track.sized && (task.total != null || task.isDone)) {
      track.sized = true;
      _sizes += task.total ?? track.got;
      _sized++;
    }
    _speed.add(_bytes, now);
    _rate.add(_current, now);
    _slotFor(task.taskId)
      ..task = task
      ..track = track
      ..seen = now;
    if (task.isDone) {
      track.ended = now;
      _slotByTask.remove(task.taskId);
      _tracks.remove(task.taskId);
      // Without a terminal there is no cursor to move: one durable line per finished task.
      if (!_interactive() && _shown()) {
        Io.err.writeln(_task(_view(task, track, _batch, live: false)));
      }
    }
    _show();
  }
}

// ---- logging ---------------------------------------------------------------------------

/// Severity levels for [Console]'s log verbs, ordered from most to least verbose.
///
/// {@category CLI}
enum LogLevel {
  /// Everything, including [Console.debug].
  debug,

  /// Informational messages and above (the default).
  info,

  /// Warnings and errors only.
  warn,

  /// Errors only.
  error,

  /// Suppresses all output.
  silent,
}

/// A self-numbering sequence of stage banners. Created by [Console.stages].
///
/// {@category CLI}
class Stages {
  /// How many stages the run has.
  final int total;
  int _current = 0;

  Stages._(this.total);

  /// Prints the next stage banner: `[n/total] message`.
  void call(String message) {
    final t = Console.theme;
    Console._log(LogLevel.info, t.highlight(t.accent('[${++_current}/$total] $message')));
  }
}

// ---- the namespace ---------------------------------------------------------------------

/// The terminal: logging, rules, spinners, progress, boards and prompts.
///
/// One live region underneath, so the parts compose: a log line or a prompt during a
/// spinner scrolls above it rather than landing on top of it. Their tokens are the
/// [theme]; what each line says is its builder.
///
/// At end of input — piped stdin, CI — a prompt falls back to its default, or throws
/// [StateError] when it has none.
///
/// {@category Terminal}
class Console {
  // ---- the live region ----

  /// The renderers on screen, innermost last; only that one is drawn.
  static final List<_Live> _stack = [];

  static _Live? get _top => _stack.lastOrNull;

  static void _push(_Live live) {
    if (_stack.contains(live)) return;
    _top?._wipe();
    _stack.add(live);
    IoBridge.above = _durable;
    IoBridge.suspend = _suspend;
    live._paint();
  }

  static void _pop(_Live live) {
    final index = _stack.indexOf(live);
    if (index == -1) return;
    final wasTop = index == _stack.length - 1;
    if (wasTop) live._wipe();
    _stack.removeAt(index);
    if (_stack.isEmpty) {
      IoBridge.above = null;
      IoBridge.suspend = null;
    }
    if (wasTop) _top?._paint();
  }

  /// Runs [action] with the live region cleared, and draws it again afterwards.
  static Future<T> _suspend<T>(Future<T> Function() action) async {
    final live = _top?.._wipe();
    try {
      return await action();
    } finally {
      live?._paint();
    }
  }

  static void _stopAll() {
    while (_stack.isNotEmpty) {
      _stack.removeLast()
        .._wipe()
        .._stop();
    }
    IoBridge.above = null;
    IoBridge.suspend = null;
  }

  /// Writes something that stays on screen, above whatever is live: every verb here does.
  static void _durable(void Function() write) {
    final live = _top?.._wipe();
    write();
    live?._paint();
  }

  /// Writes [message] to [Io.out] durably, above any spinner or bar; unlevelled.
  static void writeln([String message = '']) => _durable(() => Io.out.writeln(message));

  // ---- scopes ----

  static const _levelKey = #dartToolkitLogLevel;
  static const _themeKey = #dartToolkitConsoleTheme;
  static LogLevel _processLevel = LogLevel.info;
  static ConsoleTheme _processTheme = _bridged(ConsoleTheme._unicode ? const ConsoleTheme() : ConsoleTheme.ascii);

  /// The minimum severity that is emitted: [silenced]'s for the work in progress, else the
  /// process-wide one assigning this sets. Defaults to [LogLevel.info].
  static LogLevel get level => Zone.current[_levelKey] as LogLevel? ?? _processLevel;

  static set level(LogLevel value) => _processLevel = value;

  /// The tokens everything here draws with: [themed]'s for the work in progress, else the
  /// process-wide one assigning this sets.
  static ConsoleTheme get theme => Zone.current[_themeKey] as ConsoleTheme? ?? _processTheme;

  static set theme(ConsoleTheme value) => _processTheme = _bridged(value);

  /// Lets `Table.show`, which cannot import this, draw with the theme's border.
  static ConsoleTheme _bridged(ConsoleTheme theme) {
    IoBridge.border ??= () => Console.theme.border;
    return theme;
  }

  static bool _isEnabled(LogLevel candidate) => candidate.index >= level.index && level != LogLevel.silent;

  /// Runs [action], sync or async, with logging suppressed — for [action] and what it
  /// awaits, not for a task running beside it.
  static Future<T> silenced<T>(FutureOr<T> Function() action) => _scoped(_levelKey, LogLevel.silent, action);

  /// Runs [action] drawing with [theme], as [silenced] scopes the level.
  static Future<T> themed<T>(ConsoleTheme theme, FutureOr<T> Function() action) =>
      _scoped(_themeKey, _bridged(theme), action);

  static Future<T> _scoped<T>(Symbol key, Object value, FutureOr<T> Function() action) =>
      runZoned(() async => action(), zoneValues: {key: value});

  // ---- logging ----

  /// A counter over [total] stages, printing `[n/total] message` on each call.
  ///
  /// ```dart
  /// final stage = Console.stages(3);
  /// stage('Scraping metadata');   // [1/3] Scraping metadata
  /// ```
  static Stages stages(int total) => Stages._(total);

  /// Writes [line] at [severity], warnings and errors on stderr.
  static void _log(LogLevel severity, String line) {
    if (!_isEnabled(severity)) return;
    _durable(() => (severity.index >= LogLevel.warn.index ? Io.err : Io.out).writeln(line));
  }

  // Each verb writes any object's `toString()`, so an exception needs no `'$e'`.

  /// Logs a verbose diagnostic: `  · message`.
  static void debug(Object? message) => _log(LogLevel.debug, theme._line(theme.muted, theme.debug, '$message'));

  /// Logs a success: `  ✓ message`. Filtered at [LogLevel.info], like [info].
  static void ok(Object? message) => _log(LogLevel.info, theme._line(theme.success, theme.ok, '$message'));

  /// Logs information: `  ℹ message`.
  static void info(Object? message) => _log(LogLevel.info, theme._line(theme.accent, theme.info, '$message'));

  /// Logs a warning to stderr: `  ⚠ message`.
  static void warn(Object? message) => _log(LogLevel.warn, theme._line(theme.warning, theme.warn, '$message'));

  /// Logs an error to stderr: `  ✖ message`.
  static void error(Object? message) => _log(LogLevel.error, theme._line(theme.danger, theme.error, '$message'));

  // ---- prompts ----
  //
  // Every prompt is async: the read blocks a helper isolate ([Io.readLine]), so `Cli.run`'s
  // ^C handler still runs while one waits.

  /// Writes [question] between the theme's prompt marks and reads one trimmed line, `null`
  /// at end of input. Every word goes to stderr, so `app > out.txt` captures no question.
  static Future<String?> _answer(String question) async {
    Io.err.write('${theme.prompt}$question${theme.promptEnd}');
    return (await Io.readLine())?.trim();
  }

  static void _reject(String message) => Io.err.writeln(theme.danger('${theme.indent}$message'));

  /// Whether [secret] has echo off right now, so the way out can turn it back on.
  static bool _echoOff = false;

  /// Puts the terminal back as a prompt found it: what a signal does before it leaves.
  static void _restoreTerminal() {
    if (!_echoOff) return;
    _echoOff = false;
    try {
      stdin.echoMode = true;
    } catch (_) {}
  }

  /// Prompts for text input, returning [or] on an empty answer.
  ///
  /// [validate] returns an error message to re-prompt, or `null` to accept. At end of
  /// input the default is used, or a [StateError] is thrown when a [required] value has none.
  ///
  /// ```dart
  /// final port = await Console.ask('Port', or: '8080',
  ///     validate: (v) => int.tryParse(v) == null ? 'Must be a number' : null);
  /// ```
  static Future<String> ask(
    String message, {
    String? or,
    bool required = false,
    String? Function(String value)? validate,
  }) => _suspend(() async {
    assert(!(required && or != null), 'A required prompt cannot also have a default.');
    while (true) {
      final input = await _answer('$message${or != null ? theme.muted(' ($or)') : ''}');
      if (input == null) {
        if (required) throw StateError('No input available for required prompt: $message');
        return or ?? '';
      }
      final value = input.isEmpty ? (or ?? '') : input;
      final error = value.isEmpty && required ? 'Value cannot be empty.' : validate?.call(value);
      if (error == null) return value;
      _reject(error);
    }
  });

  /// Prompts for a yes/no confirmation, returning [or] on an empty answer.
  ///
  /// Anything but a yes or a no asks again: a typo of `yes` is not a no.
  static Future<bool> confirm(String message, {bool or = true}) => _suspend(() async {
    while (true) {
      final input = (await _answer('$message ${theme.muted(or ? '[Y/n]' : '[y/N]')}'))?.toLowerCase();
      if (input == null || input.isEmpty) return or;
      if (const {'y', 'yes', 'true', '1'}.contains(input)) return true;
      if (const {'n', 'no', 'false', '0'}.contains(input)) return false;
      _reject('Please answer y or n.');
    }
  });

  /// Prompts for sensitive input, hiding typed characters.
  static Future<String> secret(String message) => _suspend(() async {
    final watches = <StreamSubscription<ProcessSignal>>[];
    void onSig(ProcessSignal s) {
      _restoreTerminal();
      exit(128 + s.signalNumber);
    }

    try {
      if (Io.input == null && stdin.hasTerminal) {
        stdin.echoMode = false;
        _echoOff = true;
        watches.add(ProcessSignal.sigint.watch().listen(onSig));
        if (!Platform.isWindows) watches.add(ProcessSignal.sigterm.watch().listen(onSig));
      }
    } catch (_) {}
    try {
      final input = await _answer(message) ?? '';
      Io.err.writeln();
      return input;
    } finally {
      for (final w in watches) {
        await w.cancel();
      }
      _restoreTerminal();
    }
  });

  /// Prompts for one of [choices], of any element type.
  ///
  /// An enum shows by its [Enum.name]; [display] renders anything else:
  /// `await Console.select('Target', servers, display: (s) => s.name)`. [T] is never
  /// nullable, so `ctx(bump) ?? await Console.select('Bump', Bump.values)` is a `Bump`.
  ///
  /// Throws [ArgumentError] at once when [or] is not one of [choices], as `Opt.or` does.
  static Future<T> select<T extends Object>(
    String message,
    List<T> choices, {
    T? or,
    String Function(T choice)? display,
  }) {
    if (choices.isEmpty) throw ArgumentError('Choices cannot be empty');
    String label(T choice) => display?.call(choice) ?? _label(choice);
    final fallback = or != null ? choices.indexOf(or) : -1;
    if (or != null && fallback < 0) {
      throw ArgumentError.value(or, 'or', 'Not one of ${choices.map(label).join(', ')}');
    }
    return _suspend(() async {
      final t = theme;
      Io.err.writeln('$message:');
      for (final (i, choice) in choices.indexed) {
        Io.err.writeln('${t.indent}${i + 1}) ${label(choice)}${i == fallback ? t.muted(' (default)') : ''}');
      }
      while (true) {
        final input = await _answer('Select [1-${choices.length}]${fallback >= 0 ? ' [${fallback + 1}]' : ''}');
        if ((input == null || input.isEmpty) && fallback >= 0) return choices[fallback];
        if (input == null) throw StateError('No input available for required prompt: $message');
        if (int.tryParse(input) case final n? when n >= 1 && n <= choices.length) return choices[n - 1];
        if (choices.where((c) => label(c) == input).firstOrNull case final match?) return match;
        _reject('Invalid choice, please enter a number from 1 to ${choices.length}.');
      }
    });
  }

  // ---- the screen ----

  /// A divider across the terminal in the theme's border glyph, with an optional centred
  /// [title].
  static void rule([String? title]) => _durable(() {
    final t = theme;
    final cols = Io.columns ?? 80;
    final glyph = t.border.top.isEmpty ? ' ' : t.border.top;
    if (title == null || title.isEmpty) return Io.out.writeln(glyph * cols);
    final titleLen = Io.width(title) + 2;
    if (titleLen >= cols) return Io.out.writeln('${glyph * 2} $title ${glyph * 2}');
    final side = (cols - titleLen) ~/ 2;
    Io.out.writeln(t.accent('${glyph * side} $title ${glyph * (cols - titleLen - side)}'));
  });

  // ---- indicators ----

  /// A single-line progress bar over [total] steps; [line] draws it from a [ProgressView].
  ///
  /// ```dart
  /// final bar = Console.progress(files.length, line: (p) => '${p.bar(30)} ${p.current}/${p.total} eta ${p.eta?.humanized}');
  /// ```
  static ProgressBar progress(
    int total, {
    String message = '',
    int? columns,
    String Function(ProgressView view)? line,
  }) => ProgressBar._(total, message, columns, line);

  /// A board of task rows under one header line: [slots] rows, or one for each task that
  /// runs at once. Omit [total] while the work is being discovered; [TaskBoard.report]
  /// revises it upward. [task] draws a row from a [TaskView], [header] the top line from
  /// a [BatchView].
  static TaskBoard tasks({
    int total = 0,
    int? slots,
    String message = '',
    int? columns,
    String Function(TaskView view)? task,
    String Function(BatchView view)? header,
  }) => TaskBoard._(total, slots, message, columns, task, header);

  /// A spinner left running until the caller ends it; [line] draws it from a [SpinnerView].
  ///
  /// Use [spin] instead when the work is a single call.
  static Spinner spinner(String message, {String Function(SpinnerView view)? line}) =>
      Spinner._(message, line).._start();

  /// Runs [action] behind a spinner; [done] and [failed] replace [message] on the final
  /// line. Returns what [action] returns; rethrows what it throws, after the failure line.
  static Future<T> spin<T>(
    String message,
    FutureOr<T> Function() action, {
    String? done,
    String? failed,
    String Function(SpinnerView view)? line,
  }) async {
    final spinner = Console.spinner(message, line: line);
    try {
      final result = await action();
      spinner.succeed(done);
      return result;
    } catch (e) {
      spinner.fail(failed ?? '$message failed: $e');
      rethrow;
    }
  }
}

/// Rendering a batch as it runs.
///
/// {@category Terminal}
extension StreamBatchProgressExtensions<T extends BatchProgress> on Stream<T> {
  /// Draws this batch in a [TaskBoard] until it ends, then prints [done]; a failure count
  /// is a warning instead. Returns the last event, or `null` for an empty batch.
  ///
  /// The board has a row per task running at once; [slots] fixes the count. [task] and
  /// [header] are the board's builders, as in [Console.tasks].
  ///
  /// ```dart
  /// await pairs.download().show(task: (t) => '${t.index}/${t.count} ${t.name} ${t.bar(20)} ${t.speed.humanBytes}/s');
  /// ```
  Future<T?> show({
    int? slots,
    String message = '',
    String? done,
    int? columns,
    String Function(TaskView view)? task,
    String Function(BatchView view)? header,
  }) async {
    final board = Console.tasks(slots: slots, message: message, columns: columns, task: task, header: header);
    T? last;
    var completed = false;
    try {
      await for (final p in this) {
        if (p.current.isDone && p.current.status == 'failed') Console.error(p.current.error ?? p.current.label);
        board.report(last = p);
      }
      completed = true;
    } finally {
      final failed = completed ? last?.failed ?? 0 : 0;
      board.done(completed && failed == 0 ? done : null);
      if (failed > 0) Console.warn('$failed of ${last?.total ?? last?.completed ?? failed} failed');
    }
    return last;
  }
}
