part of '../../tui.dart';

/// Something that paints a rectangle. Immutable, except the controls that hold an input's
/// state ([Field]); compose them into a tree each frame.
///
/// A new widget is a [Paint] for a one-off, or a subclass for a reusable one: [paint] draws,
/// [width] and [heightAt] tell a stack how much it wants.
///
/// {@category CLI}
abstract class Widget {
  const Widget();

  /// The columns this would take with all it wants: what an [HStack] gives an unsized child.
  int get width => 0;

  /// The rows this takes at [width]: what a [VStack] gives an unsized child, and an inline app's height.
  int heightAt(int width) => 1;

  void paint(Canvas canvas);

  /// In a stack, exactly [n] cells along the stack.
  Widget fixed(int n) => _Sized(this, _Size.fixed, n);

  /// In a stack, a share of what the others leave, by [weight].
  Widget flex([int weight = 1]) => _Sized(this, _Size.flex, weight);

  /// In a stack, [n] percent of the stack.
  Widget percent(int n) => _Sized(this, _Size.percent, n);

  /// This widget as text [width] columns wide: a styled one-off to print, or a golden to test.
  ///
  /// Escapes follow [Io.color] unless [color] says.
  ///
  /// ```dart
  /// print(Box(Label('Deployed'), title: 'prod').render(30));
  /// ```
  String render(int width, {int? height, TuiTheme? theme, bool? color}) {
    final h = height ?? heightAt(width);
    final buf = _Buffer(width, h);
    paint(Canvas._(buf, 0, 0, width, h, (theme ?? const TuiTheme()), _Frame(null, Duration.zero, live: false)));
    final depth = (color ?? Io.color) ? _Tty._depth() : -1;
    return [for (var y = 0; y < h; y++) buf.row(y, depth)].join('\n');
  }
}

enum _Size { fixed, flex, percent }

final class _Sized extends Widget {
  final Widget child;
  final _Size kind;
  final int n;

  const _Sized(this.child, this.kind, this.n);

  @override
  int get width => child.width;

  @override
  int heightAt(int width) => child.heightAt(width);

  @override
  void paint(Canvas canvas) => child.paint(canvas);
}

/// What [c] wants along a stack: its fixed size, else [natural].
int _want(Widget c, int Function(Widget) natural) => c is _Sized && c.kind == _Size.fixed ? c.n : natural(c);

/// Sizes along a stack of [total] cells: fixed and percent first, unsized at [natural], flex
/// splits the rest by weight; past the end, children get nothing.
List<int> _split(int total, List<Widget> children, int gap, int Function(Widget) natural) {
  final avail = (total - gap * (children.length - 1)).clamp(0, total);
  final sizes = [
    for (final c in children)
      switch (c) {
        _Sized(kind: _Size.fixed, :final n) => n,
        _Sized(kind: _Size.percent, :final n) => avail * n ~/ 100,
        _Sized(kind: _Size.flex) => 0,
        _ => natural(c),
      },
  ];
  final weights = [for (final c in children) c is _Sized && c.kind == _Size.flex ? c.n : 0];
  final weight = _sum(weights);
  var left = avail - _sum(sizes);
  if (weight > 0 && left > 0) {
    var given = 0, seen = 0;
    for (var i = 0; i < sizes.length; i++) {
      if (weights[i] == 0) continue;
      seen += weights[i];
      final share = left * seen ~/ weight - given;
      sizes[i] = share;
      given += share;
    }
  }
  left = avail;
  for (var i = 0; i < sizes.length; i++) {
    sizes[i] = sizes[i].clamp(0, left);
    left -= sizes[i];
  }
  return sizes;
}

/// Children top to bottom, [gap] rows apart. Size them with [Widget.fixed], [Widget.flex], [Widget.percent].
///
/// ```dart
/// VStack([Label('Files', style: theme.accent), Menu(files, pick).flex(), Label(status)])
/// ```
///
/// {@category CLI}
final class VStack extends Widget {
  final List<Widget> children;
  final int gap;

