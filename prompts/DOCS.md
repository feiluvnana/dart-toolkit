# Docs

Make the docs match the code, short enough to read in one sitting.

Do this:
1. docs/VISION.md: for every API line, check that the code has it with the same name, signature and behaviour. Fix the doc where the code is right; list the cases where the doc is right and the code should change (do not change code here).
2. Doc comments: every public member gets a one-line summary that says what it does and what it returns, plus an example where usage is not obvious. Remove history, incident notes and stale TODOs. Run `dart doc` and fix the warnings.
3. README.md: the tour compiles (`dart analyze` it) and uses only APIs that exist.
4. A README.md for pub.dev: what it is, install, a 20-line tour, the module table and links to docs/VISION.md. It should be concise, with tables and one-liners.
5. CHANGELOG.md for the current version, written from git log in user terms.

Docs move with the code, so commit per file. Report what was wrong (counts per file) and what code changes the docs suggest.

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
