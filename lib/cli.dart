/// # CLI & Terminal
///
/// `Cli` for commands, options and arguments; `Console` for logs, prompts and drawing work
/// (`task.show(title)`, `batch.show(title)`, `Console.bar`); `Style` and the `Palette` for how
/// it looks; `FakeTerminal` (`testing.dart`) to test it under `Io.scope(terminal:)`.
///
/// {@category CLI}
library;

export 'core.dart';
export 'src/cli.dart' hide ConsoleBridge;
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
