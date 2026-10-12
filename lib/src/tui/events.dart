/// What an app hears, each one noun for what arrived: a moment ([Start],
/// [Resize], [Focus], [Blur], [Suspend], [Resume], [Interrupt]), an input
/// ([KeyPress], [Paste], [Pointer]), or its own message ([Post]). Sealed, so a
/// `switch` over it is exhaustive.
///
/// `key` reads the pressed name on a [KeyPress] and is `null` otherwise, so
/// `if (ev.key == 'q') break` works on any event.
sealed class TuiEvent {
  const TuiEvent();

  /// The pressed key name, or `null` for non-key events.
  String? get key => this is KeyPress ? (this as KeyPress).name : null;
}

/// Once, when the terminal is ready and before the first frame: where an app
/// starts its work (`post`, `listen`).
final class Start extends TuiEvent {
  const Start();

  @override
  bool operator ==(Object other) => other is Start;

  @override
  int get hashCode => (Start).hashCode;

  @override
  String toString() => 'Start';
}

/// The terminal is now [width] × [height]; the next frame draws at that size.
final class Resize extends TuiEvent {
  final int width, height;

  const Resize(this.width, this.height);

  @override
  bool operator ==(Object other) => other is Resize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'Resize($width×$height)';
}

/// The terminal window gained the focus; [Blur] when it lost it. Not a
/// control's focus.
final class Focus extends TuiEvent {
  const Focus();

  @override
  bool operator ==(Object other) => other is Focus;

  @override
  int get hashCode => (Focus).hashCode;

  @override
  String toString() => 'Focus';
}

/// The terminal window lost the focus.
final class Blur extends TuiEvent {
  const Blur();

  @override
  bool operator ==(Object other) => other is Blur;

  @override
  int get hashCode => (Blur).hashCode;

  @override
  String toString() => 'Blur';
}

/// ^Z: the terminal is put back and the process stops once `update` has seen
/// it. POSIX only; on Windows ^Z arrives as `KeyPress('z', ctrl: true)`.
final class Suspend extends TuiEvent {
  const Suspend();

  @override
  bool operator ==(Object other) => other is Suspend;

  @override
  int get hashCode => (Suspend).hashCode;

  @override
  String toString() => 'Suspend';
}

/// The process runs again after a [Suspend]: the screen is redrawn whole.
final class Resume extends TuiEvent {
  const Resume();

  @override
  bool operator ==(Object other) => other is Resume;

  @override
  int get hashCode => (Resume).hashCode;

  @override
  String toString() => 'Resume';
}

/// ^C: delivered as an event, never as a signal. Answering it (drawing again)
/// keeps the app open; a second ^C within two seconds closes the run (the next
/// `draw`/`poll` throws the end-of-run), and the terminal is restored on every
/// way out.
final class Interrupt extends TuiEvent {
  const Interrupt();

  @override
  bool operator ==(Object other) => other is Interrupt;

  @override
  int get hashCode => (Interrupt).hashCode;

  @override
  String toString() => 'Interrupt';
}

/// An app's own message: from [Term.post], [Term.listen], or a widget.
final class Post extends TuiEvent {
  final dynamic message;

  const Post(this.message);

  @override
  bool operator ==(Object other) => other is Post && other.message == message;

  @override
  int get hashCode => message.hashCode;

  @override
  String toString() => 'Post($message)';
}

/// A key: a printable one is its text (`KeyPress('q')`, `KeyPress('Q', shift:
/// true)`), the others have names (`KeyPress.enter`, `const KeyPress('f5')`),
/// and Ctrl and Alt combine with either (`const KeyPress('c', ctrl: true)`).
/// Reads the same whether or not the terminal speaks kitty protocol.
final class KeyPress extends TuiEvent {
  /// The text typed (one character, with what joins it), or a name: `up`,
  /// `enter`, `f5`.
  final String name;
  final bool ctrl, alt, shift;

  const KeyPress(this.name, {this.ctrl = false, this.alt = false, this.shift = false});

  static const up = KeyPress('up');
  static const down = KeyPress('down');
  static const left = KeyPress('left');
  static const right = KeyPress('right');
  static const home = KeyPress('home');
  static const end = KeyPress('end');
  static const pageUp = KeyPress('pageUp');
  static const pageDown = KeyPress('pageDown');
  static const insert = KeyPress('insert');
  static const delete = KeyPress('delete');
  static const enter = KeyPress('enter');
  static const tab = KeyPress('tab');
  static const backTab = KeyPress('tab', shift: true);
  static const backspace = KeyPress('backspace');
  static const esc = KeyPress('esc');

  /// What it types into a text input: [name] for a printable key without Ctrl
  /// or Alt, else `null`.
  String? get text => ctrl || alt || _isNamed(name) ? null : name;

  /// A name is two or more ASCII letters and digits, which no single typed
  /// character is.
  static bool _isNamed(String name) {
    if (name.length < 2) return false;
    for (var i = 0; i < name.length; i++) {
      final c = name.codeUnitAt(i) | 0x20;
      if (!((c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39))) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is KeyPress && other.name == name && other.ctrl == ctrl && other.alt == alt && other.shift == shift;

  @override
  int get hashCode => Object.hash(name, ctrl, alt, shift);

  @override
  String toString() => '${ctrl ? 'ctrl+' : ''}${alt ? 'alt+' : ''}${shift ? 'shift+' : ''}$name';
}

/// Text pasted in one piece (bracketed paste), newlines and all.
final class Paste extends TuiEvent {
  final String text;

  const Paste(this.text);

  @override
  bool operator ==(Object other) => other is Paste && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'Paste(${text.length} chars)';
}

/// What a [Pointer] event did.
enum PointerKind { press, release, drag, move, scrollUp, scrollDown }

/// A click, drag, move or wheel turn at column [x], row [y] (0-based, of the
/// app's rows). Only with `pointer: true` on [Tui.run].
final class Pointer extends TuiEvent {
  final int x, y;
  final PointerKind kind;

  /// 0 left, 1 middle, 2 right.
  final int button;
  final bool ctrl, alt, shift;

  const Pointer(this.x, this.y, this.kind, {this.button = 0, this.ctrl = false, this.alt = false, this.shift = false});

  @override
  bool operator ==(Object other) =>
      other is Pointer &&
      other.x == x &&
      other.y == y &&
      other.kind == kind &&
      other.button == button &&
      other.ctrl == ctrl &&
      other.alt == alt &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(x, y, kind, button, ctrl, alt, shift);

  @override
  String toString() => 'Pointer(${kind.name} $x,$y)';
}
