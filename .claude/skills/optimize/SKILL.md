---
name: optimize
description: Thoroughly audit and optimize dart-toolkit in every aspect (performance first, then bloat, API brevity, docs, consistency, bugs, platform parity) in three gated rounds. Use when the user types /optimize or asks for a full optimization or audit pass of the library. Module names after the command limit the scope, e.g. "/optimize http formats"; "--auto" runs without checkpoints.
---

# /optimize

A three-round audit → fix → verify pass over dart-toolkit. You are the **lead**. You spawn
read-only subagents to find and check problems, you apply the accepted fixes yourself, and you
gate every round on the release checks. Where this skill and `CONVENTIONS.md` disagree,
`CONVENTIONS.md` wins.

This file is a runbook. Do the steps in order, use the commands and templates as written, and
when a step says *stop*, end your turn. If something happens that no step covers, stop and ask
the user rather than improvising.

> The Antigravity copy (`.agents/skills/optimize/SKILL.md`) is the same skill apart from **Arguments** and **Tools**. Change both together.

**Arguments** (`$ARGUMENTS`): module names limit the scope (with none, every module is audited); `--auto` skips the checkpoints (§0).

## Tools

| Need | Use |
|---|---|
| Subagent | `Agent` with `subagent_type: "Explore"` (read-only). Launch every agent of one step in **one message** so they run concurrently. |
| Code search | `git grep -n` / Grep before any Read |
| Reading code | `Read` with `offset`/`limit` (≤80 lines) |
| Edits | `Edit` |

Only the lead edits. Subagents never edit files, run git, or write reports to disk: their final
message is the report. Never read a whole file when a line range will do. If one step needs more
than 20 subagents, launch them in waves of 20 and wait for each wave.

## Map of a run

```
Step 0  baseline ............................................ ⏸
Round 1 (PERF BLOAT FEAT DOC)  pass: audit ⏸ → implement ⏸   up to 3 passes
Round 2 (DISC CONS)            pass: audit ⏸ → implement ⏸   up to 2 passes
Round 3 (BUG ×2)               pass: audit ⏸ → implement ⏸   1 pass
Finish
```

A **pass** is one audit (§4) followed by one implementation (§5). A round repeats its pass on
the new HEAD until a pass confirms nothing new, applies nothing, or reaches its limit. Then the
next round starts.

## 0. Ground rules

| Rule | What it means |
|---|---|
| **Checkpoints** | Unless `--auto` was passed, **stop and wait for the user** after every step marked ⏸: print the checkpoint report from its template, then end your turn. Continue only on the user's reply (§7). The user may add items rejected earlier: they override a skeptic's verdict. With `--auto`, print the same report and carry on as if the reply were *go*. The stops in §8 apply in both modes. |
| **Priority** | `CONVENTIONS.md` order: **speed > call-site brevity > everything else**. Speed means measured startup, throughput or memory (§2.1). A shorter spelling that costs measurable time loses. Pruning counts as brevity. An addition must delete more at call sites than it adds to the surface, and must cost no measurable startup. Speculative features are rejected. |
| **Clean cuts** | No `@Deprecated`, shims or aliases. A rename or removal updates every call site in `lib/ bin/ tool/ test/` and every doc in the same commit. |
| **Reports stay in chat** | No `AUDIT_*.md` or other report files. The decision record (accepted, and rejected with reasons) goes into the gate's audit-record commit body, changes go into `CHANGELOG.md` (Unreleased), and new rules go into `CONVENTIONS.md` with their *why*. |
| **`bin/` is examples** | Smoke-test `bin/*.dart`; delete or merge duplicates freely. |
| **One item, one commit** | Apply one accepted item (or one tightly coupled micro-batch), verify, commit locally. A rollback only ever touches the uncommitted item. |
| **Commit & push** | Commit as the configured git user (`feiluvnana`), with **no `Co-Authored-By` trailer**. Push only at the end of each gate (§5.4). Never bump the `pubspec.yaml` version or rename CHANGELOG `Unreleased`: the owner picks the version. |
| **Co-worker** | Another agent may push to `master`. Before each gate and each push, run `git fetch && git status -sb`; if `origin/master` moved, follow §5.4. Never `reset --hard` or force-push. |
| **Skip list** | Findings rejected in earlier runs, one `title: reason` per line: `git log --grep='audit record' --format=%b \| grep '^REJECTED' \| sed 's/^REJECTED[^:]*: //'`. Add this run's rejections as you go. A finder must not re-propose a skip-listed title unless the user asks for it. Titles never contain `:`, so the title is everything before the first `: `. |

## 1. What you keep track of

Keep this state in your own context for the whole run, and print it whenever a checkpoint asks.

