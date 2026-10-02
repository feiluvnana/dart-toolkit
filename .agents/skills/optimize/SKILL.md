---
name: optimize
description: Thoroughly audit and optimize dart-toolkit in every aspect (performance first, then bloat, API brevity, docs, consistency, bugs, platform parity) by running .claude/skills/optimize/procedure.md end to end. Use when the user types /optimize or asks for a full optimization or audit pass of the library. Module names after the command limit the scope, e.g. "/optimize http formats".
---

Run `.claude/skills/optimize/procedure.md` end to end. Read it in full first. It is the procedure, and its
rules (speed > brevity priority, clean cuts, one commit per item, two-strike rollback, startup
A/B, commit & push) are binding. Use the **Gemini / Antigravity** column of its tool-mapping
table.

1. **Scope.** Module names the user typed after `/optimize` limit every audit to those modules.
   With none, audit all modules.
2. **History.** Collect titles rejected in earlier runs so they aren't re-proposed:
   `git log --grep='audit record' --format=%b | grep '^REJECTED' | sed 's/^REJECTED[^:]*: //'`.
3. **Step 0** from procedure.md §2.
4. **Each audit round** follows procedure.md §3.1 exactly:
   - **Find:** spawn one read-only subagent per dimension × module group, **all in a single
     parallel call** (Round 1 = 4 dimensions × 3 groups = 12 finders; Rounds 2 and 3 = 6 each).
     Each prompt contains the dimension's "look for" text, the group's files, the §0 priority
     bar, the §3 schema and limits, the skip list, and: *"read-only: never edit files, run git,
     or write reports to disk; return the findings as your final message."*
   - **Dedupe** the returned findings yourself, by file + normalized title.
   - **Verify:** spawn two skeptic subagents per finding in one parallel call, one for the
     *real* lens and one for the *bar* lens, each told to default to reject. Keep a finding only
     if both uphold it.
   - If no subagent tool is available, do the same steps sequentially yourself. Do not skip
     the verify step: verify each finding against the code before applying it.
   - Keep reports in chat. Never write `AUDIT_*.md` or other report files.
5. **Order:** round 1 → Gate 1, then round 2 → Gate 2, then round 3 → the Round 3 hardening
   in procedure.md §8.
6. **Repeat until nothing is left.** After Gate 1, run round 1 again on HEAD (with the new
   rejections in the skip list). Stop repeating when a pass confirms nothing new, applies
   nothing, or after 3 passes. Do the same for round 2 (at most 2 passes). Round 3 runs once.
7. **Co-worker.** A Claude Code session may also be pushing. Fetch and rebase before each gate
   and each push. Never `git reset --hard` or force-push.
8. **Finish** with the in-chat summary from procedure.md §8. If context or time runs out
   mid-gate, commit what is green, push, and say which round and gate to resume from.
