# Project rules (every dart-lib-* skill)

Pass this file to every subagent: the repo has no CLAUDE.md, so the review agents know these rules only from the prompt.

## The library
- dart_toolkit, branch master: a Dart scripting toolkit. docs/VISION.md is the intended API; lib/*.dart is the public surface (lib/src is private).
- README.md has the tour; projects/ holds real apps built on the library (projects/medialoader, projects/keybox; medialoader has a Tui dashboard). docs/PLAN.md holds Windows (§1) and Linux (§2) handoffs and open items (§3).
- Root docs are only README.md, CHANGELOG.md and LICENSE; everything else goes in docs/. Never write DOGFOOD.md.

## Priorities
- Speed (runtime, then startup) > call-site brevity = discoverability > the rest.
- Prefer deleting to adding: an addition must remove more call-site code than the surface it adds.

## API shape
- Every module works alone and composes: `Reader | Pipe > Writer`, Future mirrors (no inner `await`), actions return the receiver, readings are methods, named params over chains.
- Names: short, one word when it reads one way, the same word for the same idea in every module (docs/VISION.md §1).
- Type safety: no `Object`/`dynamic` params, sealed results over exceptions where callers branch, records for multi-returns.
- Pure Dart plus pub packages; no native code, no codegen, no sync twins. No backward compatibility: rename, merge or delete freely.
- Tui is alternate-screen only and has no colour by default (colour is opt-in per call); scrollback output belongs to Console.

## Gate and commits
- Gate: `dart analyze lib test projects tool` is clean and the full `dart test` passes. `dart test -P quick` (skips the `pty`, `chrome`, `slow` and `media` tags) is for the inner loop only, never the gate.
- Every bug fix gets a regression test that fails without the fix. Tests that check a process exits must spawn a child.
- One commit per finding, message `<area>: <imperative summary>`, no trailers (no Co-Authored-By), never push, never publish, never amend or rebase.
- The tree may hold another session's uncommitted work: commit with `git commit -- <paths>` (or stage hunks) so only your change goes in.
- Do not commit audit or report files (docs/AUDIT.md) unless asked.

## Safety
- Never signal pid -1 or 0, or any process you did not spawn. Run filtered tests when a test kills processes.
- Do not hammer external sites: loopback servers, at most a few real requests per pass.
- Security findings describe the class of problem; never write weaponised exploits.

## Measuring
- Measure speed claims with back-to-back A/B runs; this machine drifts ±80 ms. Quote the delta, never a standalone number.
- Prove each finding (scratch script, loopback server, pty driver, RSS/timing). Mark it Verified or Plausible; fix only Verified.
- Anything this Mac cannot verify (Windows, Linux) goes into docs/PLAN.md §1/§2 with files, code, test commands and expected output. Do not ship Windows code you cannot run.