| State | Content |
|---|---|
| **Scope** | The modules from the arguments, or all twelve: core, collection, async, process, native, hash, formats, fs, http, cli, tui, chrome. |
| **Known failures** | The test names that already failed at Step 0, verbatim. |
| **Skip list** | Earlier runs' rejections plus this run's. |
| **Ledger** | One row per finding: `ID · TAG · Title · path:line · status · commit`. The ID is `R<round>P<pass>-<nn>` (`R1P2-04`). The status moves `found → confirmed → accepted → applied`, or ends at `rejected (<reason>)`. A `DOC` finding whose *code* is wrong becomes `deferred (R3)`: it is pasted into every Round 3 finder prompt and audited there as a `BUG`. In Round 3, `BUG` rows also note their lens: `BUG (cancel)` or `BUG (platform)`. |
| **Checkpoint tag** | The last `checkpoint-*` tag: the base for A/B and for `git log checkpoint-<prev>..`. |

## 2. Verification

| Name | Command | Run it |
|---|---|---|
| **fast** | `dart analyze --fatal-infos && dart test <the item's test files>` | after every item, before its commit |
| **gate** | `make check test`, then **smoke** | Step 0, and closing every pass |
| **smoke** | `for b in tk books keybox; do dart run bin/$b.dart --help >/dev/null \|\| echo FAIL $b; done` | gate, and after any `cli`/`tui`/`bin/` item |
| **native** | `cargo check --manifest-path native/Cargo.toml && make native && dart test test/native_test.dart test/hash_test.dart test/archive_test.dart` | any `native/src/` change |
| **startup A/B** | §2.1 | any `lib/` change that adds an `import` or a top-level initializer, and on every touched module when closing a pass |

`make check` is analyze plus the format check; `make test` is the full suite. Before **fast**,
format what you touched: `dart format <files>`.

**The item's test files**, by module touched (take the union):

| Module | Test files |
|---|---|
| core | `core_test` |
| collection | `collection_test` |
| async | `async_test` |
| process | `process_test` |
| native, hash | `native_test`, `hash_test`, `archive_test` |
| formats | `formats_test`, `formats_diff_test` |
| fs | `fs_test`, `archive_test` |
| http | `http_test` (uses `client_conformance.dart`, `mock_client.dart`) |
| cli | `cli_test`, plus **smoke** |
| tui | `tui_test`, plus **smoke** |
| chrome | `chrome_test` (skips itself when no Chrome is installed; say so if it skipped) |
| any public API change | add `api_ergonomics_test` |

All live in `test/` as `test/<name>.dart`.

### 2.1 Startup A/B (never a standalone number)

Single-run startup drifts by ±80 ms, so a one-off `make bench` proves nothing. Compare
back to back against the last checkpoint:

```bash
git worktree add -f ../tk-base checkpoint-<prev> && (cd ../tk-base && dart pub get >/dev/null)
for i in 1 2; do (cd ../tk-base && dart run tool/bench.dart <modules> -r 8); dart run tool/bench.dart <modules> -r 8; done
git worktree remove --force ../tk-base
```

Read the **`min over`** column (the minimum over bare). A module regresses if HEAD is more than 10 ms worse than the
base in **both** pairs; then §8 applies. Quote deltas as `base → head` (`http 112 → 98 ms`).
A throughput change needs its own microbenchmark (MB/s or ms/op, base vs head in the same run)
in the commit body: write it as a throwaway script in the scratchpad, never in the repo. Under
5 % gain plus more code means **reject**.

### 2.2 Two-strike rollback

When an item fails **fast**, read the failure and make **one** corrective attempt. If it still
fails, discard only that item:

```bash
git restore --staged --worktree -- . && git clean -fd -- lib bin tool test native
```

This is safe because every earlier item is committed. Mark it `rejected (compile)` or
`rejected (test)` in the ledger with the first error line as the reason, and move to the next
item. Never leave a red tree between items.

### 2.3 Native ABI lockstep

Changing an `extern "C"` signature bumps both `tk_version()` in `native/src/lib.rs` and
`NativeLib._abi` in `lib/src/native/native.dart`. `native/prebuilt/` is gitignored, so run
`make native` for the host before testing, and add a CHANGELOG line saying the release must run
`make native-all`.

## 3. Step 0: Baseline

1. `git fetch && git status -sb`. The tree must be clean and `master` must equal
   `origin/master`. Otherwise **stop** and ask (§8), even with `--auto`.
2. Build the skip list (§0) and the scope (§1).
3. Run **gate**. Copy every failing test name verbatim into *known failures*. A later gate passes
   if it fails on no other test. If analyze or the format check fails, fix it first as its own
   commit (`style: …` for format, `fix: …` for analyze) and re-run **gate**.
4. If `native/prebuilt/<os>_<arch>/` (e.g. `macos_arm64`) is missing or older than any file in `native/src/`, run
   **native**. If `cargo` is missing, note it: every item touching `native/src/` will be
   `rejected (env)`.
