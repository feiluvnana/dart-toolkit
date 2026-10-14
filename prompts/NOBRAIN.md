# No-brain improvement pipeline

Run the other prompts in this folder as one autonomous pipeline. Make every decision yourself and do not wait for me. I review the commits afterwards.

## Stages (in order)
| # | Prompt | Why this position | Output |
|---|---|---|---|
| 1 | TESTS.md | a trustworthy, fast suite gates every later stage | fixes + flake list |
| 2 | BUGPERF.md | correctness and liveness before anything is reshaped | fix commits |
| 3 | SECURITY.md | hardening while the code is still fresh in mind | fix commits |
| 4 | PLATFORM.md | per-OS fixes; Windows/Linux go to PLAN.md | fixes + PLAN.md steps |
| 5 | ARCHITECTURE.md | restructure before polishing the surface | ARCHITECTURE.md + pure refactors |
| 6 | ERGONOMIC.md | reshape call sites on the final structure | API commits |
| 7 | FEATURE.md | add, remove or merge on the polished base | PROPOSAL.md + the "do next" items |
| 8 | DOGFOOD.md | prove stages 5–7 with real scripts and fix the top friction | DOGFOOD.md + fixes |
| 9 | DOCS.md | docs last, so they describe the final code | doc commits |
| 10 | RELEASE.md | dry-run publish only | readiness report |

## How to run each stage
1. Read `prompts/<STAGE>.md` and follow it, with the overrides below.
2. **Override "ask me":** where a prompt says to ask before acting, decide yourself. Do S and M items, and L items only if they finish within the stage. Write the reason for each decision into the commit message.
3. **Gate:** before moving on, `dart analyze lib test projects tool` is clean and the full `dart test` passes twice in a row. If the gate fails, fix it or revert that stage's last commit, and never move on red.
4. **Stage note:** add 3–6 lines to `prompts/RUN.md` (what changed, commit range, what was deferred). Commit it with the stage.
5. Move to the next stage. Later stages may undo earlier ones when they have a reason (for example ERGONOMIC renaming a refactor from ARCHITECTURE); say so in the note.

## Budgets and stop rules
- At most ~15 commits per stage. Take the highest impact first and list the rest as deferred.
- At most 2 attempts per fix. After that, defer it with what you tried.
- Stop the whole pipeline and report if the suite cannot be made green, a change needs a new non-dev dependency, or a stage would delete a module.
- Never push, never publish, never touch git history (no amend or rebase of earlier stages).
- Do not hammer external sites. Use loopback servers; at most a few real requests per stage.

## Final report (in chat, ≤ 25 lines)
A per-stage row (commits, key changes, deferred items), the API changes users will notice, open questions for me, and the commit range to review.

## Context
Same as every prompt (see any file's Context block). In short: speed > brevity = discoverability; every module works alone and composes; short, consistent names; pure Dart, no codegen, no sync twins; no backward compat; Tui is alt-screen only and colourless by default; one commit per finding, with a test for each bug fix; no trailers.
