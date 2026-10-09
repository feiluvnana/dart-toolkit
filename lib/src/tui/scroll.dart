part of '../../tui.dart';

/// What [Scroll] and [Log] share: the first row shown, moved by Up/Down, PgUp/PgDn and
/// Home/End while it has the focus, and by the wheel under the pointer.
abstract class _Scrolled extends Widget with Focusable {
  final bool scrollbar;

  /// The first row shown, the rows shown, and the rows there are, as of the last frame.
  int _offset = 0, _page = 1, _count = 0;

  _Scrolled(this.scrollbar);

  bool get _atEnd => _offset >= _count - _page;

  void _scroll(int by) => _offset = (_offset + by).clamp(0, (_count - _page).clamp(0, _count));

  /// After every move: what [Log] does to follow.
  void _moved() {}

  @override
  bool handle(TuiEvent<Object?> event) {
    switch (event) {
      case KeyPress.up:
        _scroll(-1);
      case KeyPress.down:
        _scroll(1);
      case KeyPress.pageUp:
        _scroll(-_page);
      case KeyPress.pageDown:
        _scroll(_page);
      case KeyPress.home:
        _scroll(-_count);
      case KeyPress.end:
        _scroll(_count);
      default:
        return false;
    }
    _moved();
    return true;
  }

  @override
  void pointer(Pointer event, int x, int y) {
    if (event.kind case PointerKind.wheelUp || PointerKind.wheelDown) {
      _scroll(event.kind == PointerKind.wheelUp ? -3 : 3);
      _moved();
    }
  }
}

/// [child] in less room than it wants, scrolled by keys while focused and by the wheel, with a
/// scrollbar when it does not fit. Hold it across frames, as a [Field], so it keeps its place;
/// give it a new [child] when the content changes.
///
/// ```dart
/// final help = Scroll(Label(manual));
/// … Box(help, title: 'Help').flex() …
/// ```
///
/// {@category CLI}
final class Scroll extends _Scrolled {
  Widget child;

  /// Whether the last frame drew a scrollbar: the width to lay the child out at first, so a
  /// child that does not fit is laid out once per frame, not twice.
  bool _barred = false;

  Scroll(this.child, {bool scrollbar = true}) : super(scrollbar);

  @override
  int get width => child.width + (scrollbar ? 1 : 0);

  @override
  int heightAt(int width) => child.heightAt(width);

  @override
  void paint(Canvas canvas) {
    canvas.focus(this);
    final full = canvas.width;
    var (w, h) = (full - 1, 0);
    if (!(scrollbar && _barred && (h = child.heightAt(w)) > canvas.height)) {
      h = child.heightAt(w = full);
      if (scrollbar && h > canvas.height) h = child.heightAt(w = full - 1);
    }
    final bar = w < full ? 1 : 0;
    _barred = bar == 1;
    _count = h;
    _page = canvas.height;
    _scroll(0);
    if (h <= canvas.height) return canvas.area(0, 0, w).draw(child);
    // The child at its full height, starting [_offset] rows above, writes only the rows in view.
    final top = canvas._y > canvas._top ? canvas._y : canvas._top;
    final bottom = canvas._y + canvas._shownTo;
    child.paint(Canvas._(canvas._buf, canvas._x, canvas._y - _offset, w, h, canvas.theme, canvas._frame, top, bottom));
    if (bar == 1) _scrollbar(canvas, _offset, _page, _count);
  }
}

/// A log pane over [lines], one row each in its own styles (cut with `…` when wider). With [follow] it stays on
/// the newest as lines arrive, until it is scrolled up; End, or scrolling back down, follows
/// again. Hold it across frames and add to [lines] (or assign a new list) as the log grows.
///
/// ```dart
/// final log = Log([]);
/// … Box(log, title: 'Output').flex() …
/// update: (s, e) { if (e case Line(:final text)) log.lines.add(text); return s; }
/// ```
///
/// {@category CLI}
final class Log extends _Scrolled {
  List<String> lines;
  final bool follow;
  bool _following;

  /// The widest line seen, and the list and how many of its lines it has measured.
  int _widest = 0, _measured = 0;
  List<String>? _of;

  Log(this.lines, {this.follow = true, bool scrollbar = true}) : _following = follow, super(scrollbar);

  /// Measures only the lines added since it last did (all of them for another list).
  @override
  int get width {
    if (!identical(_of, lines) || _measured > lines.length) {
      _widest = _measured = 0;
      _of = lines;
    }
    for (; _measured < lines.length; _measured++) {
      final w = Style.width(lines[_measured]);
      if (w > _widest) _widest = w;
    }
    return _widest + (scrollbar ? 1 : 0);
  }

  @override
  int heightAt(int width) => lines.isEmpty ? 1 : lines.length;

  @override
  void _moved() => _following = follow && _atEnd;

  @override
  void paint(Canvas canvas) {
    canvas.focus(this);
    _count = lines.length;
    _page = canvas.height;
    final bar = scrollbar && _count > _page ? 1 : 0;
    _following ? _scroll(_count) : _scroll(0);
    final w = canvas.width - bar, p = canvas.palette;
    for (var y = 0; y < _page && _offset + y < _count; y++) {
      canvas.text(0, y, Style.truncate(lines[_offset + y].replaceAll('\n', ' '), w, ellipsis: p.ellipsis), p.text);
    }
    if (bar == 1) _scrollbar(canvas, _offset, _page, _count);
  }
}