5. `git tag -f checkpoint-step0` (local only; tags are never pushed).
6. ⏸ **Checkpoint**, using this template:

   ```markdown
   ### /optimize · Step 0 · baseline
   - Scope: <modules>    Mode: checkpoints | --auto
   - Gate: green | <n> known failures: `<test name>`, …
   - Native: up to date | rebuilt | cargo missing
   - Baseline commits: none | `<sha> <subject>`
   - Skip list: <n> titles from earlier runs
   Next: Round 1 · pass 1 · audit (PERF, BLOAT, FEAT, DOC × <groups>).
   Reply: go · stop
   ```

## 4. Audit (the first half of every pass)

### 4.1 Find

Spawn one **finder** per *dimension × module group*, all in one message. Which dimensions a
round audits is in §6. Round 3 has two dimensions that share the tag `BUG`: each finder gets
one of the two `BUG` blocks in §10, so Round 3 runs two finders per group.

| Group | Modules | Files |
|---|---|---|
| `foundation` | core, collection, async, process, native, hash | per module `m`: `lib/<m>.dart`, `lib/src/<m>/`, `test/<m>_test.dart`; native adds `native/src/*.rs` |
| `data` | formats, fs, http | same pattern |
| `surface` | cli, tui, chrome | same pattern, plus `bin/` |

Drop out-of-scope modules, then drop empty groups. `DOC` finders also get `README.md`,
`GUIDE.md`, `CONVENTIONS.md` and `CHANGELOG.md` (the Unreleased section). Fill in this prompt;
everything in `<…>` is replaced, nothing else changes:

````markdown
You are a read-only finder auditing dart-toolkit, a dependency-free Dart 3 scripting library,
in the current working directory. Dimension: <TAG> (<dimension title>). Module group: <group>.

Files in scope:
<one path per line>

Rules:
- Read-only. Do not edit or create files, and do not run dart, make, cargo or any git command
  that changes state. You may run `git grep`, `git log`, `git show` and read files.
- Search with `git grep -n` before reading. Read at most 80 lines at a time.
- Every item cites a `path:line-line` range that you opened yourself in this session.
- At most 10 items, each High or Medium (definitions below). Do not report Low items.
- Do not report anything on the skip list below, or anything matching the dimension's
  "Not a finding" list.
- If nothing clears the bar, reply exactly `NO_ACTIONABLE_ITEMS` and nothing else.

Priority bar: speed > call-site brevity > everything else. Speed means measured startup,
throughput or memory. A shorter spelling that costs measurable time loses. Pruning counts as
brevity. An addition must delete more at call sites than it adds to the surface, and must cost no
measurable startup. Speculative features are rejected.

Severity:
- High: a startup or hot-path cost with a named mechanism; a public symbol that can be deleted;
  a doc that tells users to write code that does not compile; a crash, hang, leak or wrong result.
- Medium: anything else that clears the bar.

Titles are imperative and never contain `:`.

Dimension:
<the dimension's whole block from §10: Hunt, Evidence, Not a finding, Fix>

Skip list (`title: reason`, rejected before; do not re-propose these titles):
<one per line, or "(empty)">

Carried over from earlier rounds (Round 3 only; check these first and report each that is still true):
<the ledger's `deferred (R3)` items verbatim, or "(none)">

Reply with the list only, no preamble and no summary, in exactly this format:

- **[<TAG>] Title in imperative form** (`path:12-34`), High | Medium
  - Problem: 1–2 sentences about the current code.
  - Fix: the minimal diff, or "delete X; callers use Y".
  - Evidence: what the dimension's Evidence asks for.
  - Blast radius: every file the fix touches, from `git grep`.
````

When the finders return:
- An item with no `path:line` citation is dropped.
- A reply that ignores the format is re-sent once with the line "Reply in the format only."
  appended. A second bad reply counts as `NO_ACTIONABLE_ITEMS`.
- Give each surviving item a ledger ID and the status `found`.

### 4.2 Dedupe

Two items are duplicates when they cite the same file with overlapping line ranges, or their
titles match after lower-casing and removing punctuation. Merge them: keep the item with the
stronger Evidence, take the union of the blast radius, and keep the lower ID.

### 4.3 Verify

For every finding, spawn two **skeptics**, all in one message. Each defaults to *reject* when
unsure.

````markdown
You are the REAL skeptic for one audit finding on dart-toolkit, in the current working
directory. Read-only: same rules as an auditor (no edits, no state-changing commands; `git grep`
before reading; at most 80 lines at a time). When unsure, REJECT.

Finding:
<the item, verbatim>

Do:
1. Open the cited lines. Does the current code say what "Problem" claims?
2. `git grep -n` every symbol the Fix touches, across lib/ bin/ tool/ test/ and *.md. List the callers.
3. Would the Fix compile and keep every caller, test and doc working once they are updated?

