---
name: dart-lib-fix
description: Apply the approved findings from docs/AUDIT.md to dart_toolkit — bug fixes first, then security, platform, removals, pure refactors, ergonomic API changes, simplification and docs — one logical change per commit with analyze and the full test suite after each. Use after /dart-lib-audit once the user has decided, or with --auto for the autonomous NOBRAIN pipeline.
---

# dart-lib-fix

Applies findings the user approved in `docs/AUDIT.md`. Read [../dart-lib-audit/references/rules.md](../dart-lib-audit/references/rules.md) first; the lens checklists are in [../dart-lib-audit/references/lenses.md](../dart-lib-audit/references/lenses.md).

Args: finding ids (`B1 S3 E2`) or `approved` (default: every item the user approved in chat or marked in AUDIT.md); `--auto` for the autonomous pipeline in [references/auto.md](references/auto.md).

If there is no AUDIT.md or nothing is approved, stop and say to run `/dart-lib-audit` first. Never apply an item the user rejected or did not decide.

## Order

| # | Kind | Ids | Why here |
|---|---|---|---|
| 1 | Red gate, test infra, flakes | T*, baseline failures | every later step trusts the suite |
| 2 | Bugs, liveness, resources, speed | B* | correctness before reshaping |
| 3 | Security | S* | while the code is fresh |
| 4 | Platform (Mac-verifiable) + handoffs | P* | Windows/Linux go to docs/PLAN.md §1/§2 |
| 5 | Removals | R*, approved keep/remove verdicts | less code to refactor |
| 6 | Pure refactors | A* | structure before surface |
| 7 | API changes | E*, F* | call sites on the final structure |
| 8 | Simplification | — | `code-simplifier` on the files touched in 2–7 |
| 9 | Docs | D*, plus whatever 2–8 left stale | docs describe the final code |

Within a step: P0 first, then P1, then the rest.

## Per change (the loop)

1. Re-read the finding and the code; confirm it still applies (another session may have fixed it).
2. Bug, security or platform fix: write the regression test first and see it fail (tests that check a process exits spawn a child). Use `dart-flutter:dart-add-unit-test` conventions; helpers live in test/support.
3. Make the smallest change that fixes it. Perf fixes: back-to-back A/B before and after; the number goes in the commit message.
4. Removals: delete the member/module and every caller, test, README/VISION/CHANGELOG mention in the same commit. No deprecation shims (no backward compat).
5. Pure refactors: no behaviour change; the suite must pass untouched. Over ~300 lines: ask first (in `--auto`, do it only if it finishes within the stage).
6. API changes: the commit updates callers in projects/, tests, README and docs/VISION.md together. Recheck the line count (saved − added > 0) on the real diff.
7. Gate: `dart analyze lib test projects tool` clean and full `dart test` green. Use `dart test -P quick` or a single file while iterating, never as the gate.
8. Commit only this change's paths: `git commit -m "<area>: <imperative summary>" -- <paths>`. No trailers. Never push.
9. Mark the item in docs/AUDIT.md (`fixed <sha>` / `skipped: why`).

Limits: at most 2 attempts per fix; then revert it, mark `deferred: <what was tried>` and move on. Never leave the tree red between commits.

## Simplification (step 8)

Launch `code-simplifier:code-simplifier` (or `pr-review-toolkit:code-simplifier`) with the exact list of files changed since the start of this run (`git diff --name-only <start>..HEAD -- lib`), the rules.md text, and: "Only these files. Preserve behaviour and the public API. No new abstractions; prefer deleting." Review its diff yourself, gate, and commit per file group as `<area>: simplify …`.

## Docs (step 9)

- CHANGELOG.md `## Unreleased`: Fixed / Security / Performance / Changed / Removed lines in user terms.
- docs/VISION.md and README.md match every changed signature; the README tour still compiles.
- Doc comments on changed public members: one line, what it does and returns (`dart-flutter:dart-write-documentation`).
- Windows/Linux handoffs written into docs/PLAN.md with files, code, commands, expected output.

## Report (chat, ≤ 25 lines)

Per step: commits (range), key changes, deferred items. Then the API changes users will notice, open questions, and the commit range to review. When every item is done, tell the user AUDIT.md can be deleted (do not delete it yourself).
