# Tests

Make the suite trustworthy and fast.

Do this:
1. Map the coverage: list each public member and whether a test exercises it (use `dart test --coverage` or grep). Rank the untested ones by risk.
2. Find flakes: run the full suite 10 times. Record every failure and fix the cause. Typical causes: shared cwd or env across test files (one VM process), RSS or timing thresholds, port reuse, real network, and sleeping instead of waiting for a condition.
3. Find slow tests: anything over 1 s. Make it faster or move it behind a tag (`@Tags(['slow'])`) with a `dart_test.yaml` preset.
4. Quality: tests that pass without the fix (revert the fix and rerun), asserts on implementation details, and missing negative and edge cases.
5. Infrastructure: shared helpers (loopback server, pty driver, child-process runner, temp dir) in test/support. No test may write into the repo.

One commit per change. Report coverage before and after, the flake list with fixes, and the suite time before and after.

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