Reply in exactly these lines:
VERDICT: UPHOLD | REJECT
REASON: one sentence, citing path:line.
CALLERS: comma-separated files (only with UPHOLD).
````

````markdown
You are the BAR skeptic for one audit finding on dart-toolkit, in the current working
directory. Read-only: same rules as an auditor. When unsure, REJECT.

Priority bar: <the same text as in the finder prompt>

Dimension:
<the dimension's Evidence and Not a finding parts from §10>

Finding:
<the item, verbatim>

Answer each:
1. Does it carry the Evidence its dimension asks for: numbers or a named mechanism, grep
   counts, a before/after call site, or a reproducible scenario?
2. Does it match any "Not a finding" entry?
3. Does what it adds already exist under another name? Check with `git grep`.
4. If it adds API: does it delete more at call sites than it adds to the surface?

Reply in exactly these lines:
VERDICT: UPHOLD | REJECT
REASON: one sentence naming the question that decided it.
````

A finding is `confirmed` only if **both** skeptics reply UPHOLD. Otherwise it is
`rejected (real)` or `rejected (bar)` with the skeptic's REASON. A reply without a `VERDICT:`
line is re-sent once, then counts as REJECT (`rejected (malformed)`).

### 4.4 Rank and propose

Then open every confirmed finding's lines yourself (subagents misread code). Mark anything that
breaks a `CONVENTIONS.md` rule `rejected (lead)` with the rule named. Sort the rest:
1. `PERF` with measured numbers, then `PERF` with a named mechanism;
2. `BUG` High, then `BUG` Medium;
3. `BLOAT`, by net lines deleted;
4. `FEAT`, `DISC`, `CONS`, by call-site tokens saved;
5. `DOC`.

Within a group, High comes before Medium. Propose the top items up to the round's cap (§6).

### 4.5 ⏸ Checkpoint: audit

```markdown
### /optimize · Round <r> · pass <p> · audit
<n> confirmed · <m> rejected · <k> finders said NO_ACTIONABLE_ITEMS

| # | ID | Tag | Title | Where | Evidence | Files |
|---|---|---|---|---|---|---|
| 1 | R1P1-03 | PERF | … | `lib/src/…:12-34` | 165 → 25 ms (mechanism) | 3 |

**Proposed for this pass (cap <c>):** 1, 2, 4, …
**Not proposed (over the cap):** 9, 10

**Rejected**
- R1P1-05 (bar): <title>: <reason>

Reply: go · drop 2,4 · add 9 · add R1P1-05 · redo <note> · stop
```

If no finding was confirmed, say so in this report and, on *go*, end the round (§6) without an
implementation pass.

## 5. Implementation (the second half of every pass)

Apply the approved items in three batches, in this order. Inside a batch, keep the rank order.

| Batch | Items | Commit prefix |
|---|---|---|
| **A: deletions** | `BLOAT`, doc deletions | `refactor: …` |
| **B: speed** | `PERF` | `perf: …` |
| **C: additions and corrections** | `FEAT`, `DOC` corrections, `DISC`, `CONS`, `BUG` | `feat:`, `docs:`, `refactor:`, `fix:` (see §6) |

### 5.1 One item

1. **Re-locate.** Open the cited lines yourself. If earlier items moved the code, find it
   with `git grep`. If the problem is gone, mark the item `rejected (stale)` and skip it.
2. **Blast radius.** `git grep -n -w <symbol> -- lib bin tool test '*.md'` for every symbol the
   item renames, removes or changes. Each hit is a file you will touch.
3. **Change the code** in `lib/` (and `native/src/`), with the smallest diff that does the Fix.
4. **Update every hit** from step 2 in `bin/`, `tool/` and `test/`.
5. **Tests.**
   - A deletion or rename: the existing tests, updated. Add nothing.
   - A speed change: the existing tests must pass unchanged. That shows behaviour didn't move.
   - New API: a test for each case that applies: happy path; edge (empty, boundary, unicode);
     failure (the exception or `Left` it documents); cancellation under `Cancel.scope` if it is
     async; differential against the reference if it replaces an engine
     (`formats_diff_test.dart`).
   - A bug fix: a test that fails before the fix and passes after it. Check it fails first.
   - Tests go in the module's existing `test/<module>_test.dart`, never in a new file.
6. **Docs move with code.** A public API change updates, in the same commit:
   - `README.md` and `GUIDE.md`: every snippet that uses the changed name.
   - `CHANGELOG.md`, under `## Unreleased`: this run's `### <title>` heading. The first item
     of the run that touches the changelog adds that heading above the earlier ones, named for
     the run (as `### Audit IV` was). Under it, use `#### Upgrading` (a `Before | After` table
     row for anything a caller must change), `#### Added`, `#### Removed`, `#### Fixed`,
     `#### Faster` (with `base → head`) or `#### Smaller`. One row or one bullet per item.
   - `CONVENTIONS.md`: only for a new rule, with its `> *Why:*` line naming what this item found.
   - Dartdoc: per CONVENTIONS §8, a comment says what the signature cannot.
