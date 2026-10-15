# Security

Assume a script feeds the toolkit untrusted input: web pages, archives, HTTP headers, file names, CLI args and terminal labels.

Review:
- **Injection:** shell/argv (including `--` and .cmd quoting), terminal escape injection (labels, links, markdown, titles, OSC 52/8), HTML/CSS selector inputs, and JSON paths.
- **Paths:** archive traversal (`..`, absolute paths, symlink and hardlink members, device names), atomic-write races, symlink following in copy, move and delete, and permissions on created files and temp dirs.
- **Network:** where `insecure:` TLS can be enabled and whether it is scoped; redirects to other hosts carrying headers (Authorization, Cookie); decompression bombs; unbounded bodies or headers; and timeouts on every stage.
- **Resources:** inputs that cause quadratic time or unbounded memory (regex, diff, HTML, JSON depth, image pixel caps, tar headers).
- **Secrets:** tokens in logs, error messages, cache files or the crash output; cache directories that store credentials.
- **Browser:** Chromium flags, the temp profile and its lifetime, and pages that run evaluate on attacker input.

Prove each finding with a minimal input. Fix with a regression test, one commit each. Report a table of ID, class, impact, input, fix. Describe the class of problem; do not write weaponised exploits.

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
