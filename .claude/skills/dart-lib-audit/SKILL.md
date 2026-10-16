---
name: dart-lib-audit
description: Whole-library audit of dart_toolkit (all of lib/, not a diff) for bugs, liveness, security, platform, architecture, API ergonomics, redundancy, test and doc gaps. Writes a ranked docs/AUDIT.md and stops for the user's decisions before any edit. Use when asked to audit, review or optimize the library, or as the first step before /dart-lib-fix.
---

# dart-lib-audit

Read-only audit of the whole library. Output: `docs/AUDIT.md` (uncommitted) and a short chat summary. **No edits to lib/, test/ or docs other than AUDIT.md.**

Args (optional): module names (`http html archive …`) to narrow the scope; lens names (`bugperf security platform architecture ergonomic tests docs dogfood`) to narrow the lenses; `--auto` to continue straight into `/dart-lib-fix --auto` instead of stopping. Default: every module, every lens except `dogfood`.

First read [references/rules.md](references/rules.md) (the project rules) and [references/lenses.md](references/lenses.md) (what each lens checks). `dogfood` is in [references/dogfood.md](references/dogfood.md).

## 1. Baseline

Record, do not fix:

```sh
git rev-parse --short HEAD; git status --short | wc -l
dart analyze lib test projects tool
dart test            # full suite; note count, time, failures
```

- A dirty tree is normal (other sessions work here). Note it; never stash, reset or commit it.
- Ask the other sessions first: `ListAgents`, then `SendMessage` each peer session in this repo, asking what it is editing. Mark the findings in its files "in progress elsewhere" instead of reporting them as yours.
- The tree can move during the audit. Rerun analyze and the full suite just before writing AUDIT.md; if HEAD changed, say so and use the final numbers.
- If analyze or test is red, record each failure as a P0/P1 finding and continue the audit. Rerun a failing test alone once to tell a flake from a break.
- Also note: `wc -l lib/*.dart lib/src/**/*.dart` for size, and the public library list (`ls lib/*.dart`).

## 2. Map the surface

Before reviewing, build the module list the agents will share:
- For each lib/<module>.dart: its exports, the lib/src files behind it, its tests, and its callers in projects/ and README.md.
- Read docs/VISION.md §1 (naming) and the README tour, so findings can be judged against the intended API.

## 3. Review (agents, scoped to the whole of lib/)

The pr-review-toolkit agents default to `git diff`. Every prompt below must say so explicitly:

> Review the WHOLE of `lib/` (every file under lib/ and lib/src/), not the git diff and not recent changes. Ignore git status. Project rules (there is no CLAUDE.md): <paste references/rules.md>. Lens checklist: <paste the lens section>. Report each finding as: id, file:line, problem in one line, evidence (how you proved it, or "Plausible"), suggested fix, severity guess. Do not edit, create or delete any file in the repo: scratch scripts go only under <session scratchpad>/<lens>/, with a scratch pubspec that path-depends on the repo. Use loopback only; never signal a process you did not spawn. At most 15 findings, most severe first.

Launch in one message, in parallel (split lib/ by module group if a run would exceed one agent's reach: e.g. net = http/html/chrome/cookies, files = fs/archive/hash/zip/7z/rar, term = console/tui/terminal/cli, rest = core/json/yaml/csv/pool/shell/image/video):

| Agent | Lens |
|---|---|
| `pr-review-toolkit:silent-failure-hunter` | BUGPERF error paths, swallowed errors, fallbacks |
| `pr-review-toolkit:code-reviewer` | BUGPERF correctness + rules.md compliance |
| `pr-review-toolkit:type-design-analyzer` | ERGONOMIC type safety, ARCHITECTURE shared model |
| `pr-review-toolkit:pr-test-analyzer` | TESTS coverage gaps and test quality (whole test/ vs whole lib/) |
| `pr-review-toolkit:comment-analyzer` | DOCS doc comments vs code |
| `general-purpose` | SECURITY lens |
| `general-purpose` | PLATFORM + ARCHITECTURE lenses (import graph, sizes, lifecycle owners) |
| `general-purpose` | ERGONOMIC + REDUNDANCY (unused exports, dead code, duplicates; VISION.md vs code) |

Do the things agents cannot do well yourself: liveness and speed probes (scratch scripts in the session scratchpad, loopback servers, pty drivers, A/B timings), `dart doc` warning count, `dart test --coverage` if the TESTS lens is on.

## 4. Verify

Agents over-report. For every finding before it goes in AUDIT.md:
- Open the file:line and confirm the code says what the agent claims.
- Upgrade to **Verified** only with proof (a scratch script output, a failing test sketch, a measurement). Otherwise **Plausible**. Drop what is wrong.
- Merge duplicates found by several agents; keep the best evidence.
- Check each against rules.md: a "fix" that adds a sync twin, codegen, a dependency, `Object` params, or surface with no call-site saving is not a fix.

## 5. Write docs/AUDIT.md

Overwrite any previous AUDIT.md (read it first; carry over still-open undecided items and say so). Keep it under ~300 lines: tables and one-liners.

```md
# AUDIT <date> (<HEAD short sha>, <n> uncommitted files)

## Baseline
analyze: <clean | n issues>; test: <passed/total> in <s>; failures: <list or none>

## Findings
| ID | P | Lens | file:line | Problem | Evidence | Fix | Effort |
|---|---|---|---|---|---|---|---|
| B1 | P0 | bugperf | lib/src/x.dart:120 | … | Verified: <how> | … | S |

## Systemic patterns
- <pattern>: <where it recurs (ids)>, <one fix for all>

## Keep / remove candidates
| Feature | Users (projects, README, tests) | Replacement | Verdict |
|---|---|---|---|

## Handoffs
- <Windows/Linux items for docs/PLAN.md, with ids>

## Decisions needed
1. <question> (ids) — recommended: <answer>
```

Ranking:
- **P0**: wrong results, data loss, hang/VM kept alive, security hole, red gate.
- **P1**: broken edge cases, resource leaks, Verified perf wins ≥ 2×, misleading errors.
- **P2**: API ergonomics with positive line count, redundancy, test gaps on risky code, doc drift.
- **P3**: style, naming nits.
- A Plausible finding ranks one level below what it would be if Verified. A deterministic code read (a fallback path, a missing check) counts as Verified.
- Timing a child through a shell pipeline (`sleep 8 | ./x`) measures the pipeline. Time the process alone (`/usr/bin/time ./x < fifo`).
- Effort S (< 1 h), M (a session), L (needs its own plan).
- IDs by lens: B bugperf, S security, P platform, A architecture, E ergonomic, R redundancy, T tests, D docs, F dogfood.

## 6. Stop

Report in chat (≤ 20 lines): baseline, counts per priority, the top 5 findings, systemic patterns, and the "Decisions needed" list. **Stop and wait** for the user to approve, reject or reprioritise. Approved items are applied with `/dart-lib-fix`.

With `--auto`: do not stop; decide each "Decisions needed" item yourself (recommendation wins, never delete a module) and continue with `/dart-lib-fix --auto`.