7. **Format and verify.** `dart format <touched .dart files>`, then **fast** with the item's
   test files (§2), plus **native** for a `native/src/` change, **smoke** for `cli`/`tui`/`bin/`,
   and **startup A/B** (§2.1) if the item adds an import or top-level initializer. Failure
   follows §2.2.
8. **Commit.**

   ```bash
   git add -A -- lib bin tool test native README.md GUIDE.md CHANGELOG.md CONVENTIONS.md
   git commit -F- <<'MSG'
   <prefix>: <what changed, imperative, ≤ 72 chars>

   <The problem, one sentence. What changed, one or two sentences.>
   <perf only: base → head numbers and the command that produced them.>
   <unverified-on-windows, if it applies.>

   Audit: <ID> [<TAG>]
   MSG
   ```

   Then mark the item `applied` with the short SHA.

### 5.2 Close the pass

1. `git fetch && git status -sb`. If `origin/master` moved, follow §5.4 first.
2. Run **gate**. If a test outside *known failures* fails, follow §8.
3. Run **startup A/B** (§2.1) on every module the pass touched. A regression follows §8.
4. Write the audit record. It is an empty commit whose body lists every ledger row from this pass:

   ```bash
   git commit --allow-empty -F- <<'MSG'
   chore(gate-<r>): audit record

   Round <r>, pass <p>. Scope: <modules | all>.
   ACCEPTED [<TAG>] <ID>: <title> (<sha>)
   REJECTED (<real|bar|lead|stale|compile|test|gate|startup|env|user|malformed>): <title>: <reason>
   A/B: <module> <base> → <head> ms, …
   Known failures: <none | names>
   MSG
   ```

   Every `REJECTED` line keeps exactly that shape, so the skip-list command (§0) can read it.

### 5.3 ⏸ Checkpoint: implementation

```markdown
### /optimize · Round <r> · pass <p> · implemented
| # | Commit | ID | Subject |
|---|---|---|---|
| 1 | `abc1234` | R1P1-03 | perf: … |

- Rolled back: R1P1-07 (test): <first error line>
- Gate: green | fails only on known failures
- A/B (min over bare): http 112 → 98 ms, formats 140 → 141 ms
- Next: Round <r> · pass <p+1> · audit | Round <r+1> · pass 1 · audit | Finish

Reply: go (push and continue) · revert 2 · stop
```

On *go*, push (§5.4), `git tag -f checkpoint-gate<r>`, and continue as *Next* says.

### 5.4 Push

```bash
git fetch && git status -sb
```

- **Not behind:** `git push`.
- **Behind:** `git rebase origin/master`. If it applies cleanly, re-run **gate**, then
  `git push`. If it conflicts, `git rebase --abort` and **stop** (§8).
- Never `git push --force` or `git reset --hard`.

## 6. Rounds

| Round | Dimensions (§10) | Groups | Cap per pass | Max passes | Commit prefix | Tag on *go* |
|---|---|---|---|---|---|---|
| **1: Foundation** | `PERF`, `BLOAT`, `FEAT`, `DOC` | all three | 15 | 3 | per batch (§5) | `checkpoint-gate1` |
| **2: Consistency** | `DISC`, `CONS` | all three | 15 | 2 | `refactor: …` | `checkpoint-gate2` |
| **3: Hardening** | `BUG` cancellation, `BUG` platform | all three | 15 | 1 | `fix: …` | `checkpoint-gate3` |

A round ends when a pass confirms nothing, applies nothing, or reaches the round's max passes.
Each new pass audits the new HEAD with the grown skip list.

**Round 2 extras.**
- After a rename, `git grep -n -w <old name>` across the whole repo, `*.md` and dartdoc
  included. No hits may remain outside `CHANGELOG.md`.
- Run **smoke** after every `cli`/`tui` item.

**Round 3 extras.**
- Every `fix:` commit adds the test that failed before it (§5.1 step 5).
- A Windows-only change that could not run here is labelled `unverified-on-windows` in its
  commit body and in the audit record.
- The run is done when **gate** passes (apart from *known failures*), the tree is clean, and
  `master` is pushed.

## 7. User replies at a checkpoint

At the Step 0 checkpoint, *go* starts Round 1 · pass 1 · audit and *stop* ends the run with the
§9 resume line (nothing to push).

