---
name: dart-lib-feature
description: Decide and build what dart_toolkit should do — review missing, redundant and candidate modules against real scripting work, then add an approved feature through feature-dev following the library's API conventions, with regression tests, CHANGELOG, README and VISION updates. Use when asked to add, remove or merge a feature or module, or to review the library's feature set.
---

# dart-lib-feature

Two modes:
- `/dart-lib-feature review` — decide what the library should DO (no code). Code quality, bugs and naming are out of scope.
- `/dart-lib-feature <description>` — build one approved feature.

Read [../dart-lib-audit/references/rules.md](../dart-lib-audit/references/rules.md) first. The core rule: **prefer deleting to adding; an addition must remove more call-site code than the surface it adds.**

## Review mode

Judge against real scripting work (scraping, downloading, file and archive chores, CLI tools, terminal UIs, automation) and the libraries in [references/candidates.md](references/candidates.md).

Each item needs evidence: a call site in projects/ or the README tour, or a 5–15 line "today vs proposed" snippet you actually ran.
1. **Missing:** tasks a script often needs that take more than 5 lines today or cannot be done. Rank by how often a real script hits them.
2. **Redundant:** members, params or modules that duplicate another way, that no project, doc or test uses, or that a plain-Dart one-liner covers. Say what replaces each.
3. **Modules:** merge, split, remove or add? Judge the candidates in candidates.md rather than assuming them: use case, a rough 3-line API, cost (deps, startup ms, lines), verdict.
4. **Gaps between modules:** compositions that should be one pipe (`Reader | Pipe > Writer`) but are not.
5. **Defaults:** default values that are wrong for most scripts.

Output: docs/PROPOSAL.md (create it, or update it if one exists; it is deleted once its items are done), tables and one-liners, ≤ ~300 lines, ending with a "do next" list of 10 items tagged Add/Remove/Merge/Change and effort S/M/L. **Stop** and ask before writing any code into lib/. Removing a module is always the user's call.

## Build mode

1. Confirm the feature is approved (in chat, PROPOSAL.md or AUDIT.md). If not, write its before/after snippet and line count and ask.
2. Run `feature-dev:feature-dev` with the description and the rules.md text, and add to it:
   - Explore with `feature-dev:code-explorer` on the module(s) it touches and on the shared model (lib/core.dart: Reader/Writer/Pipe, Progress, Closeable, Origin, Key/Store, Status). Reuse those types; never add a lookalike.
   - Architect with `feature-dev:code-architect` under these constraints: one behaviour per method; named params over chains; Future mirrors so callers chain without inner `await`; actions return the receiver; short names consistent with docs/VISION.md §1; sealed results where callers branch; no `Object`/`dynamic` params; no sync twin; no codegen; no new non-dev dependency without asking.
   - Pick the smallest surface: a param on an existing method beats a new method; a new method beats a new class; a new module needs its own approval.
3. Implement with tests first (`dart-flutter:dart-add-unit-test`; loopback servers and pty helpers in test/support; tag slow ones `slow`). Speed-sensitive paths get a back-to-back A/B number.
4. Update in the same commit: callers in projects/ that get shorter, README.md (module table/tour if it belongs there), docs/VISION.md, and CHANGELOG.md `## Unreleased` (Added/Changed/Removed, user terms).
5. Review with `feature-dev:code-reviewer` on the changed files; fix what holds up.
6. Gate: `dart analyze lib test projects tool` clean, full `dart test` green. Commit `<area>: <imperative summary>` with only this feature's paths, no trailers, no push.

Report: the feature's API (3–5 lines), call-site lines saved vs surface added, tests added, commit sha.