  const VStack(this.children, {this.gap = 0});

  @override
  int get width => _max(children.map((c) => c.width));

  @override
  int heightAt(int width) =>
      _sum(children.map((c) => _want(c, (c) => c.heightAt(width)))) +
      gap * (children.isEmpty ? 0 : children.length - 1);

  @override
  void paint(Canvas canvas) {
    final sizes = _split(canvas.height, children, gap, (c) => c.heightAt(canvas.width));
    var y = 0;
    for (final (i, c) in children.indexed) {
      canvas.area(0, y, canvas.width, sizes[i]).draw(c);
      y += sizes[i] + gap;
    }
  }
}

/// Children left to right, [gap] columns apart. Size them with [Widget.fixed], [Widget.flex], [Widget.percent].
///
/// {@category CLI}
final class HStack extends Widget {
  final List<Widget> children;
  final int gap;

  const HStack(this.children, {this.gap = 0});

  @override
  int get width =>
      _sum(children.map((c) => _want(c, (c) => c.width))) + gap * (children.isEmpty ? 0 : children.length - 1);

  @override
  int heightAt(int width) {
    final sizes = _split(width, children, gap, (c) => c.width);
    var h = 0;
    for (final (i, c) in children.indexed) {
      final ch = c.heightAt(sizes[i]);
      if (ch > h) h = ch;
    }
    return h;
  }

  @override
  void paint(Canvas canvas) {
    final sizes = _split(canvas.width, children, gap, (c) => c.width);
    var x = 0;
    for (final (i, c) in children.indexed) {
      canvas.area(x, 0, sizes[i], canvas.height).draw(c);
      x += sizes[i] + gap;
    }
  }
}

/// How a line sits in its width.
///
/// {@category CLI}
enum Align { left, center, right }

/// Text, wrapped at word boundaries to its width unless [wrap] is off (then cut with `…`).
///
/// ```dart
/// Label('Saved', style: theme.success)
/// Label.spans([Span('3', Style(bold: true)), Span(' files changed')], align: Align.right)
/// ```
///
/// {@category CLI}
final class Label extends Widget {
  final List<Span> spans;
  final Style? style;
  final Align align;
  final bool wrap;

  Label(String text, {this.style, this.align = Align.left, this.wrap = true}) : spans = [Span(Io.stripAnsi(text))];

  const Label.spans(this.spans, {this.style, this.align = Align.left, this.wrap = true});

  @override
  int get width {
    var best = 0, w = 0;
    for (final s in spans) {
      for (final (g, cw) in _graphemes(s.text)) {
        if (g == '\n') {
          if (w > best) best = w;
          w = 0;
        } else {
          w += cw;
        }
      }
    }
    return w > best ? w : best;
  }

  @override
  int heightAt(int width) => _lines(width).length;

  /// The text as lines of cells, broken at [width].
  List<List<(String, int, Style)>> _lines(int width) {
    final lines = <List<(String, int, Style)>>[[]];
    var w = 0, space = -1;
    for (final s in spans) {
      for (final (g, cw) in _graphemes(s.text)) {
        var line = lines.last;
        if (g == '\n') {
          lines.add([]);
          (w, space) = (0, -1);
          continue;
        }
        if (wrap && width > 0 && w + cw > width && line.isNotEmpty) {
          if (g == ' ') {
            lines.add([]);
            (w, space) = (0, -1);
            continue;
          }
          final carry = space >= 0 ? line.sublist(space + 1) : <(String, int, Style)>[];
          if (space >= 0) line.removeRange(space, line.length);
          lines.add(carry);
          line = carry;
          w = _sum(carry.map((c) => c.$2));
          space = -1;
        }
        if (g == ' ') space = line.length;
        line.add((g, cw, s.style));
        w += cw;
      }
    }
    return lines;
  }

