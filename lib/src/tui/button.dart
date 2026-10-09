part of '../../tui.dart';

/// A [Button] as its `button:` builder sees it.
///
/// {@category CLI}
final class ButtonView {
  final String label;
  final bool isHovered, isFocused, isPressed, isEnabled;
  final Palette palette;

  const ButtonView(
    this.label, {
    this.isHovered = false,
    this.isFocused = false,
    this.isPressed = false,
    this.isEnabled = true,
    this.palette = const Palette(),
  });
}

/// `[ Save ]`: muted when disabled, reversed while pressed, the accent with the focus, underlined
/// under the pointer.
Widget _buttonFace(ButtonView b) {
  final p = b.palette;
  final style = !b.isEnabled
      ? p.muted
      : (b.isPressed ? const Style(reverse: true) : Style.none) +
            (b.isFocused ? p.accent + const Style(bold: true) : p.text) +
            (b.isHovered ? const Style(underline: true) : Style.none);
  return Label('[ ${b.label} ]', style: style, wrap: false);
}

/// A button: it sends [message] to the app's `update` (as a [Sent]) when clicked, or on Enter or
/// Space while it has the focus. A disabled one takes neither the focus nor clicks. How it looks
/// in each state is the theme's `button:` builder, or [button].
///
/// ```dart
/// HStack([Button('Save', message: const Save()), Button('Quit', message: const Quit())], gap: 2)
/// … case Sent(message: Save()) => save(s), …
/// ```
///
/// Two buttons with the same label and message are the same button, so one built anew in each
/// `view` keeps the focus.
///
/// {@category CLI}
final class Button<M> extends Widget with Focusable {
  final String label;
  final M message;
  final bool enabled;
  final Widget Function(ButtonView view)? button;

  Button(this.label, {required this.message, this.enabled = true, this.button});

  @override
  int get width => Style.width(label) + 4;

  @override
  bool handle(TuiEvent<Object?> event) {
    if (!enabled || (event != KeyPress.enter && event != const Char(' '))) return false;
    _Engine._active?._message(message);
    return true;
  }

  @override
  void paint(Canvas canvas) {
    final build = button ?? canvas.theme.button;
    // Only the button itself takes clicks, however wide a row it is given: as wide as its face.
    final face = build(ButtonView(label, isEnabled: enabled, palette: canvas.palette)).width;
    canvas = canvas.area(0, 0, face > 0 && face < canvas.width ? face : canvas.width, 1);
    final focused = enabled && canvas._register(this, message, true);
    final view = ButtonView(
      label,
      isHovered: enabled && canvas.isHovered,
      isFocused: focused,
      isPressed: enabled && canvas.isPressed,
      isEnabled: enabled,
      palette: canvas.palette,
    );
    canvas.draw(build(view));
  }

  @override
  bool operator ==(Object other) => other is Button<M> && other.label == label && other.message == message;

  @override
  int get hashCode => Object.hash(label, message);
}

/// [child] made clickable: a click sends [message] to the app's `update`, and while the pointer
/// is over it [hover] (by default an underline) is laid over it. For links, cards and rows; a
/// control the keys can reach too is a [Button].
///
/// ```dart
/// Clickable(Label(file.name), message: Open(file))
/// ```
///
/// {@category CLI}
final class Clickable<M> extends Widget {
  final Widget child;
  final M message;
  final Style hover;

  const Clickable(this.child, {required this.message, this.hover = const Style(underline: true)});

  @override
  int get width => child.width;

  @override
  int heightAt(int width) => child.heightAt(width);

  @override
  void paint(Canvas canvas) {
    canvas.draw(child);
    canvas._clickable(message);
    if (canvas.isHovered) canvas.tint(hover);
  }
}

