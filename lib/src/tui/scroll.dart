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
  void mouse(Mouse event, int x, int y) {
    if (event.kind case MouseKind.wheelUp || MouseKind.wheelDown) {
      _scroll(event.kind == MouseKind.wheelUp ? -3 : 3);
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

  Scroll(this.child, {bool scrollbar = true}) : super(scrollbar);

  @override
  int get width => child.width + (scrollbar ? 1 : 0);

  @override
  int heightAt(int width) => child.heightAt(width);

  @override
  void paint(Canvas canvas) {
    canvas.focus(this);
    var w = canvas.width, h = child.heightAt(w);
    final bar = scrollbar && h > canvas.height ? 1 : 0;
    if (bar == 1) h = child.heightAt(w -= 1);
    _count = h;
    _page = canvas.height;
    _scroll(0);
    if (h <= canvas.height) return canvas.area(0, 0, w).draw(child);
    // Painted whole off screen, then the rows in view copied: a child cannot start above its canvas.
    final buf = _Buffer(w, h);
    child.paint(Canvas._(buf, 0, 0, w, h, canvas.theme, canvas._frame));
    canvas._blit(buf, _offset);
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

  Log(this.lines, {this.follow = true, bool scrollbar = true}) : _following = follow, super(scrollbar);

  @override
  int get width => _max(lines.map(Style.width)) + (scrollbar ? 1 : 0);

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