  @override
  void paint(Canvas canvas) {
    final base = canvas.theme.text + style;
    canvas.fill(base);
    final lines = _lines(canvas.width);
    for (var y = 0; y < lines.length && y < canvas.height; y++) {
      var line = lines[y];
      var w = _sum(line.map((c) => c.$2));
      if (w > canvas.width) {
        final cut = <(String, int, Style)>[];
        var cw = 0;
        for (final c in line) {
          if (cw + c.$2 > canvas.width - 1) break;
          cut.add(c);
          cw += c.$2;
        }
        line = [...cut, ('…', 1, cut.isEmpty ? Style.none : cut.last.$3)];
        w = cw + 1;
      }
      var x = switch (align) {
        Align.left => 0,
        Align.center => (canvas.width - w) ~/ 2,
        Align.right => canvas.width - w,
      };
      for (final (g, _, s) in line) {
        x = canvas.text(x, y, g, s);
      }
    }
  }
}

/// A border, an optional [title], [padding] (rows, columns) and a [child].
///
/// The border takes the theme's `focused` style while the focus is inside it.
///
/// ```dart
/// Box(Menu(files, pick), title: 'Files', border: Border.double)
/// ```
///
/// {@category CLI}
final class Box extends Widget {
  final Widget? child;
  final String? title;
  final Border? border;
  final Style? style;
  final (int, int) padding;

  const Box(this.child, {this.title, this.border, this.style, this.padding = (0, 1)});

  int get _edge => border?.side.isEmpty ?? false ? 0 : 1;

  @override
  int get width {
    final e = _edge * 2 + padding.$2 * 2;
    final t = title == null ? 0 : Io.width(title!) + 4;
    final c = (child?.width ?? 0) + e;
    return c > t ? c : t;
  }

  @override
  int heightAt(int width) {
    final e = _edge, noSide = e == 0 && title != null ? 1 : 0;
    return (child?.heightAt(width - e * 2 - padding.$2 * 2) ?? 0) + e * 2 + padding.$1 * 2 + noSide;
  }

  @override
  void paint(Canvas canvas) {
    final b = border ?? canvas.theme.borders;
    final e = b.side.isEmpty ? 0 : 1;
    final top = e == 0 && title != null ? 1 : 0;
    final before = canvas._frame.focusPainted;
    canvas
        .area(
          e + padding.$2,
          e + padding.$1 + top,
          canvas.width - 2 * (e + padding.$2),
          canvas.height - 2 * (e + padding.$1) - top,
        )
        .draw(child ?? Paint((_) {}));
    final focused = !before && canvas._frame.focusPainted;
    canvas.box(border: b, title: title, style: style ?? (focused ? canvas.theme.focused : canvas.theme.border));
  }
}

/// A one-off widget: [painter] draws on the canvas it is given, [width] × [height] by preference.
///
/// ```dart
/// Paint((c) => c.text(0, 0, '●', Style(fg: online ? Color.green : Color.red)), width: 1)
/// ```
///
/// {@category CLI}
final class Paint extends Widget {
  final void Function(Canvas canvas) painter;
  final int _width, _height;

  const Paint(this.painter, {int width = 0, int height = 1}) : _width = width, _height = height;

  @override
  int get width => _width;

  @override
  int heightAt(int width) => _height;

  @override
  void paint(Canvas canvas) => painter(canvas);
}

/// [child] under [theme]: what [theme] leaves unset comes from the theme around it.
///
/// {@category CLI}
final class Themed extends Widget {
  final TuiTheme theme;
  final Widget child;

  const Themed(this.theme, this.child);

  @override
  int get width => child.width;

  @override
  int heightAt(int width) => child.heightAt(width);

  @override
  void paint(Canvas canvas) => child.paint(
    Canvas._(canvas._buf, canvas._x, canvas._y, canvas.width, canvas.height, theme._over(canvas.theme), canvas._frame),
  );
}