| Reply | At an audit checkpoint | At an implementation checkpoint |
|---|---|---|
| *go* | implement the proposed items | push, tag, continue |
| *drop 2,4* | remove them from the proposal; mark them `rejected (user)`; show the checkpoint again | — |
| *add 9* / *add R1P1-05* | add it to the proposal, even over the cap or a skeptic's reject; show the checkpoint again | — |
| *redo <note>* | re-run this audit with `<note>` added under "Rules:" in every finder prompt | — |
| *revert 2* | — | `git revert --no-edit <sha>`, mark it `rejected (user)`, re-run **gate**, show the checkpoint again |
| *stop* | end the run: §9 | end the run without pushing this pass: §9 |
| anything else | treat it as an instruction, apply it, and show the same checkpoint again | same |

## 8. When something goes wrong

| Situation | Do |
|---|---|
| Step 0: tree dirty, or `master` ≠ `origin/master` | **Stop** and ask. Do not stash, reset or commit the user's changes. |
| Baseline analyze or format fails | Fix it as its own commit before tagging (§3 step 3). |
| A finder or skeptic breaks its format | Re-send once (§4.1, §4.3), then count it as no items / REJECT. |
| An item fails **fast** | §2.2 two-strike rollback. |
| **gate** fails on a test outside *known failures* | Find the culprit without leaving `master`: for each of this pass's commits, newest first, run `git worktree add -f ../tk-probe <sha> && (cd ../tk-probe && dart pub get >/dev/null && dart test test/<file>.dart --plain-name '<test>'); git worktree remove --force ../tk-probe`. The first commit where it passes is clean; the commit just after it is the culprit. `git revert --no-edit <culprit>`, mark that item `rejected (gate)`, re-run **gate**. |
| **startup A/B** regresses a module | Revert this pass's commits that touch that module's `lib/` files, newest first (`git revert --no-edit <sha>`), re-running the A/B after each, until it clears. Mark each reverted item `rejected (startup)` with the numbers. |
| `cargo` or a Rust target is missing | Mark native items `rejected (env)`; carry on with the rest. |
| `chrome_test` skipped (no Chrome) | Carry on, and say in the checkpoint that chrome items are unverified. |
| Rebase conflict while pushing | `git rebase --abort`, **stop**, and show the conflicting files. |
| The co-worker's commits break **gate** | **Stop** and report it. Do not fix their commits inside an audit item. |
| An item needs a decision only the owner can make (a version bump, a dependency, a new module) | Mark it `rejected (user)` with "needs owner decision" and list it in the checkpoint. |
| Context or time is running out | Finish or roll back the current item so the tree is green, write the audit record for the partial pass, push if **gate** is green, and print the resume line (§9). |

## 9. Finish

Print this summary, then end:

```markdown
### /optimize · done
| Round | Passes | Applied | Rejected |
|---|---|---|---|
| 1 | 2 | 11 | 23 |

- Faster: <module base → head ms, and throughput numbers>
- Removed / renamed: <names and their replacements>
- Unverified: <unverified-on-windows items, chrome items if skipped>
- Pushed: `<sha>` on master
```

If the run stopped early, add the resume line instead of *Pushed*:
`Resume: /optimize <scope> — next is Round <r> · pass <p> · <audit | implementation>.`
The audit-record commits and `checkpoint-*` tags mark the place. On resume, read the last audit
record (`git log --grep='audit record' -1 --format=%B`), rebuild the skip list, skip Step 0's
gate if HEAD has a `checkpoint-*` tag, and start at the named step.

## 10. Dimensions

Every block has the same four parts. **Hunt** is where to look. **Evidence** is what an item
must show to be kept. **Not a finding** is what the *bar* skeptic rejects on sight. **Fix** is
what the change looks like. A finder's prompt carries its dimension's whole block; a bar
skeptic's carries Evidence and Not a finding.

### `PERF`: speed (startup, throughput, memory)

**Hunt**
- *Startup:* a new `import` in `lib/<m>.dart` that serves one method (CONVENTIONS §5: `Table.read`, not
  `Path.table()`); a computing top-level `final` (a `RegExp`, lookup table or map built at load
  rather than on first use); a third-party runtime dependency other than `path`.
- *Hot loops* (tokenizers in `formats`, the CSS/XPath engines, `Table`/`Sequence` operators, body
  decoding in `http`, Console redraw): per-element `substring`/`sublist`/spread/closure allocation,
  a record returned per token, a `RegExp` built inside the loop, string `+` in place of a
  `StringBuffer`, a `toList()` in the middle of a lazy chain, the same bytes `utf8`-decoded twice,
  `dynamic` dispatch on a typed path.
- *Algorithmic:* a full sort to read `take(n)`, `length` or `isEmpty`; a linear scan repeated
  inside a loop (O(n²)) where a set or map is available; recursion that a stack walk would beat
  (CONVENTIONS §4 depth rule).
- *Isolates:* a closure for `Isolate.run`/`Pool` built inside a method, which captures `this`; a whole
  input sent where one slice would do; an isolate spawned per item instead of per worker.
