## cli / process

### Upgrading

| before | after |
|---|---|
| `Opt.number('top', abbr: 'n', description: 'How many').or(10)` | `Opt.number('top', 'How many').abbr('n').or(10)` |
| `Opt.flag('dry', abbr: 'd')` | `Opt.flag('dry').abbr('d')` |
| `Arg.text('id', description: 'The build')` | `Arg.text('id', 'The build')` |
| `CliCommand('hash', description: 'Digest files', values: …)` | `CliCommand('hash', 'Digest files', values: …)` |
| `CliCommand('go', handler: …)` (no description) | `CliCommand('go', '', handler: …)` |
| `Cli(name: 'tk', …)` in `bin/tk.dart` | `Cli(…)`: the name defaults to the script's (`tk.dart`, pub's `tk.dart-3.x.snapshot`, `tk.exe`) |
| `Io.out.writeln(x)` in a `Cli` handler, so it would not break a spinner | `print(x)` |
| `Console.select('Bump', Bump.values, display: (b) => b.name)` | `Console.select('Bump', Bump.values)`; the result is `Bump`, never `Bump?` |
| `return Lifecycle.exit('nothing found')` in an `async` handler | `throw 'nothing found'` |
| `Console.spinner('x', style: SpinnerStyle.dot)` / `Console.spin(…, style:)` | `Console.spinner('x')`: braille, or ASCII where it cannot draw |
| `spinner.info('…')` | `spinner.stop()` (silent) or `succeed`/`warn`/`fail` |
| `spinner.isSpinning`, `spinner.elapsed` | the ending line prints the elapsed time |
| `Console.clear()` | — (full-screen clearing is a TUI's job) |
| `Console.isEnabled(level)` | — (`Console.level` is still readable) |
| `ctx.command` | — |
| `CommandPipeline(['a', 'b'])` | `'a' \| 'b'` |
| a `CancelToken` + `Cancel.scope` + unawaited future to stop a server | `final s = run('server'); …; await s.kill();` |

`bin/`: tk.dart 109 → 108 lines, 18 `description:` labels gone (−280 characters); books.dart 87 → 86; keybox.dart 174 → 173.

### Removed

- `SpinnerStyle` and its six styles, and the `style:` parameters of `Console.spinner`/`Console.spin`. The
  braille frames stay, with an ASCII `- \ | /` fallback chosen privately: `TERM=linux`, a locale without
  UTF-8 (`LC_ALL`/`LC_CTYPE`/`LANG`), or a Windows console that is not Windows Terminal.
- `Spinner.info`, `Spinner.isSpinning`, `Spinner.elapsed`, `Spinner.style`.
- `Console.clear` (it also dropped the live stack without stopping its timers).
- `Console.isEnabled`, `CliContext.command` and the `CommandPipeline` constructor are private.
- `CliOption.abbr` (the field) is private; the short form is set with the `.abbr('n')` chain step.
- `test/keybox_test.dart`: its CLI test duplicated `cli_test`, its HTML test duplicated `formats_test`, and
  neither exercised `bin/keybox.dart`, whose parsing lives inside `run()`.

### Added

- `Cli(name:)` is optional and defaults to the script's file name, less `.dart`, pub's
  `.dart-<version>.snapshot`, `.dill`/`.aot`/`.jit` and `.exe`. `--completion` now emits
  `complete … tk` instead of `complete … app` when the name is left out. Checked through
  `dart run dart_toolkit:tk --completion bash` (the pub snapshot path).
- The description is the second positional on every `Opt.*`, `Arg.*` and on `CliCommand`. Dart cannot mix
  an optional positional with named parameters, so:
  - `abbr:` moved from the `Opt` factories to a chain step, `.abbr('n')`, beside `.env()`. It keeps
    `or`/`required`/`many`/`env` in any order.
  - `CliCommand`'s description is a *required* positional (it has named `values`/`commands`/`handler`).
    A command without help text writes `''`.
- `print` inside `Cli.run` is `Console.writeln`: a zone `print` override, so it lands above a live spinner
  or board instead of on its row. No new surface.
- `Console.select<T extends Object>`: an enum is shown and matched by `.name`, as `Opt.among` spells it,
  and `x ?? await Console.select(…)` infers `T`.
- `Cli.run`'s doc says `throw` is how a handler fails; `Cli.run` now passes the error itself to
  `Lifecycle.exit(e, 1)` instead of `'$e'`.
- `ShellRun.kill()` (F-7): SIGTERM to the command's tree, SIGKILL after 2 s, completes when they are
  gone. Works before the process is up, is a no-op after it ended, and ends a `.stream` without an error.
  Awaiting the run afterwards throws `CancelledException`.

### Faster

- P-PROC-1: on Windows, what a bare executable name resolves to (`which` + the `.bat`/`.cmd` decision) is
  cached until `PATH` or `PATHEXT` changes. Proxy measured on macOS (the cache is Windows-only, so not A/B'd
  on the target): one `which` costs 126–235 µs here with 24 `PATH` entries × 1 extension (200-call means for
  `no-such-tool`, `ls`, `dart`); a cache hit costs 0.02 µs. Windows multiplies the stats by `PATHEXT`
  (~12 by default), so the saving is larger there. Only hits are cached, so a tool installed mid-run is
  still found.

### Skipped

- **S-3 (process without `fs`)** — measured, not done. `process` with `fs` vs a scratch copy where
  `process` takes `String` paths and drops its `fs` import: median 521 vs 449 ms (−72 ms; 8 alternating
  rounds, mins 509 vs 440). `run('x', workdir: dir)` keeps working because `Path` is an extension type
  implementing `String`. What does not survive is `Path.run()` (`(dir / 'build.sh').run()`): an extension
  on `Path` needs `fs`, and the replacement, `run("'$script'")`, is longer and breaks on a quote in the path.
  The two routes that keep it each cost more than they save or break a rule. Moving the `Path` type into
  `core` drags `package:path` into every module (+40–80 ms, noisy, on a core-only script). Having `fs`
  import `process` to host `Path.run` breaks "a module does not import another to add one method". The
  barrel, the documented import, gains nothing either way. Revisit if `Path`'s pure members ever stop
  needing `package:path`.
- F-9 (`int.humanBytes`): left to `fs`/core. `_formatBytes` in `console.dart` is unchanged, for the
  integrator to dedupe.

### Verified from phase 2 (no change needed)

CLI-2 (memoised exit hooks), CLI-3 (`Lifecycle.exit` stops renderers, writes durably), CLI-4 (`secret`
restores echo on ^C), CLI-5 (control characters in `_paint`), CLI-6 (`UsageException.command`), CLI-7
(`--flag=` is an error), CLI-8 (fish iterates `_reachable` and offers `--help`), CLI-9 (bash `--opt=`),
CLI-10 (`--version` only at the root); PROC-6 (one-line `ShellException`), PROC-7 (PATHEXT-only for
extensionless names), PROC-8 (missing workdir), PROC-9 (`.stream` keeps stderr), PROC-10 (`inherit`
suspends the live region), PROC-11 (`args:` + `shell: true` refused on Windows). All are in the code with
tests.

### CONVENTIONS

- In "A name is written once": the declaration example becomes `Opt.number('top', 'How many to show').or(10)`.
  Add: **the help text is the second positional, and every other property is a chain step (`.abbr`,
  `.env`, `.or`)**. *Why:* Dart cannot mix an optional positional with named parameters, and tk.dart wrote
  `description:` 13 times.
- In "A builder only where the order means something": `CliCommand(name, description, values:, commands:,
  handler:)`.
- "Opened once, at the top" gains: **inside `Cli.run`, `print` is a durable write.** *Why:* README's
  `print(...)` examples broke a running spinner.
