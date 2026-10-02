---
name: optimize
description: Thoroughly audit and optimize dart-toolkit in every aspect (performance first, then bloat, API brevity, docs, consistency, bugs, platform parity) by running .claude/skills/optimize/procedure.md end to end. Use when the user says /optimize or asks for a full optimization or audit pass of the library. Optional args are module names to limit scope, e.g. "/optimize http formats".
---

Run `.claude/skills/optimize/procedure.md` end to end. Read it first. It is the procedure, and its rules
(priority, clean cuts, one commit per item, two-strike rollback, startup A/B, commit & push)
are binding. These steps say how to start each round and when to stop.

1. **Scope.** Module names in the args (`$ARGUMENTS`) limit every audit to those modules. With no
   args, audit all modules.
2. **History.** Collect titles rejected in earlier runs so they aren't re-proposed:
   `git log --grep='audit record' --format=%b | grep '^REJECTED' | sed 's/^REJECTED[^:]*: //'`.
3. **Step 0** from procedure.md §2.
4. **Each audit round** runs the saved workflow (the user's `/optimize` call is the opt-in):
   `Workflow({ name: 'optimize-audit', args: { round: N, modules: [...] or omitted, skip: [history + this run's rejections] } })`.
   It returns `{ confirmed, rejected }`. Those findings have already been checked twice, but
   still open the cited lines before applying any of them. Copy `rejected` into the gate's
   audit record.
5. **Order:** round 1 → Gate 1, then round 2 → Gate 2, then round 3 → the Round 3 hardening
   in procedure.md §8.
6. **Repeat until nothing is left.** After Gate 1, run round 1 again on HEAD (with the new
   rejections in `skip`). Stop repeating when a pass confirms nothing new, applies nothing, or
   after 3 passes. Do the same for round 2 (at most 2 passes). Round 3 runs once.
7. **Finish** with the in-chat summary from procedure.md §8. If context or time runs out
   mid-gate, commit what is green, push, and say which round and gate to resume from: the
   audit-record commits plus `checkpoint-*` tags are the resume point.
