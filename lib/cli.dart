/// # CLI & Terminal
///
/// `Cli` for commands, options and arguments; `Console` for logs, prompts and drawing work
/// (`task.show(title)`, `batch.show(title)`, `Console.bar`); `Style` and the `Palette` for how
/// it looks; `FakeTerminal` (`testing.dart`) to test it under `Io.scope(terminal:)`.
///
/// {@category CLI}
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'src/terminal.dart';
export 'src/terminal.dart'
    show
        BarGlyphs,
        BatchView,
        Char,
        Color,
        ItemView,
        KeyPress,
        LogLevel,
        LogView,
        Marks,
        Mouse,
        MouseKind,
        Palette,
        Paste,
        Resize,
        StringStyles,
        Style,
        Tally,
        TallyItem,
        TaskView,
        TuiEvent;

import 'src/core.dart';

export 'core.dart';

part 'src/cli/command.dart';
part 'src/cli/completion.dart';
part 'src/cli/console.dart';
part 'src/cli/lifecycle.dart';
part 'src/cli/pick.dart';
