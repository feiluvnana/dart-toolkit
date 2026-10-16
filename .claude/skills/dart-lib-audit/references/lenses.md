# Audit lenses

Each lens covers its whole field across all of lib/ (and projects/ and the README tour as callers). The finding format is in SKILL.md.

## TESTS: a trustworthy, fast suite
1. Coverage map: each public member and whether a test exercises it (`dart test --coverage=coverage` + `dart run coverage:format_coverage`, or grep). Rank untested members by risk.
2. Flakes: run the full suite several times (10 for a dedicated tests pass). Typical causes: shared cwd or env across test files (one VM process), RSS or timing thresholds, port reuse, real network, sleeping instead of waiting for a condition.
3. Slow tests: anything over 1 s. Make it faster or tag it (`@Tags(['slow'])`, preset `quick` in dart_test.yaml).
4. Quality: tests that pass without the fix (revert the fix and rerun), asserts on implementation details, missing negative and edge cases.
5. Infrastructure: shared helpers (loopback server, pty driver, child-process runner, temp dir) live in test/support. No test may write into the repo.
Report: coverage before/after, flake list with causes, suite time before/after.

## BUGPERF: bugs, liveness, resources, speed
- Correctness: wrong results, edge cases (empty, huge, unicode, CRLF, partial reads, redirects, timeouts), error paths that hide or misreport the cause.
- Liveness: anything that keeps the VM alive after the work is done (sockets, timers, stdin listeners, child processes, signal watchers), deadlocks, hangs on cancel, orphaned children.
- Resources: unclosed files, sockets or responses; temp files left behind (including on Ctrl-C); memory that grows with input where it should stream.
- Speed: hot loops, repeated work, needless copies, regex in loops, sync I/O on hot paths, import startup cost, isolate overhead.
- Concurrency: races between futures, re-entrancy, pause/cancel semantics on streams.
Proof: scratch script, loopback server, pty driver or RSS/timing measurement. Perf findings carry an A/B number.

## SECURITY: untrusted input
Assume a script feeds the toolkit untrusted web pages, archives, HTTP headers, file names, CLI args and terminal labels.
- Injection: shell/argv (including `--` and .cmd quoting), terminal escapes (labels, links, markdown, titles, OSC 52/8, C1), HTML/CSS selector inputs, JSON paths.
- Paths: archive traversal (`..`, absolute, symlink and hardlink members, device names), atomic-write races, symlink following in copy/move/delete, permissions on created files and temp dirs.
- Network: where `insecure:` TLS can be enabled and whether it is scoped; redirects to other hosts carrying Authorization/Cookie; decompression bombs; unbounded bodies or headers; a timeout on every stage.
- Resources: inputs causing quadratic time or unbounded memory (regex, diff, HTML, JSON depth, YAML aliases, image pixel caps, tar headers, KDF rounds).
- Secrets: tokens in logs, error messages, cache files or crash output; cache dirs that store credentials.
- Browser: Chromium flags, the temp profile and its lifetime, evaluate on attacker input.
Proof: a minimal input. Report class, impact, input.

## PLATFORM: OSes and terminals
Targets: Windows, macOS, Linux; Terminal.app, iTerm2, VS Code, Windows Terminal, conhost, tmux/screen, ssh, piped or non-tty stdio.
- Per module: path handling (separators, case, reserved names, long paths, symlinks and their permissions), process spawning (PATH/PATHEXT, quoting, .cmd/.bat, tree kill, signals and Windows equivalents), file locking and rename-over-open, line endings, encodings and code pages, temp dirs, home/config/cache dirs (XDG, %APPDATA%, ~/Library).
- Terminal: key decoding (VT input, Esc timing, modifiers, Kitty/CSI-u), mouse, bracketed paste, width of emoji/CJK/combining characters, NO_COLOR/TERM=dumb, size and resize, alt screen restored on crash, Ctrl-C and Ctrl-Z.
Verify what this Mac can: pty drivers, `LANG=C`, `TERM=dumb`, narrow width, piped stdin, tmux. Fixes get a test skipped elsewhere; Windows/Linux-only findings become docs/PLAN.md §1/§2 steps.
Report: an OS × module matrix of ok / fixed / handed off / unknown.

## ARCHITECTURE: structure, not features
- Module boundaries: does each lib/*.dart own one concern? Which imports cross modules; can a module be used alone (import cost, transitive deps)? Draw the import graph (text); flag cycles and needless edges.
- Shared model: Reader/Writer/Pipe, Progress, Closeable, Origin, Key/Store, Status. Does every module use the shared types instead of lookalikes? Where does a module re-implement something lib/src already has?
- Layering: anything public that should be private (unused or accidental exports); private code duplicated across modules.
- Dependencies: each pub dependency with size, startup cost and use. Drop, replace with ~100 lines in-house, or promote in-house code to a dependency?
- Size: files over ~800 lines, god classes, functions over ~80 lines. Propose splits along seams, not line counts.
- Lifecycle: one owner for signals, stdin, exit hooks and child processes; nothing bypasses lib/src/exit.dart or lib/src/terminal.dart.
- Extensibility: can users plug in their own Writer, Pipe, Serializer or widget without touching src? Do the promised builder/subclass seams exist?
Output when run as its own pass: docs/ARCHITECTURE.md (graph, findings, migration order). Refactors are pure; a refactor over ~300 lines needs approval.

## ERGONOMIC: shorter, safer, discoverable call sites
1. Rewrite the README tour and projects/ the way the API *should* read. Diff against today; each place the ideal does not compile is a finding.
2. Look for: required boilerplate (try/catch, close(), await chains, manual loops), params every caller passes the same way, different names for the same idea across modules, two ways to do one thing, chains that should be named params (or the reverse), nullable returns that force `!`, error messages that do not say what to do, types that leak internals.
3. Discoverability: is the feature findable from the entry point (`Http.`, `Fs.`, `Console.`, …) by autocomplete alone? Is it in the module doc comment and docs/VISION.md?
4. Type safety: see rules.md.
Each proposal: a before/after snippet and `call-site lines saved − surface added`; drop it if not positive.

## DOCS: docs match the code
1. docs/VISION.md: every API line exists in code with the same name, signature and behaviour. Doc wrong → fix the doc; code wrong → a finding (no code change in this lens).
2. Doc comments: every public member has a one-line summary of what it does and returns, plus an example where usage is not obvious. No history, incident notes or stale TODOs. `dart doc` has zero warnings.
3. README.md: the tour compiles (`dart analyze` a copy) and uses only APIs that exist; concise, tables and one-liners, module table, links to docs/VISION.md.
4. CHANGELOG.md: the current version written from git log in user terms.
Report counts of wrong facts per file and the code changes the docs suggest.

## REDUNDANCY (always on)
Dead code, unused exports, members or params no doc, project or test uses, duplicates of another way or of a plain-Dart one-liner. Say what replaces each. Removal candidates are listed for the user's decision, never deleted by the audit.