- *FFI:* bytes copied into native memory when a path would do (files are read by the library);
  `tk_alloc` without `tk_free` on the throw path; a "buffer full, call again" loop that does not grow
  geometrically.
- *I/O:* a whole file or body read where a stream would do; a fresh client per request, which
  defeats keep-alive; sequential `await` in a loop where `parallelize`/`Pool` fits; an unbounded
  cache or map.

**Evidence:** the measurement that would prove it. For a startup claim, `tool/bench.dart <module>`
(§2.1). For throughput, a microbenchmark sketch: the input and its size, the operation, the
expected MB/s or ms/op. An *expected* gain names its mechanism ("one allocation per token
removed", "O(n log n) → O(n)"), never just "faster".

**Not a finding:** under a 5 % gain; a cold path (option parsing, help rendering, one-shot
setup) unless it runs at startup; sprinkling `const` or `final`; code in `bin/` or `test/`; a gain
that needs a third-party package or native assets (`hook/build.dart`).

**Fix:** the smallest diff that removes the cost. Commit as `perf: …` with `base → head` numbers
in the body.

### `BLOAT`: surface and code that earn nothing

**Hunt**
- *Aliases:* two spellings of one operation, or a method that only composes two others with no
  call-site saving (CONVENTIONS §1 "One name per operation").
- *Extensions on `String`/`Iterable`/`Map`/`int`* beyond the conversion getter (`.url`, `.path`,
  `.json`, `60.s`). The vocabulary belongs on the returned type.
- *Public but not API:* `git grep -wn Name -- lib bin test '*.md'` finds only the defining file and
  tests. Such a symbol goes private, or goes. This includes test-only seams: a parameter,
  constructor or `@visibleForTesting` that exists for injection.
- *Dead code:* unused private members, branches unreachable after an exhaustive `switch`, a
  parameter every caller passes the same value, flags left over from a removed feature.
- *Duplicate helpers:* the same escape, quote, byte-format or path join written in two modules.
  Keep one, in `core` only if that adds no import.
- *Prose:* a doc comment that restates its signature; two `bin/` examples showing one idea.

**Evidence:** the `git grep` hit counts (lib / bin / test / docs) for each symbol removed, and the
net lines deleted. Name the replacement callers will use.

**Not a finding:** anything CONVENTIONS keeps on purpose (`Element.attr`, `Sequence.union`,
`chunk`, Chrome's `frame`/`pdf`/dialogs, `Duration.jittered`); a deletion that makes a common
call longer; "unused in `bin/`" alone, because the bar is usefulness to script authors, not `bin/`
usage.

**Fix:** delete, and update every call site and doc in the same commit. Commit as `refactor: …`,
with a CHANGELOG *Removed* line naming the replacement.

### `FEAT`: shorter call sites and missing capabilities

**Hunt**
- *Long call sites:* places in `bin/`, README, GUIDE or tests that spend 3+ lines on a common
  script task: a status check, a manual loop over pages, a parse-then-null-check.
- *Verbose signatures:* a required argument with an obvious default; help text not in the 2nd
  positional; a nullable return where callers write `!` (`git grep -n ')!'`). CONVENTIONS says to
  return the guaranteed value and add `…OrNull`.
- *Grid holes:* an operation present on one member of a family and missing on its siblings
  (`String`/`List<int>`/`Path`; `Opt`/`Arg`; `ConsoleTheme`/`TuiTheme`).
- *Modifiers:* a public class with no `final`/`base`/`interface`/`sealed`, or a closed set of
  variants that is not `sealed`, so `switch` can't be exhaustive.
- *Missing capability:* only one a real script hits. `git grep` before proposing it: XPath `$x`,
  CSS `$`, JSONPath, streaming `download`, every HTTP verb, `parallelize`, `retry` and `Table`
  already exist.

**Evidence:** the call site before and after, with tokens saved, plus the list of existing call
sites that shrink. An addition must delete more at call sites than it adds to the surface (§0).

**Not a finding:** a capability no call site needs today; anything that already exists under
another name (that would be an alias, so `BLOAT`); cryptography beyond hashing; anything that adds
a runtime dependency or measurable startup; a builder where order means nothing.

**Fix:** the smallest API that removes the long spelling, with the tests §5.1 step 5 lists. Commit as
`feat: …`.

### `DOC`: docs that disagree with code

**Hunt**
- *Stale snippets:* every identifier in a README, GUIDE, CHANGELOG *Unreleased* or `///` example
  checked with `git grep -w`. Renamed or removed names, old argument shapes.
- *Wrong behaviour:* documented defaults, throw-vs-null, exit codes (64 / 1 / 128+n) and caps
  (robots.txt 512 KiB, sitemap 50 MB, depth 1000, archive 200× / 1 GiB) that differ from the code.
- *CONVENTIONS* rules the code breaks, rules that contradict each other, or a rule with no *why*.
- *Dartdoc:* a comment that restates the signature (delete it), or one that omits what the
  signature can't say: what it throws, which scope it reads, how it cancels.
- *POSIX-only assumptions:* `/` joins, `~`, `sh -c` in docs or code.
- *Extension-type tests:* `is`/`case` checks on `Path`, `Row`, `Elements` or `Nodes`, which match
  the raw `String`/`Map`/`List` after erasure.

**Evidence:** the doc line and the code line that disagree, both cited.

**Not a finding:** wording polish that keeps the meaning; docs for private API; a longer
explanation where a table row already says it.

**Fix:** a deletion goes in Batch A, a correction in Batch C. If the code is wrong rather than
the doc, mark it `deferred (R3)` in the ledger (§1); Round 3's finders get it.

### `DISC`: can a script author find it?

**Hunt**
- Work through each entry point as autocomplete shows it: `'…'.url.`, `'…'.path.`, `.json.`,
  `Http.`, `Shell.`, `Hash.`, `Console.`, `Cancel.`. List the workflows that are reachable only by
  already knowing a top-level function or class name.
- A facade missing a member its siblings have; a returned type missing a method that exists only
  as a top-level function taking that type.
- A README tour step with no visible way in from the previous step's result.

**Evidence:** the path a user takes today (what they must already know) beside the path after
the fix. The common call must not get longer.

**Not a finding:** short globals that are the point (`run(...)`, `ask`, `confirm`); a second door
to the same operation (an alias, so `BLOAT`) unless the situation picks the door (CONVENTIONS §1).

**Fix:** *move* the entry point, never duplicate it. A clean cut, with every call site updated.

### `CONS`: siblings that read alike

**Hunt**
- Drift from CONVENTIONS §1's *One word per idea* table: `or`, `text`/`bytes`/`form`/`json`,
  `markup`, `download`, `…OrNull`, `.many()`, `links`.
- Names: booleans not `is…`; a sync twin not ending in `Sync`; a pure function of the receiver
  written as a method instead of a getter; `on<event>`/`<event>` pairs broken; theme fields named
  differently in `ConsoleTheme` and `TuiTheme`; HTTP verbs vs `Client` methods.
- Shape: parameter order across related functions; a builder step that doesn't return the
  receiver; a registration that doesn't return its unregistration.
- Failure: `null` vs throw vs `Either` for the same kind of failure; an error message missing the
  name of what was absent; `_ =>` wildcards over sealed types.

**Evidence:** the two sites side by side, each cited, and the CONVENTIONS rule they split on.

**Not a finding:** a difference a CONVENTIONS rule allows (two doors chosen by situation, `Table`
keyed by column name, the two `Object` parameters on `ctx.follow` and `client.scrape`).

**Fix:** rename every site; the zero-hit `git grep` from §6 *Round 2 extras* applies.

### `BUG`: cancellation, errors and edge inputs

**Hunt**
- *Cancel:* cancel `Cancel.scope` during each async API in `async`, `http`, `process` and `chrome`
  (`retry` backoff, `Pool` queue, `delay`, lock waiters, `download` mid-body, `run` with children).
  Afterwards no `Timer`, `StreamSubscription`, isolate, child process or socket may remain open,
  and pool permits must be returned.
- *Errors:* a worker error rethrown without its original stack (`Error.throwWithStackTrace`); a
  `catch` that swallows; a `Completer` completed twice; cleanup skipped on the error path; a
  `finally` that awaits after the scope is gone.
- *Edge inputs:* empty, a single element, multi-byte UTF-8 split across a chunk boundary, BOM, CRLF,
  non-UTF-8, exactly the 4 MiB native threshold, nesting at depth 1000, an unterminated construct
  (must be a `FormatException`, never a hang), lengths beyond `i32`.

**Evidence:** a test sketch: input or schedule → observed wrong output, hang or leak → expected.

**Not a finding:** a theoretical race with no schedule that triggers it; "could be null" where the
type says otherwise; behaviour CONVENTIONS §4 already defines.

**Fix:** the fix plus the test that failed before it.

### `BUG`: platform parity

**Hunt**
- *POSIX* (runnable here): the pipefail exit code, signal forwarding to the process tree, CRLF
  input, `/dev/tty` restore on every exit path.
- *Windows* (not runnable on macOS): unit tests on the *built* command line and path logic:
  `cmd /d /c` for built-ins, refusal of unsafe `cmd` arguments, `\` separators and drive roots,
  atomic replace while a file is locked, native prebuilt lookup by `<os>_<arch>`.

**Evidence:** the command line or path the code builds, beside the one the platform needs.

**Not a finding:** a platform the package doesn't target; behaviour that differs by design and is
documented.

**Fix:** the fix plus a unit test. Label anything not executed as `unverified-on-windows` in the
commit body.
