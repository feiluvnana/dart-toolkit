/// # Tui
///
/// Full-screen and inline terminal apps: [Tui.run] takes a state, a `draw` of it built from
/// widgets ([Label], [VStack], [HStack], [Box], [Menu], [Grid], [Field], [Tabs], [Button],
/// [Clickable], [Popup], [Board], [Spin], [Scroll], [Log], [Markdown], [Picture], [Paint]) and an
/// `update` that answers every [TuiEvent]: [Start], [KeyPress], [Paste], [Pointer], [Resize],
/// [Focus], [Blur], [Suspend], [Resume], [Interrupt] and your own messages as [Post]. A cell
/// buffer is diffed so each frame writes only what changed; colour falls back from 24-bit to 256
/// to 16 to none; the terminal is put back on every way out.
///
/// {@category CLI}
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'src/keys.dart';
import 'src/terminal.dart';
export 'src/keys.dart'
    show
        Blur,
        Choice,
        Focus,
        Focusable,
        Interrupt,
        KeyPress,
        Paste,
        Pointer,
        PointerKind,
        Post,
        Resize,
        Resume,
        Start,
        Suspend,
        TuiEvent;
export 'src/terminal.dart'
    show
        BarGlyphs,
        BatchView,
        Color,
        ItemView,
        LogLevel,
        LogView,
        Marks,
        Palette,
        StringStyles,
        Style,
        Tally,
        TallyItem,
        TaskView;

import 'src/core.dart';

export 'core.dart';

part 'src/tui/app.dart';
part 'src/tui/button.dart';
part 'src/tui/canvas.dart';
part 'src/tui/controls.dart';
part 'src/tui/field.dart';
part 'src/tui/gauge.dart';
part 'src/tui/markdown.dart';
part 'src/tui/picture.dart';
part 'src/tui/scroll.dart';
part 'src/tui/style.dart';
part 'src/tui/widget.dart';
