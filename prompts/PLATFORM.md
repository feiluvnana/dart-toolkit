# Platforms and terminals

The library must work on Windows, macOS and Linux, and across terminals: Terminal.app, iTerm2, VS Code, Windows Terminal, conhost, tmux/screen, ssh, and piped or non-tty stdio.

Check per module: path handling (separators, case, reserved names, long paths, symlinks and their permissions), process spawning (PATH/PATHEXT, quoting, .cmd/.bat, tree kill, signals and their Windows equivalents), file locking and rename-over-open, line endings, encodings and console code pages, temp dirs, and the home/config/cache dirs (XDG, %APPDATA%, ~/Library).
Terminal: key decoding (VT input, Esc timing, modifiers, Kitty/CSI-u), mouse, bracketed paste, width of emoji/CJK/combining characters, NO_COLOR/TERM=dumb, size and resize, and the alt screen with restore on crash, Ctrl-C and Ctrl-Z.

Verify what this Mac can verify: pty drivers, `LANG=C`, `TERM=dumb`, a narrow width, piped stdin, and tmux. For each platform-specific finding, either fix it with a test that is skipped elsewhere, or (Windows or Linux only) write exact steps into PLAN.md §1/§2: files, code, test commands, expected output. Do not ship Windows code you cannot run. Report an OS × module matrix of ok, fixed, handed off or unknown.

## Context (same in every prompt)
- dart_toolkit, branch master: a Dart scripting toolkit. docs/VISION.md is the intended API; lib/*.dart is the public surface (lib/src is private).
- README.md has the tour; projects/rawfree/rawfree.dart is a real Tui app built on the library; docs/PLAN.md holds Windows and Linux handoffs.
- Priorities: speed (runtime, then startup) > call-site brevity = discoverability > the rest.
- Every module works alone and composes: `Reader | Pipe > Writer`, Future mirrors (no inner `await`), actions return the receiver, readings are methods, named params over chains.
- Names: short, one word when it reads one way, the same word for the same idea in every module (see docs/VISION.md §1).
- Pure Dart plus pub packages; no native code, no codegen, no sync twins. No backward compatibility: rename, merge or delete freely.
- Tui is alternate-screen only and has no colour by default (`accent:` opts in); scrollback output belongs to Console.
- Every bug fix gets a regression test. Before each commit: `dart analyze lib test projects tool` is clean and the full `dart test` passes.
- One commit per finding, message `<area>: <imperative summary>`, no trailers, never push. Do not commit prompt output files unless asked.
- Never signal pid -1 or 0, or any process you did not spawn.
- Measure speed claims with back-to-back A/B runs; this machine drifts ±80 ms.