/// A popup: [content] drawn above everything else, under [anchor] (or above it where there is no
/// room below), clipped to the screen. A click outside it sends [dismiss], so `update` can stop
/// showing it. [Popup.at] places it at a position, [Popup.modal] in the middle of the screen,
/// where it alone takes the keys and the pointer.
///
/// ```dart
/// Popup(Button('File', message: const OpenMenu()), content: Menu(fileMenu), dismiss: const CloseMenu())
/// if (s.confirming) Popup.modal(Box(confirm, title: 'Delete?'), dismiss: const Cancel())
/// ```
///
/// {@category CLI}
final class Popup<M> extends Widget {
  final Widget? anchor;
  final Widget content;
  final M dismiss;
  final (int, int)? _at;
  final bool _modal;

  const Popup(Widget this.anchor, {required this.content, required this.dismiss}) : _at = null, _modal = false;

  /// [content] with its top left at column [x], row [y] of the screen.
  const Popup.at(int x, int y, {required this.content, required this.dismiss})
    : anchor = null,
      _at = (x, y),
      _modal = false;

  /// [content] in the middle of the screen, the only thing the keys and the pointer reach.
  const Popup.modal(this.content, {required this.dismiss}) : anchor = null, _at = null, _modal = true;

  @override
  int get width => anchor?.width ?? 0;

  @override
  int heightAt(int width) => anchor?.heightAt(width) ?? 0;

  @override
  void paint(Canvas canvas) {
    if (anchor case final a?) canvas.draw(a);
    final at = anchor == null ? canvas : canvas._natural(anchor!);
    final layer = switch (_at) {
      (final x, final y) => _Layer(content, (x, y - 1, 0, 1), dismiss, dismissible: true, modal: false),
      null when _modal => _Layer(content, null, dismiss, dismissible: true, modal: true),
      null => _Layer(content, (at._x, at._y, at.width, at.height), dismiss, dismissible: true, modal: false),
    };
    canvas._frame.popups.add(layer);
  }
}

/// [child], and [text] in a popup under it while the pointer is over it.
///
/// {@category CLI}
final class Tooltip extends Widget {
  final Widget child;
  final String text;

  const Tooltip(this.child, this.text);

  @override
  int get width => child.width;

  @override
  int heightAt(int width) => child.heightAt(width);

  @override
  void paint(Canvas canvas) {
    canvas.draw(child);
    final over = canvas._natural(child);
    if (over.isHovered) over._popup(_Tip(text));
  }
}

final class _Tip extends Widget {
  final String text;

  const _Tip(this.text);

  @override
  int get width => Style.width(text) + 2;

  @override
  void paint(Canvas canvas) {
    canvas.fill(canvas.palette.muted + const Style(reverse: true));
    canvas.text(1, 0, text);
  }
}

/// A popup as placed on screen.
typedef _Placed = ({_Layer layer, int x, int y, int w, int h});

/// Draws [frame]'s popups over [buf], each clipped to it; popups a popup opens are drawn after it.
List<_Placed> _paintPopups(_Buffer buf, _Frame frame, TuiTheme theme) {
  final placed = <_Placed>[];
  for (var i = 0; i < frame.popups.length; i++) {
    final layer = frame.popups[i];
    final w = layer.content.width.clamp(1, buf.width);
    final h = layer.content.heightAt(w).clamp(1, buf.height);
    final (int x, int y) = switch (layer.anchor) {
      null => ((buf.width - w) ~/ 2, (buf.height - h) ~/ 2),
      (final ax, final ay, _, final ah) => (
        ax.clamp(0, buf.width - w),
        (ay + ah + h <= buf.height ? ay + ah : (ay - h >= 0 ? ay - h : buf.height - h)).clamp(0, buf.height - h),
      ),
    };
    if (layer.modal) frame.modalFrom = frame.targets.length;
    final canvas = Canvas._(buf, x, y, w, h, theme, frame)..fill();
    canvas.draw(layer.content);
    placed.add((layer: layer, x: x, y: y, w: w, h: h));
  }
  return placed;
}
