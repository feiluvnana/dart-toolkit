# Architecture

Review the structure, not the features.

Check:
- **Module boundaries:** does each lib/*.dart own one concern? Which imports cross modules, and could a module be used alone (import cost, transitive deps)? Draw the import graph and flag cycles and needless edges.
- **Shared model:** Reader/Writer/Pipe, Progress, Closeable, Origin, Key/Store and Status. Is every module using the shared types instead of its own lookalikes? Where does a module re-implement something src/ already has?
- **Layering:** public facade vs lib/src. Is anything public that should be private, or private code duplicated across modules?
- **Dependencies:** list each pub dependency with its size, its startup cost and what it is used for. Could it be dropped or replaced by 100 lines in-house, or should an in-house part become a dependency?
- **Size:** files over about 800 lines, god classes, and functions over about 80 lines. Propose splits that follow seams, not line counts.
- **Lifecycle:** one owner for signals, stdin, exit hooks and child processes. Confirm that nothing bypasses lib/src/exit.dart or terminal.dart.
- **Extensibility:** can users plug in their own Writer, Pipe, Serializer or widget without touching src? Do builder or subclass seams exist where the docs promise them?

Output: docs/ARCHITECTURE.md with the graph (text), findings and a migration order. Refactors are pure (no behaviour change), one commit each, with the full suite passing. Ask before any refactor over about 300 lines.

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
