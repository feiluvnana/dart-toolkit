# Ergonomics

Make the API shorter to call, harder to misuse and easier to discover, without losing power.

Do this:
1. Rewrite the README tour and projects/ the way the API *should* read. Diff it against today; each place where the ideal does not compile yet is a finding.
2. Look for: required boilerplate (try/catch, close(), await chains, manual loops), parameters every caller passes the same way, names that differ for the same idea across modules, two ways to do one thing, chains that should be named params (or the reverse), nullable returns that force `!`, error messages that do not say what to do, and types that leak internals.
3. Discoverability: can a user find the feature from the entry point (`Http.`, `Fs.`, `Console.`, ...) with autocomplete alone? Is it in the module's doc comment and in docs/VISION.md?
4. Type safety: no `Object`/`dynamic` params, sealed results over exceptions where callers branch, records for multi-returns.

Each proposal gets a before/after snippet and a count of call-site lines saved over the surface added; drop it if the count is not positive. Apply the accepted ones as one commit per change, updating callers, tests, README and VISION in the same commit. Report a table of change, lines saved, commit.

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
