# Dogfooding

Find friction by building real things on the library.

Write 5 small but real scripts in a scratch folder (projects/_dogfood/, not committed), each a task people actually automate. For example:
1. Mirror a docs site to disk with assets, resumable, with a progress bar.
2. A CLI that watches a folder, hashes new files and uploads changed ones over HTTP with retries.
3. A Tui dashboard that runs shell commands in parallel and shows live output and status.
4. Scrape a paginated listing into JSON with dedupe and a cache, then render a summary table.
5. Download a release archive, verify its checksum, unpack it and run a binary from it.

Use only dart_toolkit and dart:core. Whenever you reach for dart:io, raw streams, a try/catch, a manual loop or a workaround, log it: the task, what you wrote, what you wished you could write, and the module.
Do not write DOGFOOD.md or any other file for the log: the friction log (ranked by how often each one hit and the lines it wasted) and the scripts' line counts go in your final chat report. Fix the top 5 in lib/ (one commit each, with a test), rerun the scripts and report the line counts again.

## Context (same in every prompt)
- dart_toolkit, branch master: a Dart scripting toolkit. docs/VISION.md is the intended API; lib/*.dart is the public surface (lib/src is private).
- README.md has the tour; projects/rawfree.dart is a real Tui app built on the library; docs/PLAN.md holds Windows and Linux handoffs.
- Priorities: speed (runtime, then startup) > call-site brevity = discoverability > the rest.
- Every module works alone and composes: `Reader | Pipe > Writer`, Future mirrors (no inner `await`), actions return the receiver, readings are methods, named params over chains.
- Names: short, one word when it reads one way, the same word for the same idea in every module (see docs/VISION.md §1).
- Pure Dart plus pub packages; no native code, no codegen, no sync twins. No backward compatibility: rename, merge or delete freely.
- Tui is alternate-screen only and has no colour by default (`accent:` opts in); scrollback output belongs to Console.
- Every bug fix gets a regression test. Before each commit: `dart analyze lib test projects tool` is clean and the full `dart test` passes.
- One commit per finding, message `<area>: <imperative summary>`, no trailers, never push. Do not commit prompt output files unless asked.
- Never signal pid -1 or 0, or any process you did not spawn.
- Measure speed claims with back-to-back A/B runs; this machine drifts ±80 ms.
